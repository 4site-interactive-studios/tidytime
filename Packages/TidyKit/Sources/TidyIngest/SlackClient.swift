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

    public init(http: HTTPClient, token: String, baseURL: URL = URL(string: "https://slack.com/api")!) {
        self.http = http; self.token = token; self.baseURL = baseURL
    }

    private func get(_ method: String, _ query: [URLQueryItem] = []) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let request = HTTPRequest(method: "GET", url: comps.url!, headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        return response.body
    }

    private struct SlackError: Decodable { let ok: Bool; let error: String? }
    private func checkOK(_ data: Data) throws {
        if let e = try? JSONDecoder().decode(SlackError.self, from: data), e.ok == false {
            throw IngestError.transport("slack error: \(e.error ?? "unknown")")
        }
    }

    public func authTestUserId() async throws -> String {
        struct R: Decodable { let user_id: String? }
        let data = try await get("auth.test")
        try checkOK(data)
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
            try checkOK(data)
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
            try checkOK(data)
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
            try checkOK(data)
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

public struct FakeSlackClient: SlackClient {
    public var selfUserId: String
    public var names: [String: String]
    public var conversations: [SlackConversation]
    public var messagesByConversation: [String: [SlackMessageDTO]]
    public init(selfUserId: String, names: [String: String] = [:], conversations: [SlackConversation] = [],
                messagesByConversation: [String: [SlackMessageDTO]] = [:]) {
        self.selfUserId = selfUserId; self.names = names; self.conversations = conversations
        self.messagesByConversation = messagesByConversation
    }
    public func authTestUserId() async throws -> String { selfUserId }
    public func userNames() async throws -> [String: String] { names }
    public func listConversations() async throws -> [SlackConversation] { conversations }
    public func history(conversationId: String, oldestTs: String?) async throws -> [SlackMessageDTO] {
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
        let sorted = messages.sorted { $0.postedAt < $1.postedAt }
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

    public init(client: SlackClient, db: AppDatabase, clock: TidyClock = SystemClock(),
                sessionizer: SlackSessionizer = SlackSessionizer()) {
        self.client = client; self.db = db; self.clock = clock; self.sessionizer = sessionizer
    }

    @discardableResult
    public func run() async throws -> Int {
        let now = Int64(clock.now.timeIntervalSince1970)
        let selfId = try await client.authTestUserId()
        let names = try await client.userNames()
        let conversations = try await client.listConversations()
        var total = 0
        for conv in conversations {
            let cursor = try db.latestSlackTs(conversationId: conv.id)
            let dtos = try await client.history(conversationId: conv.id, oldestTs: cursor)
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
            if let latest = all.last?.ts {
                try db.saveSyncState(SyncState(source: "slack:\(conv.id)", cursor: latest,
                                               lastRunAt: now, lastSuccessAt: now))
            }
        }
        return total
    }
}
