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

/// One page of meetings plus the cursor for the next, if any.
public struct FathomPage: Sendable, Equatable {
    public let bundles: [FathomMeetingBundle]
    public let nextCursor: String?
    public init(bundles: [FathomMeetingBundle], nextCursor: String?) {
        self.bundles = bundles; self.nextCursor = nextCursor
    }
}

public protocol FathomClient: Sendable {
    /// Fetch **one** page. Pagination is driven by the caller so it can persist each page before
    /// asking for the next — see `FathomSync.run`. Fetching every page internally and returning an
    /// accumulated array is what made a mid-pagination 429 discard all of it and loop forever.
    func fetchMeetingsPage(createdAfter: String?, cursor: String?) async throws -> FathomPage
}

extension FathomClient {
    /// Accumulate every page. Convenience for tests and callers that genuinely want it all at
    /// once; the sync path deliberately does **not** use this.
    public func fetchMeetings(createdAfter: String?, maxPages: Int = 100) async throws -> [FathomMeetingBundle] {
        var out: [FathomMeetingBundle] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await fetchMeetingsPage(createdAfter: createdAfter, cursor: cursor)
            out.append(contentsOf: page.bundles)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < maxPages
        return out
    }
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
                clock: TidyClock = SystemClock(),
                // Fathom's heavy-call limit is a rolling 60s window, so the backoff has to be able
                // to outlast one. The old default (base 0.5s, 3 retries) slept 0.5+1+2 = 3.5s
                // TOTAL and then gave up — roughly 17x short, and exactly what
                // docs/reference/fathom-api.md already prescribed against ("start at ~5s and
                // double"). 5+10+20+30+30 = 95s clears a 60s window with margin.
                backoff: Backoff = Backoff(base: 5, cap: 30), maxRetries: Int = 5,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.http = http; self.apiKey = apiKey; self.internalDomains = internalDomains
        self.baseURL = baseURL; self.clock = clock; self.backoff = backoff
        self.maxRetries = maxRetries; self.sleeper = sleeper
    }

    public func fetchMeetingsPage(createdAfter: String?, cursor: String?) async throws -> FathomPage {
        let fetchedAt = Int64(clock.now.timeIntervalSince1970)
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
        return FathomPage(
            bundles: doc.items.map { FathomMapper.bundle($0, internalDomains: internalDomains, fetchedAt: fetchedAt) },
            nextCursor: doc.nextCursor)
    }

    private func sendWithRetry(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response = try await http.send(request)
            if response.status == 429, attempt < maxRetries {
                let retryAfter = response.serverRequestedDelay
                await sleeper(backoff.delay(attempt: attempt, retryAfter: retryAfter))
                attempt += 1; continue
            }
            // A bare `http 429: ` with an empty body told a human nothing — it was logged 2,246
            // times over 33 days without ever explaining what to do next.
            if response.status == 429 {
                throw IngestError.rateLimited(
                    provider: "fathom", attempts: maxRetries + 1,
                    waitedSeconds: backoff.totalDelay(retries: maxRetries),
                    detail: """
                        Fathom meters transcript reads separately: 30 requests per 60s for "heavy"
                        calls (any /meetings request with include_transcript or include_summary),
                        dropping to 5 per 60s under load. Anything already fetched this run HAS
                        been saved and the cursor advanced, so the next run resumes instead of
                        restarting. If this repeats every run with meetings still at 0, the key is
                        the thing to check: Fathom -> User Settings -> API Access.
                        """)
            }
            guard (200..<300).contains(response.status) else {
                throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
            }
            return response
        }
    }
}

public final class FakeFathomClient: FathomClient, @unchecked Sendable {
    public var bundles: [FathomMeetingBundle]
    /// Pages served in order, for exercising multi-page pagination and mid-pagination failures.
    /// When nil, `bundles` comes back as a single page.
    public var pages: [Result<FathomPage, IngestError>]?
    public private(set) var requestedCursors: [String?] = []

    public init(bundles: [FathomMeetingBundle] = [], pages: [Result<FathomPage, IngestError>]? = nil) {
        self.bundles = bundles; self.pages = pages
    }

