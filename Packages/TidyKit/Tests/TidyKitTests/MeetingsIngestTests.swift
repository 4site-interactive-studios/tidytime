import XCTest
import Foundation
import TidyCore
import TidyStore
@testable import TidyIngest

final class TimeParseTests: XCTestCase {
    func testEpochParsesRFC3339() {
        let t1 = TimeParse.epoch("2026-07-22T15:00:00Z")
        let t2 = TimeParse.epoch("2026-07-22T16:00:00Z")
        XCTAssertNotNil(t1)
        XCTAssertEqual(t2! - t1!, 3600)   // one hour apart, whatever the absolute epoch
        XCTAssertNotNil(TimeParse.epoch("2026-07-22T15:00:00.500Z"))
        XCTAssertNil(TimeParse.epoch("not a date"))
        XCTAssertNil(TimeParse.epoch(nil))
    }
    func testHMS() {
        XCTAssertEqual(TimeParse.hmsSeconds("01:02:03"), 3723)
        XCTAssertEqual(TimeParse.hmsSeconds("12:40"), 760)
        XCTAssertEqual(TimeParse.hmsSeconds("45"), 45)
        XCTAssertNil(TimeParse.hmsSeconds("x:y"))
    }
    func testDomainAndExternal() {
        XCTAssertEqual(TimeParse.domain("a@Client.ORG"), "client.org")
        XCTAssertTrue(TimeParse.isExternal(email: "a@client.org", internalDomains: ["4site.org"]))
        XCTAssertFalse(TimeParse.isExternal(email: "b@4site.org", internalDomains: ["4site.org"]))
        XCTAssertTrue(TimeParse.isExternal(email: nil, internalDomains: ["4site.org"])) // unknown → external
    }
    func testDayEpoch() {
        // Midnight UTC of the day equals the RFC3339 midnight parse.
        XCTAssertEqual(TimeParse.dayEpochUTC("2026-07-22"), TimeParse.epoch("2026-07-22T00:00:00Z"))
        XCTAssertNil(TimeParse.dayEpochUTC("nope"))
    }
}

final class FathomParseTests: XCTestCase {
    let fixture = """
    { "items": [ {
        "recording_id": 555,
        "title": "Acme + 4Site sync",
        "scheduled_start_time": "2026-07-22T15:00:00Z",
        "scheduled_end_time": "2026-07-22T16:00:00Z",
        "recording_start_time": "2026-07-22T15:02:00Z",
        "recording_end_time": "2026-07-22T16:03:00Z",
        "share_url": "https://fathom.video/abc",
        "calendar_invitees": [
          {"email":"bryan@4site.org","name":"Bryan","is_external":false},
          {"email":"ceo@acme.org","name":"Acme CEO","is_external":true}
        ],
        "default_summary": {"markdown_formatted":"# Notes\\nDiscussed the donation page."},
        "transcript": [
          {"speaker":{"name":"Bryan","email":"bryan@4site.org"},"text":"Let's review the page.","timestamp":"00:00:05"},
          {"speaker":{"name":"Acme CEO"},"text":"Looks great.","timestamp":"00:12:40"}
        ]
    } ], "next_cursor": null }
    """

    func testParsesMeetingWithRecordingDuration() async throws {
        let http = FakeHTTPClient([.json(fixture)])
        let client = LiveFathomClient(http: http, apiKey: "k", internalDomains: ["4site.org"],
                                      clock: FixedClock(Date(timeIntervalSince1970: 9999)), sleeper: { _ in })
        let bundles = try await client.fetchMeetings(createdAfter: nil)
        XCTAssertEqual(bundles.count, 1)
        let b = bundles[0]
        XCTAssertEqual(b.meeting.id, "555")
        XCTAssertEqual(b.meeting.durationSeconds, 61 * 60)   // recording span 15:02–16:03
        XCTAssertTrue(b.meeting.hasTranscript)
        XCTAssertTrue(b.meeting.hasSummary)
        XCTAssertEqual(b.invitees.count, 2)
        XCTAssertEqual(b.invitees.first { $0.email == "ceo@acme.org" }?.emailDomain, "acme.org")
        XCTAssertTrue(b.invitees.first { $0.email == "ceo@acme.org" }?.isExternal ?? false)
        XCTAssertEqual(b.utterances.count, 2)
        XCTAssertEqual(b.utterances[1].startSeconds, 760)    // 00:12:40
        // Auth header present
        XCTAssertEqual(http.sentRequests[0].headers["X-Api-Key"], "k")
    }
}

