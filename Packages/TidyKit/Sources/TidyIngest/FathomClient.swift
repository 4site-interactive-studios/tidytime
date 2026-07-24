import Foundation
import TidyCore
import TidyStore

// Fathom meetings + transcripts. ⚠️ Build-time checks (docs/reference/fathom-api.md): the response
// envelope ({items, next_cursor}), meeting id = stringified recording_id, transcript timestamps as
// "HH:MM:SS", and summary at default_summary.markdown_formatted are the documented-but-unverified
// shape. Fixtures follow it; adjust the DTOs here if the live API differs.

struct FathomListResponse: Decodable, Sendable {
    let items: [FathomMeeting]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
}
struct FathomMeeting: Decodable, Sendable {
    let recordingId: Int
    let title: String?
    let scheduledStartTime: String?
    let scheduledEndTime: String?
    let recordingStartTime: String?
    let recordingEndTime: String?
    let shareUrl: String?
    let calendarInvitees: [FathomInvitee]?
    let transcript: [FathomUtterance]?
    let defaultSummary: FathomSummary?
    enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id", title
        case scheduledStartTime = "scheduled_start_time", scheduledEndTime = "scheduled_end_time"
        case recordingStartTime = "recording_start_time", recordingEndTime = "recording_end_time"
        case shareUrl = "share_url", calendarInvitees = "calendar_invitees"
        case transcript, defaultSummary = "default_summary"
    }
}
struct FathomInvitee: Decodable, Sendable {
    let email: String?
    let name: String?
    let isExternal: Bool?
    enum CodingKeys: String, CodingKey { case email, name, isExternal = "is_external" }
}
struct FathomUtterance: Decodable, Sendable {
    let speaker: FathomSpeaker?
    let text: String
    let timestamp: String?
}
struct FathomSpeaker: Decodable, Sendable { let name: String?; let email: String? }
struct FathomSummary: Decodable, Sendable {
    let markdownFormatted: String?
    enum CodingKeys: String, CodingKey { case markdownFormatted = "markdown_formatted" }
}

/// A parsed meeting + its child rows, ready to persist.
public struct FathomMeetingBundle: Sendable, Equatable {
    public let meeting: Meeting
    public let invitees: [MeetingInvitee]
    public let utterances: [TranscriptUtterance]
    public init(meeting: Meeting, invitees: [MeetingInvitee], utterances: [TranscriptUtterance]) {
        self.meeting = meeting; self.invitees = invitees; self.utterances = utterances
    }
}

enum FathomMapper {
    static func bundle(_ dto: FathomMeeting, internalDomains: [String], fetchedAt: Int64) -> FathomMeetingBundle {
        let id = String(dto.recordingId)
        let recStart = TimeParse.epoch(dto.recordingStartTime)
        let recEnd = TimeParse.epoch(dto.recordingEndTime)
        let schedStart = TimeParse.epoch(dto.scheduledStartTime)
        let schedEnd = TimeParse.epoch(dto.scheduledEndTime)
        // Duration ground truth = recording span; fall back to scheduled slot.
        let duration: Int
        if let s = recStart, let e = recEnd { duration = Int(max(0, e - s)) }
        else if let s = schedStart, let e = schedEnd { duration = Int(max(0, e - s)) }
        else { duration = 0 }

        let transcript = dto.transcript ?? []
        let summary = dto.defaultSummary?.markdownFormatted
        let meeting = Meeting(
            id: id, source: "fathom", title: dto.title,
            scheduledStart: schedStart, scheduledEnd: schedEnd,
            recordingStart: recStart, recordingEnd: recEnd, durationSeconds: duration,
            hasTranscript: !transcript.isEmpty, hasSummary: summary != nil, summary: summary,
            externalUrl: dto.shareUrl, calendarEventId: nil, fetchedAt: fetchedAt, createdAt: fetchedAt)

        let invitees = (dto.calendarInvitees ?? []).map { inv in
            MeetingInvitee(meetingId: id, email: inv.email, name: inv.name,
                           emailDomain: TimeParse.domain(inv.email),
                           isExternal: inv.isExternal ?? TimeParse.isExternal(email: inv.email, internalDomains: internalDomains))
        }
        let utterances = transcript.enumerated().map { idx, u in
            TranscriptUtterance(meetingId: id, idx: idx, speaker: u.speaker?.name,
                                speakerEmail: u.speaker?.email,
                                startSeconds: TimeParse.hmsSeconds(u.timestamp) ?? 0, endSeconds: nil, text: u.text)
        }
        return FathomMeetingBundle(meeting: meeting, invitees: invitees, utterances: utterances)
    }
}

public protocol FathomClient: Sendable {
    func fetchMeetings(createdAfter: String?) async throws -> [FathomMeetingBundle]
}

