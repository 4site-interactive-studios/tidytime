import Foundation
import TidyCore
import TidyStore

// Read-only Slack ingest via an internal app's user token. ⚠️ Build-time check: the internal-app
// exemption from the May-2025 rate limits (docs/reference/slack-api.md) — confirm still in force.

public struct SlackConversation: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let type: String   // 'channel' | 'group' | 'im' | 'mpim'
    public init(id: String, name: String?, type: String) { self.id = id; self.name = name; self.type = type }
}

public struct SlackMessageDTO: Sendable, Equatable {
    public let userId: String?
    public let text: String?
    public let ts: String
    public let threadTs: String?
    public init(userId: String?, text: String?, ts: String, threadTs: String? = nil) {
        self.userId = userId; self.text = text; self.ts = ts; self.threadTs = threadTs
    }
}

public protocol SlackClient: Sendable {
    func authTestUserId() async throws -> String
    func userNames() async throws -> [String: String]
    func listConversations() async throws -> [SlackConversation]
    func history(conversationId: String, oldestTs: String?) async throws -> [SlackMessageDTO]
}

// MARK: - ts helpers

public enum SlackTS {
    /// Slack ts ("1719000000.001200") → Unix epoch seconds.
    public static func epoch(_ ts: String) -> Int64 {
        Int64(Double(ts) ?? 0)
    }
}

// MARK: - Live client (Slack Web API)

public struct LiveSlackClient: SlackClient {
    private let http: HTTPClient
    private let token: String
    private let baseURL: URL
    private let backoff: Backoff
    private let maxRetries: Int
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(http: HTTPClient, token: String, baseURL: URL = URL(string: "https://slack.com/api")!,
                backoff: Backoff = Backoff(base: 2, cap: 60), maxRetries: Int = 3,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.http = http; self.token = token; self.baseURL = baseURL
        self.backoff = backoff; self.maxRetries = maxRetries; self.sleeper = sleeper
    }

