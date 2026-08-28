import Foundation
import TidyCore
import TidyStore

/// Bootstraps `entity_signals` from the Productive cache, so a session resolves at rung 1 without
/// the user teaching the app anything first.
///
/// Two sources, because on a real workspace the documented one alone yields nothing:
///
/// 1. **Company domains** → `url_host` + `email_domain`. This is what
///    `docs/architecture/understand-layer.md` §2.2 specifies, and it is right in principle — but on
///    the workspace this was built against **0 of 687 companies carry a domain**, so it produced
///    exactly zero signals. It is kept because it is high-precision where it does apply.
/// 2. **Name tokens** → `keyword`, from company names and project names. This is what actually
///    populates the vocabulary here, and §2.2 calls for it too.
///
/// ## Why ambiguity, not a stop-list, is the precision guard
///
/// A hand-written stop-list cannot know that "video" appears in 40 projects across 30 different
/// clients while "engrid" belongs to exactly one. So the rule is structural: **a token becomes a
/// signal only if every name containing it maps to the same client.** A token that points at two
/// clients points at neither, and minting it would produce confident wrong attributions — far worse
/// than no attribution, because the user has to notice and undo it.
///
/// `pd_tasks.title` is deliberately NOT a source. It is the highest-volume (11,631 rows) and
/// lowest-precision vocabulary available, and the URL rung gives exact task attribution instead.
public struct EntityBootstrap: Sendable {
    public init() {}

    /// Tokens that name our own tooling or the calendar rather than a client. These would otherwise
    /// pass the ambiguity test whenever a single client happens to own the only project mentioning
    /// them, and attach a client to every unrelated session.
    static let houseTokens: Set<String> = [
        "4site", "internal", "admin", "ops", "operations", "general", "misc", "miscellaneous",
        "retainer", "support", "maintenance", "meeting", "meetings", "call", "calls", "time",
        "off", "pto", "holiday", "vacation", "training", "onboarding", "hiring", "recruiting",
    ]

    @discardableResult
    public func run(_ db: AppDatabase, now: Int64) throws -> Int {
        var count = 0
        let companies = try db.companies()
        let projects = try db.projects()

        // 1. Domains — exact, unambiguous, and free when present.
        for c in companies {
            guard let domain = c.domain?.lowercased(), !domain.isEmpty else { continue }
            for type in ["url_host", "email_domain"] {
                try db.insertSignalIfAbsent(EntitySignal(
                    signalType: type, signalValue: domain, clientId: c.id,
                    provenance: "bootstrapped", createdAt: now, updatedAt: now))
                count += 1
            }
        }

        // 2. Name tokens, keeping only those that identify exactly one client.
        var clientsByToken: [String: Set<String>] = [:]
        var projectsByToken: [String: Set<String>] = [:]

        for c in companies where !c.name.isEmpty {
            for t in Tokenizer.tokens(c.name) {
                clientsByToken[t, default: []].insert(c.id)
            }
        }
        for p in projects where !p.name.isEmpty {
            // A project with no company is unattributable — this is exactly the state the whole
            // mirror was in before `include=` was sent, and minting signals from it would attach
            // tokens to an empty client id.
            guard !p.companyId.isEmpty else { continue }
            for t in Tokenizer.tokens(p.name) {
                clientsByToken[t, default: []].insert(p.companyId)
                projectsByToken[t, default: []].insert(p.id)
            }
        }

        for (token, clients) in clientsByToken {
            guard clients.count == 1, let clientId = clients.first else { continue }
            guard !Self.houseTokens.contains(token) else { continue }
            // Attach a project only when the token is unique to one project as well; otherwise the
            // signal still resolves the client, which is the more valuable half.
            let projectId = projectsByToken[token]?.count == 1 ? projectsByToken[token]?.first : nil
            try db.insertSignalIfAbsent(EntitySignal(
                signalType: "keyword", signalValue: token, clientId: clientId, projectId: projectId,
                provenance: "bootstrapped", createdAt: now, updatedAt: now))
            count += 1
        }
        return count
    }
}

