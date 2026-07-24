import Foundation
import TidyCore
import TidyStore

// Google Calendar (read-only). Google returns camelCase JSON, so DTOs decode without CodingKeys or
// a snake_case strategy. OAuth (loopback + PKCE, Internal-type client) is live-only; the access
// token is supplied by an injected provider so request-building + parsing are testable.

struct GCalListResponse: Decodable, Sendable {
    let items: [GCalEvent]?
    let nextSyncToken: String?
    let nextPageToken: String?
}
struct GCalEvent: Decodable, Sendable {
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: GCalTime?
    let end: GCalTime?
    let organizer: GCalOrganizer?
    let attendees: [GCalAttendee]?
    let conferenceData: GCalConferenceData?
    let hangoutLink: String?
    let iCalUID: String?
    let updated: String?
}
struct GCalTime: Decodable, Sendable { let dateTime: String?; let date: String? }
struct GCalOrganizer: Decodable, Sendable { let email: String? }
struct GCalAttendee: Decodable, Sendable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
}
struct GCalConferenceData: Decodable, Sendable { let entryPoints: [GCalEntryPoint]? }
struct GCalEntryPoint: Decodable, Sendable { let entryPointType: String?; let uri: String? }

/// Attendee shape we store as JSON in `calendar_events.attendees_json`.
struct StoredAttendee: Codable, Sendable {
    let email: String?
    let name: String?
    let responseStatus: String?
    let isExternal: Bool
}

enum GCalMapper {
    /// Active event → CalendarEvent (cancelled events are handled as deletions by the sync).
    static func event(_ dto: GCalEvent, calendarId: String, internalDomains: [String], fetchedAt: Int64) -> CalendarEvent? {
        let allDay = dto.start?.date != nil
        let startAt: Int64?
        let endAt: Int64?
        if allDay {
            startAt = dto.start?.date.flatMap(TimeParse.dayEpochUTC)
            endAt = dto.end?.date.flatMap(TimeParse.dayEpochUTC)
        } else {
            startAt = TimeParse.epoch(dto.start?.dateTime)
            endAt = TimeParse.epoch(dto.end?.dateTime)
        }
        guard let s = startAt, let e = endAt else { return nil }

        let stored = (dto.attendees ?? []).map { a in
            StoredAttendee(email: a.email, name: a.displayName, responseStatus: a.responseStatus,
                           isExternal: TimeParse.isExternal(email: a.email, internalDomains: internalDomains))
        }
        let attendeesJson = (try? JSONEncoder().encode(stored)).map { String(decoding: $0, as: UTF8.self) }

        let videoUri = dto.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        let conferenceUrl = dto.hangoutLink ?? videoUri

        return CalendarEvent(
            id: dto.id, calendarId: calendarId, title: dto.summary, description: dto.description,
            location: dto.location, startAt: s, endAt: e, allDay: allDay, status: dto.status,
            organizerEmail: dto.organizer?.email, attendeesJson: attendeesJson,
            conferenceUrl: conferenceUrl, icalUid: dto.iCalUID,
            updatedAt: TimeParse.epoch(dto.updated), fetchedAt: fetchedAt)
    }
}

/// The result of one calendar sync pull: events to upsert, ids to delete, and the next sync token.
public struct CalendarPage: Sendable, Equatable {
    public let upserts: [CalendarEvent]
    public let deletedIds: [String]
    public let nextSyncToken: String?
    public init(upserts: [CalendarEvent], deletedIds: [String], nextSyncToken: String?) {
        self.upserts = upserts; self.deletedIds = deletedIds; self.nextSyncToken = nextSyncToken
    }
}

public protocol GoogleCalendarClient: Sendable {
    func fetchEvents(calendarId: String, syncToken: String?, timeMin: String?, timeMax: String?) async throws -> CalendarPage
}

public struct LiveGoogleCalendarClient: GoogleCalendarClient {
    private let http: HTTPClient
    private let internalDomains: [String]
    private let accessToken: @Sendable () async throws -> String
    private let clock: TidyClock
    private let baseURL: URL