    // The first live run proved Slack WILL 429 a workspace-wide first sync, and this client had no
    // backoff at all (Productive/Fathom did) — every 15-min cycle then re-slammed the limit and
    // nothing ever completed. Honors Retry-After, which Slack always sends on 429.
    private func get(_ method: String, _ query: [URLQueryItem] = []) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let request = HTTPRequest(method: "GET", url: comps.url!, headers: ["Authorization": "Bearer \(token)"])
        var attempt = 0
        while true {
            let response = try await http.send(request)
            if response.status == 429, attempt < maxRetries {
                let retryAfter = response.headers["Retry-After"].flatMap(TimeInterval.init)
                await sleeper(backoff.delay(attempt: attempt, retryAfter: retryAfter))
                attempt += 1
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
            }
            return response.body
        }
    }

    private struct SlackError: Decodable { let ok: Bool; let error: String? }
    /// Throws `.slack(code:method:)` so callers can tell a skippable per-conversation failure from
    /// a fatal token failure. Previously every `ok:false` collapsed into one opaque string.
    private func checkOK(_ data: Data, method: String) throws {
        if let e = try? JSONDecoder().decode(SlackError.self, from: data), e.ok == false {
            throw IngestError.slack(code: e.error ?? "unknown", method: method)
        }
    }

    public func authTestUserId() async throws -> String {
        struct R: Decodable { let user_id: String? }
        let data = try await get("auth.test")
        try checkOK(data, method: "auth.test")
        guard let uid = (try? JSONDecoder().decode(R.self, from: data))?.user_id else {
            throw IngestError.decoding("auth.test: no user_id")
        }
        return uid
    }

    public func userNames() async throws -> [String: String] {
        struct R: Decodable {
            struct U: Decodable { let id: String; let real_name: String?; let name: String? }
            let members: [U]?
            let response_metadata: Meta?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var names: [String: String] = [:]
        var cursor: String?
        var pages = 0
        repeat {
            var q = [URLQueryItem(name: "limit", value: "200")]
            if let cursor, !cursor.isEmpty { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await get("users.list", q)
            try checkOK(data, method: "users.list")
            let r = try JSONDecoder().decode(R.self, from: data)
            for u in r.members ?? [] { names[u.id] = u.real_name ?? u.name }
            cursor = r.response_metadata?.next_cursor
            pages += 1
        } while (cursor?.isEmpty == false) && pages < 50
        return names
    }

    public func listConversations() async throws -> [SlackConversation] {
        struct R: Decodable {
            struct C: Decodable {
                let id: String; let name: String?
                let is_im: Bool?; let is_mpim: Bool?; let is_private: Bool?; let is_channel: Bool?
            }
            let channels: [C]?
            let response_metadata: Meta?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var out: [SlackConversation] = []
        var cursor: String?
        var pages = 0
        repeat {
            var q = [URLQueryItem(name: "types", value: "public_channel,private_channel,mpim,im"),
                     URLQueryItem(name: "limit", value: "200")]
            if let cursor, !cursor.isEmpty { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await get("conversations.list", q)
            try checkOK(data, method: "conversations.list")
            let r = try JSONDecoder().decode(R.self, from: data)
            for c in r.channels ?? [] {
                let type: String = (c.is_im == true) ? "im" : (c.is_mpim == true) ? "mpim"
                    : (c.is_private == true) ? "group" : "channel"
                out.append(SlackConversation(id: c.id, name: c.name, type: type))
            }
            cursor = r.response_metadata?.next_cursor
            pages += 1
        } while (cursor?.isEmpty == false) && pages < 50
        return out
    }

    public func history(conversationId: String, oldestTs: String?) async throws -> [SlackMessageDTO] {
        struct R: Decodable {
            struct M: Decodable { let user: String?; let text: String?; let ts: String; let thread_ts: String? }
            let messages: [M]?
            let response_metadata: Meta?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var out: [SlackMessageDTO] = []
        var cursor: String?
        var pages = 0
        repeat {
            var q = [URLQueryItem(name: "channel", value: conversationId),
                     URLQueryItem(name: "limit", value: "200")]
            if let oldestTs { q.append(URLQueryItem(name: "oldest", value: oldestTs)) }
            if let cursor, !cursor.isEmpty { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await get("conversations.history", q)
            try checkOK(data, method: "conversations.history")
            let r = try JSONDecoder().decode(R.self, from: data)
            for m in r.messages ?? [] {
                out.append(SlackMessageDTO(userId: m.user, text: m.text, ts: m.ts, threadTs: m.thread_ts))
            }
            cursor = r.response_metadata?.next_cursor
            pages += 1
        } while (cursor?.isEmpty == false) && pages < 50
        return out
    }
}

public final class FakeSlackClient: SlackClient, @unchecked Sendable {
    public var selfUserId: String
    public var names: [String: String]
    public var conversations: [SlackConversation]
    public var messagesByConversation: [String: [SlackMessageDTO]]
    /// Conversation id → Slack error code that `history` should raise, so a per-conversation
    /// failure can be reproduced without a live workspace.
    public var historyErrors: [String: String]
    /// Conversation ids `history` was actually asked for, in order. Lets a test assert that a
    /// conversation known unreachable is genuinely *not re-requested*, rather than merely tolerated.
    public private(set) var historyRequests: [String] = []

    public init(selfUserId: String, names: [String: String] = [:], conversations: [SlackConversation] = [],
                messagesByConversation: [String: [SlackMessageDTO]] = [:],
                historyErrors: [String: String] = [:]) {
        self.selfUserId = selfUserId; self.names = names; self.conversations = conversations
        self.messagesByConversation = messagesByConversation
        self.historyErrors = historyErrors
    }
    public func authTestUserId() async throws -> String { selfUserId }
    public func userNames() async throws -> [String: String] { names }
    public func listConversations() async throws -> [SlackConversation] { conversations }
    public func history(conversationId: String, oldestTs: String?) async throws -> [SlackMessageDTO] {
        historyRequests.append(conversationId)
        if let code = historyErrors[conversationId] {
            throw IngestError.slack(code: code, method: "conversations.history")
        }
        let all = messagesByConversation[conversationId] ?? []
        guard let oldestTs, let cutoff = Double(oldestTs) else { return all }
        return all.filter { (Double($0.ts) ?? 0) > cutoff }
    }
}

/// Clusters a conversation's messages into `kind='slack'` sessions (split on gaps).
public struct SlackSessionizer: Sendable {
    public let gapSeconds: Int
    public let nominalSeconds: Int
    public init(gapSeconds: Int = 900, nominalSeconds: Int = 60) {
        self.gapSeconds = gapSeconds; self.nominalSeconds = nominalSeconds
    }

    public func sessions(conversationId: String, name: String?, messages: [SlackMessage], createdAt: Int64) -> [Session] {
        // Only the user's OWN messages define the user's time. The first live sync built 12k
        // "sessions" out of colleagues chatting in channels the user never touched that day —
        // phantom time on the timeline. Others' messages stay stored as context for notes, but a
        // session exists only where the user actually participated.
        let sorted = messages.filter(\.isSelf).sorted { $0.postedAt < $1.postedAt }
        guard !sorted.isEmpty else { return [] }
        var clusters: [[SlackMessage]] = []
        var current: [SlackMessage] = [sorted[0]]
        for msg in sorted.dropFirst() {
            if msg.postedAt - current.last!.postedAt > Int64(gapSeconds) {
                clusters.append(current); current = [msg]
            } else {
                current.append(msg)
            }
        }
        clusters.append(current)
        return clusters.map { cluster in
            let start = cluster.first!.postedAt
            var end = cluster.last!.postedAt
            if end == start { end = start + Int64(nominalSeconds) }
            return Session(kind: "slack", startedAt: start, endedAt: end, durationSeconds: Int(end - start),
                           title: name, contextKey: "slack:\(conversationId)", primaryApp: "com.tinyspeck.slackmacgap",
                           sourceRef: conversationId, createdAt: createdAt)
        }
    }
}

/// Pulls each conversation's new messages, upserts them, and rebuilds its Slack sessions.
public struct SlackSync: Sendable {
    private let client: SlackClient
    private let db: AppDatabase
    private let clock: TidyClock
    private let sessionizer: SlackSessionizer
    /// First-sync window. The first live run pulled TWELVE YEARS of workspace history (back to
    /// 2014) because an absent cursor meant "everything". A bounded default keeps the first pull
    /// proportionate to what the product can attribute (and inside the retention window anyway).
    private let initialHistoryDays: Int
    /// Optional so tests and the fake path stay silent; the app always passes one.
    private let logger: TidyLogger?

    public init(client: SlackClient, db: AppDatabase, clock: TidyClock = SystemClock(),
                sessionizer: SlackSessionizer = SlackSessionizer(), initialHistoryDays: Int = 30,
                logger: TidyLogger? = nil) {
        self.client = client; self.db = db; self.clock = clock; self.sessionizer = sessionizer
        self.initialHistoryDays = initialHistoryDays; self.logger = logger
    }

    @discardableResult
    public func run() async throws -> Int {
        let now = Int64(clock.now.timeIntervalSince1970)
        let selfId = try await client.authTestUserId()
        // users.list over a whole workspace is expensive; refresh the name map at most daily.
        // Messages that arrive between refreshes keep user_id and just lack a display name.
        var names: [String: String] = [:]
        let usersState = (try? db.syncState("slack:users")) ?? nil
        let usersFresh = usersState?.lastSuccessAt.map { now - $0 < 86_400 } ?? false
        if !usersFresh {
            names = try await client.userNames()
            try db.saveSyncState(SyncState(source: "slack:users", cursor: nil,
                                           lastRunAt: now, lastSuccessAt: now))
            // Backfill: messages ingested while the throttle was active stored user_name = nil,
            // and the incremental cursor means they are never re-fetched — without this they'd
            // stay nameless forever (round-3 finding R1-C2).
            try db.backfillSlackUserNames(names)
        }
        let conversations = try await client.listConversations()
        var skipped = 0
        let firstSyncOldest = "\(now - Int64(initialHistoryDays) * 86_400).000000"
        var total = 0
        for conv in conversations {
            let stateKey = "slack:\(conv.id)"
            let prior = (try? db.syncState(stateKey)) ?? nil

            // A conversation already known unreachable is not re-requested every 15 minutes. It is
            // re-probed once the cooldown expires rather than tombstoned forever, because Slack
            // documents that conversation IDs are NOT stable — a private channel shared across
            // orgs can change its `G…` prefix to `C…`, so a stored id can start returning
            // channel_not_found for a channel that still exists. Rejoining a channel should also
            // heal on its own without the user knowing this state exists.
            if let since = Self.unreachableSince(prior), now - since < Self.unreachableCooldown {
                continue
            }

            let cursor = try db.latestSlackTs(conversationId: conv.id) ?? firstSyncOldest
            let dtos: [SlackMessageDTO]
            do {
                dtos = try await client.history(conversationId: conv.id, oldestTs: cursor)
            } catch let IngestError.slack(code, method) where SlackErrorClass.classify(code) == .skipConversation {
                // One unreachable conversation is not a broken workspace. Record it, tell the user
                // once, and keep syncing everything else — the whole run used to abort here, which
                // is why `slack.last_success_at` had never been set despite 7,309 banked messages.
                let firstTime = Self.unreachableSince(prior) == nil
                try? db.saveSyncState(SyncState(
                    source: stateKey,
                    cursor: prior?.cursor,
                    lastRunAt: now,
                    lastSuccessAt: prior?.lastSuccessAt,
                    lastError: "\(Self.unreachableMarker)\(now) \(code) (\(method))"))
                if firstTime {
                    logger?.info("slack conversation unreachable — skipping it, syncing the rest", [
                        "conversation": conv.id,
                        "name": conv.name ?? "(unnamed)",
                        "code": code,
                        "retry_after_hours": String(Self.unreachableCooldown / 3600),
                    ])
                }
                skipped += 1
                continue
            }
            let records = dtos.map { dto in
                SlackMessage(
                    conversationId: conv.id, conversationType: conv.type, conversationName: conv.name,
                    ts: dto.ts, postedAt: SlackTS.epoch(dto.ts), userId: dto.userId,
                    userName: dto.userId.flatMap { names[$0] }, isSelf: dto.userId == selfId,
                    threadTs: dto.threadTs, text: dto.text, permalink: nil, fetchedAt: now)
            }
            try db.upsertSlackMessages(records)
            total += records.count

            // Rebuild sessions from all messages of this conversation.
            let all = try db.slackMessages(conversationId: conv.id)
            try db.deleteSlackSessions(conversationId: conv.id)
            for session in sessionizer.sessions(conversationId: conv.id, name: conv.name, messages: all, createdAt: now) {
                try db.insertSession(session)
            }
            // A successful pass always clears any unreachable marker (lastError: nil), so a
            // rejoined or re-resolved conversation heals with no manual step.
            try db.saveSyncState(SyncState(source: stateKey, cursor: all.last?.ts ?? prior?.cursor,
                                           lastRunAt: now, lastSuccessAt: now, lastError: nil))
        }
        if skipped > 0 {
            logger?.debug("slack sync finished with unreachable conversations", [
                "skipped": String(skipped), "synced": String(conversations.count - skipped),
            ])
        }
        return total
    }

    // MARK: Unreachable-conversation bookkeeping

    /// Marker prefix in `sync_state.last_error` for a conversation we could not read. Encoded into
    /// the existing per-conversation row rather than a new table: `sync_state` already keys on
    /// `slack:<conv>`, so this needs no migration, and it survives restarts — which an in-memory
    /// set could not, since `IngestCoordinator` builds a fresh `SlackSync` on every pass.
    static let unreachableMarker = "unreachable-since:"

    /// How long an unreachable conversation stays skipped before one re-probe. A day turns 96
    /// pointless requests per day into one, while still self-healing.
    static let unreachableCooldown: Int64 = 86_400

    /// Epoch seconds when the conversation was first found unreachable, or `nil` if it is not
    /// marked. A row whose `last_error` is anything else (or nil) is treated as reachable.
    static func unreachableSince(_ state: SyncState?) -> Int64? {
        guard let raw = state?.lastError, raw.hasPrefix(unreachableMarker) else { return nil }
        let rest = raw.dropFirst(unreachableMarker.count)
        return Int64(rest.prefix { $0.isNumber })
    }
}