public struct LiveFathomClient: FathomClient {
    private let http: HTTPClient
    private let baseURL: URL
    private let apiKey: String
    private let internalDomains: [String]
    private let clock: TidyClock
    private let backoff: Backoff
    private let maxRetries: Int
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(http: HTTPClient, apiKey: String, internalDomains: [String] = [],
                baseURL: URL = URL(string: "https://api.fathom.ai/external/v1")!,
                clock: TidyClock = SystemClock(), backoff: Backoff = Backoff(), maxRetries: Int = 3,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.http = http; self.apiKey = apiKey; self.internalDomains = internalDomains
        self.baseURL = baseURL; self.clock = clock; self.backoff = backoff
        self.maxRetries = maxRetries; self.sleeper = sleeper
    }

    public func fetchMeetings(createdAfter: String?) async throws -> [FathomMeetingBundle] {
        let fetchedAt = Int64(clock.now.timeIntervalSince1970)
        var out: [FathomMeetingBundle] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("meetings"), resolvingAgainstBaseURL: false)!
            var q: [URLQueryItem] = [
                URLQueryItem(name: "include_transcript", value: "true"),
                URLQueryItem(name: "include_summary", value: "true"),
            ]
            if let createdAfter { q.append(URLQueryItem(name: "created_after", value: createdAfter)) }
            if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            comps.queryItems = q
            let request = HTTPRequest(method: "GET", url: comps.url!, headers: ["X-Api-Key": apiKey])
            let response = try await sendWithRetry(request)
            let doc: FathomListResponse
            do { doc = try JSONDecoder().decode(FathomListResponse.self, from: response.body) }
            catch { throw IngestError.decoding("fathom meetings: \(error)") }
            out.append(contentsOf: doc.items.map { FathomMapper.bundle($0, internalDomains: internalDomains, fetchedAt: fetchedAt) })
            cursor = doc.nextCursor
            pages += 1
        } while cursor != nil && pages < 100
        return out
    }

    private func sendWithRetry(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response = try await http.send(request)
            if response.status == 429, attempt < maxRetries {
                let retryAfter = response.headers["Retry-After"].flatMap(TimeInterval.init)
                await sleeper(backoff.delay(attempt: attempt, retryAfter: retryAfter))
                attempt += 1; continue
            }
            guard (200..<300).contains(response.status) else {
                throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
            }
            return response
        }
    }
}

public struct FakeFathomClient: FathomClient {
    public var bundles: [FathomMeetingBundle]
    public init(bundles: [FathomMeetingBundle]) { self.bundles = bundles }
    public func fetchMeetings(createdAfter: String?) async throws -> [FathomMeetingBundle] { bundles }
}

/// Builds a `kind='meeting'` session from a meeting, using recording time as ground truth.
public enum MeetingSessionBuilder {
    public static func session(from meeting: Meeting, createdAt: Int64) -> Session {
        let start = meeting.recordingStart ?? meeting.scheduledStart ?? createdAt
        let end = meeting.recordingEnd ?? meeting.scheduledEnd ?? (start + Int64(meeting.durationSeconds))
        return Session(
            kind: "meeting", startedAt: start, endedAt: end, durationSeconds: meeting.durationSeconds,
            title: meeting.title, contextKey: nil, primaryApp: nil, sourceRef: meeting.id, createdAt: createdAt)
    }
}

/// Syncs Fathom meetings into the cache and (re)builds their meeting sessions.
public struct FathomSync: Sendable {
    private let client: FathomClient
    private let db: AppDatabase
    private let clock: TidyClock

    public init(client: FathomClient, db: AppDatabase, clock: TidyClock = SystemClock()) {
        self.client = client; self.db = db; self.clock = clock
    }

    @discardableResult
    public func run(createdAfter: String? = nil) async throws -> Int {
        let now = Int64(clock.now.timeIntervalSince1970)
        let existingCursor = try? db.syncState("fathom")?.cursor
        let bundles = try await client.fetchMeetings(createdAfter: createdAfter ?? existingCursor)
        var latestRecording: Int64 = 0
        for b in bundles {
            try db.upsertMeeting(b.meeting)
            try db.replaceInvitees(meetingId: b.meeting.id, b.invitees)
            try db.replaceUtterances(meetingId: b.meeting.id, b.utterances)
            try db.deleteMeetingSession(meetingId: b.meeting.id)
            try db.insertSession(MeetingSessionBuilder.session(from: b.meeting, createdAt: now))
            if let rs = b.meeting.recordingStart { latestRecording = max(latestRecording, rs) }
        }
        // Advance the cursor to just past the latest recording we saw (ISO8601).
        let cursor = latestRecording > 0
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(latestRecording)))
            : (try? db.syncState("fathom")?.cursor) ?? nil
        try db.saveSyncState(SyncState(source: "fathom", cursor: cursor, lastRunAt: now, lastSuccessAt: now))
        return bundles.count
    }
}