/// Classifies all unclassified sessions for a day and strengthens the matched signals.
public struct DayClassifier: Sendable {
    public init() {}
    @discardableResult
    public func run(_ db: AppDatabase, from: Int64, to: Int64, now: Int64) throws -> (classified: Int, unresolved: Int) {
        let classifier = try Classifier.load(db)
        var classified = 0, unresolved = 0
        for s in try db.sessions(from: from, to: to) {
            guard let id = s.id, s.clientId == nil else { continue }
            let invitees = (s.kind == "meeting" ? s.sourceRef.flatMap { try? db.invitees(meetingId: $0) } : nil) ?? []
            // Page text captured during the session feeds rung-2 lexical (local; no gate needed).
            // Scoped to the session's own host so an absorbed detour can't supply the evidence (R1-3).
            let host = s.contextKey.flatMap { $0.hasPrefix("web:") ? String($0.dropFirst(4)) : nil }
            let pageTexts = (s.kind == "screen"
                ? try? db.pageTexts(from: s.startedAt, to: s.endedAt, limit: 3, host: host) : nil) ?? []
            if let c = classifier.classify(s, invitees: invitees, pageTexts: pageTexts) {
                try db.classifySession(id: id, clientId: c.clientId, projectId: c.projectId, taskId: c.taskId,
                                       confidence: c.confidence, rung: c.rung, rationale: c.rationale, classifiedAt: now)
                if let v = c.matchedSignalValue, let t = c.matchedSignalType {
                    // Re-touch the SAME signal that fired (not a hardcoded url_host) so the right
                    // rule rises in weight — strengthening a bogus type would pollute entity_signals.
                    try? db.strengthenSignal(type: t, value: v, clientId: c.clientId,
                                             projectId: c.projectId, provenance: "inferred", now: now)
                }
                classified += 1
            } else {
                unresolved += 1
            }
        }
        return (classified, unresolved)
    }
}

/// Records a user's recap action into `decisions` and feeds the learning loop: a reassignment
/// creates/strengthens a **user-confirmed** signal (which outranks inferred ones forever).
public struct DecisionRecorder: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    public init(db: AppDatabase, clock: TidyClock = SystemClock()) { self.db = db; self.clock = clock }

    public struct SignalRef: Sendable { public let type: String; public let value: String
        public init(type: String, value: String) { self.type = type; self.value = value } }

    @discardableResult
    public func record(suggestionId: Int64?, action: String, clientId: String? = nil,
                       projectId: String? = nil, taskId: String? = nil, note: String? = nil,
                       confirmSignal: SignalRef? = nil) throws -> Int64 {
        let now = Int64(clock.now.timeIntervalSince1970)
        let decisionId = try db.insertDecision(Decision(
            suggestionId: suggestionId, action: action, clientId: clientId, projectId: projectId,
            taskId: taskId, note: note, createdAt: now))
        if let sig = confirmSignal, let clientId {
            try db.strengthenSignal(type: sig.type, value: sig.value, clientId: clientId,
                                    projectId: projectId, provenance: "user_confirmed", now: now)
        }
        if let suggestionId {
            try db.updateSuggestionStatus(id: suggestionId, status: Self.status(for: action), now: now)
        }
        return decisionId
    }

    static func status(for action: String) -> String {
        switch action {
        case "accept", "log": return "logged"
        case "edit": return "edited"
        case "reassign": return "reassigned"
        case "toss": return "tossed"
        case "snooze": return "snoozed"
        default: return "pending"
        }
    }
}

/// Generates ask-once resolution questions for recurring unresolved web hosts.
public struct ResolutionQuestionGenerator: Sendable {
    public let minOccurrences: Int
    public init(minOccurrences: Int = 2) { self.minOccurrences = minOccurrences }

    @discardableResult
    public func generate(_ db: AppDatabase, from: Int64, to: Int64, now: Int64) throws -> Int {
        var hostCounts: [String: Int] = [:]
        for s in try db.sessions(from: from, to: to) where s.clientId == nil {
            if let ck = s.contextKey, ck.hasPrefix("web:") {
                hostCounts[String(ck.dropFirst(4)), default: 0] += 1
            }
        }
        var created = 0
        for (host, count) in hostCounts where count >= minOccurrences {
            try db.upsertQuestion(ResolutionQuestion(
                question: "Which client is \(host)?", signalType: "url_host", signalValue: host, createdAt: now))
            created += 1
        }
        return created
    }
}

/// The sensitivity gate (guardrail G2). Fails closed: any configured term found → sensitive, and
/// the content must NOT be sent to a cloud model. Runs before rungs 3–4 and note generation.
public struct SensitivityGate: Sendable {
    /// Hardcoded floor of always-on sensitive terms (lowercased). Guarantees the gate is NEVER a
    /// no-op even with an empty/partial config or a user-cleared list (guardrails.md: "an empty list
    /// never disables the gate"). Config terms are added ON TOP of this floor. Over-caution is the
    /// safe failure direction (a bland generic note costs one manual edit; the opposite leaks).
    public static let floorTerms: [String] = [
        "salary", "compensation", "raise", "bonus", "pip", "performance review", "performance plan",
        "termination", "fired", "layoff", "severance", "offer letter", "lawsuit", "settlement",
        "legal counsel", "confidential", "hr complaint", "disciplinary", "grievance",
    ]

    public let terms: [String]
    public init(terms: [String], includeFloor: Bool = true) {
        var all = terms.map { $0.lowercased() }.filter { !$0.isEmpty }
        if includeFloor { all.append(contentsOf: Self.floorTerms) }
        self.terms = Array(Set(all))
    }
    public init(config: Config) { self.init(terms: config.sensitivity.allTerms) }

    public func isSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        return terms.contains { lower.contains($0) }
    }
    /// nil when sensitive (block cloud send); otherwise the text.
    public func gated(_ text: String) -> String? { isSensitive(text) ? nil : text }
}