final class FathomSyncTests: XCTestCase {
    func testSyncPersistsMeetingAndBuildsSession() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(id: "555", source: "fathom", title: "Sync",
                              recordingStart: 1000, recordingEnd: 4660, durationSeconds: 3660,
                              hasTranscript: true, fetchedAt: 0, createdAt: 0)
        let bundle = FathomMeetingBundle(
            meeting: meeting,
            invitees: [MeetingInvitee(meetingId: "555", email: "x@acme.org", emailDomain: "acme.org", isExternal: true)],
            utterances: [TranscriptUtterance(meetingId: "555", idx: 0, startSeconds: 0, text: "hi")])
        let sync = FathomSync(client: FakeFathomClient(bundles: [bundle]), db: db,
                              clock: FixedClock(Date(timeIntervalSince1970: 5000)))

        let count = try await sync.run()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try db.meeting(id: "555")?.durationSeconds, 3660)
        XCTAssertEqual(try db.invitees(meetingId: "555").count, 1)
        XCTAssertEqual(try db.utterances(meetingId: "555").count, 1)
        // A meeting session was created from recording time.
        let sessions = try db.sessions(from: 0, to: 100_000)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].kind, "meeting")
        XCTAssertEqual(sessions[0].sourceRef, "555")
        XCTAssertEqual(sessions[0].durationSeconds, 3660)

        // Re-sync must not duplicate the session or child rows.
        _ = try await sync.run()
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 1)
        XCTAssertEqual(try db.invitees(meetingId: "555").count, 1)
    }
}

final class CalendarTests: XCTestCase {
    let fixture = """
    { "items": [
        { "id":"ev1","status":"confirmed","summary":"Client call","description":"agenda",
          "location":"Zoom","start":{"dateTime":"2026-07-22T15:00:00Z"},"end":{"dateTime":"2026-07-22T16:00:00Z"},
          "organizer":{"email":"bryan@4site.org"},
          "attendees":[{"email":"bryan@4site.org","displayName":"Bryan","responseStatus":"accepted"},
                       {"email":"ceo@acme.org","displayName":"CEO","responseStatus":"accepted"}],
          "hangoutLink":"https://meet.google.com/xyz","iCalUID":"uid-1","updated":"2026-07-20T10:00:00Z" },
        { "id":"ev2","status":"cancelled" }
    ], "nextSyncToken":"tok-123" }
    """

    func testParsesEventsAndExternalFlag() async throws {
        let http = FakeHTTPClient([.json(fixture)])
        let client = LiveGoogleCalendarClient(http: http, internalDomains: ["4site.org"],
                                              accessToken: { "access-tok" },
                                              clock: FixedClock(Date(timeIntervalSince1970: 111)))
        let page = try await client.fetchEvents(calendarId: "primary", syncToken: nil, timeMin: nil, timeMax: nil)
        XCTAssertEqual(page.upserts.count, 1)
        XCTAssertEqual(page.deletedIds, ["ev2"])
        XCTAssertEqual(page.nextSyncToken, "tok-123")
        let ev = page.upserts[0]
        XCTAssertEqual(ev.conferenceUrl, "https://meet.google.com/xyz")
        XCTAssertEqual(ev.icalUid, "uid-1")
        XCTAssertFalse(ev.allDay)
        XCTAssertTrue(ev.attendeesJson?.contains("\"isExternal\":true") ?? false)   // acme external
        XCTAssertEqual(http.sentRequests[0].headers["Authorization"], "Bearer access-tok")
    }

    func testSyncUpsertsAndDeletesAndSavesToken() async throws {
        let db = try AppDatabase.inMemory()
        let ev = CalendarEvent(id: "ev1", calendarId: "primary", title: "Call", startAt: 1000, endAt: 4600, fetchedAt: 0)
        let page = CalendarPage(upserts: [ev], deletedIds: ["gone"], nextSyncToken: "tok-9")
        let sync = CalendarSync(client: FakeGoogleCalendarClient(page: page), db: db,
                                clock: FixedClock(Date(timeIntervalSince1970: 200)))
        let summary = try await sync.run()
        XCTAssertEqual(summary.upserted, 1)
        XCTAssertEqual(try db.calendarEvents(from: 0, to: 100_000).count, 1)
        XCTAssertEqual(try db.syncState("google_calendar")?.cursor, "tok-9")
    }
}

final class AwayGapResolutionTests: XCTestCase {
    func testResolveAwayGap() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.insertAwayGap(AwayGap(startedAt: 1000, endedAt: 4000, durationSeconds: 3000, cause: "idle", createdAt: 0))
        XCTAssertEqual(try db.unresolvedAwayGaps(from: 0, to: 100_000).count, 1)
        try db.resolveAwayGap(id: id, attribution: "call", note: "client call", clientId: "c1", resolvedAt: 5000)
        XCTAssertTrue(try db.unresolvedAwayGaps(from: 0, to: 100_000).isEmpty)
    }
}