    public init(http: HTTPClient, internalDomains: [String] = [],
                accessToken: @escaping @Sendable () async throws -> String,
                clock: TidyClock = SystemClock(),
                baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3")!) {
        self.http = http; self.internalDomains = internalDomains; self.accessToken = accessToken
        self.clock = clock; self.baseURL = baseURL
    }

    public func fetchEvents(calendarId: String, syncToken: String?, timeMin: String?, timeMax: String?) async throws -> CalendarPage {
        let fetchedAt = Int64(clock.now.timeIntervalSince1970)
        let token = try await accessToken()
        var upserts: [CalendarEvent] = []
        var deleted: [String] = []
        var pageToken: String? = nil
        var syncTokenOut: String? = nil
        var pages = 0
        repeat {
            var comps = URLComponents(
                url: baseURL.appendingPathComponent("calendars/\(calendarId)/events"),
                resolvingAgainstBaseURL: false)!
            var q = [URLQueryItem(name: "singleEvents", value: "true"),
                     URLQueryItem(name: "maxResults", value: "250")]
            if let syncToken { q.append(URLQueryItem(name: "syncToken", value: syncToken)) }
            else {
                if let timeMin { q.append(URLQueryItem(name: "timeMin", value: timeMin)) }
                if let timeMax { q.append(URLQueryItem(name: "timeMax", value: timeMax)) }
            }
            if let pageToken { q.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = q
            let request = HTTPRequest(method: "GET", url: comps.url!,
                                      headers: ["Authorization": "Bearer \(token)"])
            let response = try await http.send(request)
            guard (200..<300).contains(response.status) else {
                throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
            }
            let doc: GCalListResponse
            do { doc = try JSONDecoder().decode(GCalListResponse.self, from: response.body) }
            catch { throw IngestError.decoding("google calendar: \(error)") }
            for item in doc.items ?? [] {
                if item.status == "cancelled" { deleted.append(item.id) }
                else if let ev = GCalMapper.event(item, calendarId: calendarId, internalDomains: internalDomains, fetchedAt: fetchedAt) {
                    upserts.append(ev)
                }
            }
            pageToken = doc.nextPageToken
            syncTokenOut = doc.nextSyncToken ?? syncTokenOut
            pages += 1
        } while pageToken != nil && pages < 100
        return CalendarPage(upserts: upserts, deletedIds: deleted, nextSyncToken: syncTokenOut)
    }
}

public struct FakeGoogleCalendarClient: GoogleCalendarClient {
    public var page: CalendarPage
    public init(page: CalendarPage) { self.page = page }
    public func fetchEvents(calendarId: String, syncToken: String?, timeMin: String?, timeMax: String?) async throws -> CalendarPage { page }
}

/// Syncs calendar events into the cache and records the `syncToken` cursor.
public struct CalendarSync: Sendable {
    private let client: GoogleCalendarClient
    private let db: AppDatabase
    private let clock: TidyClock
    private let calendarId: String

    public init(client: GoogleCalendarClient, db: AppDatabase, clock: TidyClock = SystemClock(),
                calendarId: String = "primary") {
        self.client = client; self.db = db; self.clock = clock; self.calendarId = calendarId
    }

    public struct Summary: Sendable, Equatable { public var upserted: Int; public var deleted: Int }

    @discardableResult
    public func run(timeMin: String? = nil, timeMax: String? = nil) async throws -> Summary {
        let now = Int64(clock.now.timeIntervalSince1970)
        let syncToken = try? db.syncState("google_calendar")?.cursor
        let page = try await client.fetchEvents(calendarId: calendarId, syncToken: syncToken,
                                                timeMin: timeMin, timeMax: timeMax)
        try db.upsertCalendarEvents(page.upserts)
        for id in page.deletedIds { try db.deleteCalendarEvent(id: id) }
        try db.saveSyncState(SyncState(source: "google_calendar", cursor: page.nextSyncToken ?? syncToken,
                                       lastRunAt: now, lastSuccessAt: now))
        return Summary(upserted: page.upserts.count, deleted: page.deletedIds.count)
    }
}