    public func fetchMeetingsPage(createdAfter: String?, cursor: String?) async throws -> FathomPage {
        requestedCursors.append(cursor)
        guard var remaining = pages else { return FathomPage(bundles: bundles, nextCursor: nil) }
        guard !remaining.isEmpty else { return FathomPage(bundles: [], nextCursor: nil) }
        let next = remaining.removeFirst()
        pages = remaining
        return try next.get()
    }
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

    /// Pull meetings page by page, **persisting each page before requesting the next**.
    ///
    /// The previous shape fetched up to 100 pages into an array and persisted nothing until the
    /// whole walk finished. A 429 on any page threw out of the accumulator, discarded every page
    /// already fetched and parsed, and left `sync_state.cursor` untouched — so 900s later the run
    /// replayed the identical page sequence into the identical limit. That closed loop ran 2,246
    /// times over 33 days with `last_success_at` never once set and `meetings` at 0.
    ///
    /// Bounding the first pull to 90 days (43ca776) shrank the input but could not break the loop,
    /// because the failure is structural — all-or-nothing pagination plus cursor-only-on-success —
    /// not size-dependent. Persisting per page is what turns a rate limit from a permanent wall
    /// into a pause: each run keeps whatever it got and the next one resumes past it.
    @discardableResult
    public func run(createdAfter: String? = nil, defaultWindowDays: Int = 90,
                    maxPages: Int = 100) async throws -> Int {
        let now = Int64(clock.now.timeIntervalSince1970)
        let existingCursor = (try? db.syncState("fathom"))??.cursor
        // No cursor yet → bound the first pull instead of fetching all history (transcripts are
        // the heavy 30/min-limited call; an unbounded first pull 429-loops forever).
        let fallback = ISO8601DateFormatter().string(
            from: clock.now.addingTimeInterval(-Double(defaultWindowDays) * 86_400))
        let since = createdAfter ?? existingCursor.flatMap { $0.isEmpty ? nil : $0 } ?? fallback

        var total = 0
        var pageCursor: String?
        var pages = 0
        var latestRecording: Int64 = 0

        do {
            repeat {
                let page = try await client.fetchMeetingsPage(createdAfter: since, cursor: pageCursor)
                for b in page.bundles {
                    try db.upsertMeeting(b.meeting)
                    try db.replaceInvitees(meetingId: b.meeting.id, b.invitees)
                    try db.replaceUtterances(meetingId: b.meeting.id, b.utterances)
                    try db.deleteMeetingSession(meetingId: b.meeting.id)
                    try db.insertSession(MeetingSessionBuilder.session(from: b.meeting, createdAt: now))
                    if let rs = b.meeting.recordingStart { latestRecording = max(latestRecording, rs) }
                }
                total += page.bundles.count
                // Advance the durable cursor after every page, so an interruption on the next one
                // costs at most that page rather than the whole run.
                saveCursor(latestRecording: latestRecording, now: now, succeeded: false)
                pageCursor = page.nextCursor
                pages += 1
            } while pageCursor != nil && pages < maxPages
        } catch {
            // Partial progress is already committed above. Re-throw so the failure is still
            // visible in `last_error` and Doctor — a silent partial success would be worse.
            throw error
        }

        saveCursor(latestRecording: latestRecording, now: now, succeeded: true)
        return total
    }

    /// Persist the high-water mark. `lastSuccessAt` is stamped only on a complete walk, so a run
    /// that banked pages and then hit a limit is not misreported as a clean sync.
    private func saveCursor(latestRecording: Int64, now: Int64, succeeded: Bool) {
        let prior = (try? db.syncState("fathom")) ?? nil
        let cursor = latestRecording > 0
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(latestRecording)))
            : prior?.cursor
        try? db.saveSyncState(SyncState(
            source: "fathom", cursor: cursor, lastRunAt: now,
            lastSuccessAt: succeeded ? now : prior?.lastSuccessAt,
            lastError: succeeded ? nil : prior?.lastError))
    }
}
