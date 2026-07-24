// TidyUnderstand — sessionization support, entity resolution / the client registry, the local
// classification rungs (1 rules, 2 lexical), the sensitivity gate, and the learning loop. Cloud
// rungs (3–5) live in TidyAI and are reached through a protocol, so this target has no dependency
// on TidyAI. See docs/architecture/understand-layer.md and classification-ladder.md.
import Foundation
import TidyStore

/// Lightweight tokenizer for lexical matching: lowercased alphanumeric tokens, length ≥ 3, minus a
/// small stopword list.
public enum Tokenizer {
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "www", "http", "https", "com", "org", "net", "your",
        "you", "from", "this", "that", "are", "was", "our", "out", "not",
    ]
    public static func tokens(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }
    public static func tokenSet(_ strings: [String?]) -> Set<String> {
        Set(strings.flatMap { tokens($0) })
    }
}

/// The result of classifying a session at rungs 1–2.
public struct Classification: Sendable, Equatable {
    public var clientId: String
    public var projectId: String?
    public var taskId: String?
    public var confidence: Double
    public var rung: Int
    public var rationale: String
    /// The signal value that produced a rung-1 match (used to strengthen the learned rule).
    public var matchedSignalValue: String?
    public init(clientId: String, projectId: String? = nil, taskId: String? = nil, confidence: Double,
                rung: Int, rationale: String, matchedSignalValue: String? = nil) {
        self.clientId = clientId; self.projectId = projectId; self.taskId = taskId
        self.confidence = confidence; self.rung = rung; self.rationale = rationale
        self.matchedSignalValue = matchedSignalValue
    }
}

/// Classifies sessions using deterministic signal rules (rung 1) then lexical matching against the
/// Productive cache (rung 2). Immutable snapshot built via `load`.
public struct Classifier: Sendable {
    private let signalsByValue: [String: [EntitySignal]]
    private let candidates: [LexicalCandidate]

    struct LexicalCandidate: Sendable {
        let clientId: String
        let projectId: String?
        let taskId: String?
        let specificity: Int   // 0 company, 1 project, 2 task
        let tokens: Set<String>
        let label: String
    }

    public init(companies: [PDCompany], projects: [PDProject], tasks: [PDTask], signals: [EntitySignal]) {
        self.signalsByValue = Dictionary(grouping: signals, by: { $0.signalValue })

        let companyById = Dictionary(companies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projectById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cands: [LexicalCandidate] = []
        for c in companies {
            cands.append(.init(clientId: c.id, projectId: nil, taskId: nil, specificity: 0,
                               tokens: Tokenizer.tokenSet([c.name]), label: c.name))
        }
        for p in projects {
            let company = companyById[p.companyId]
            cands.append(.init(clientId: p.companyId, projectId: p.id, taskId: nil, specificity: 1,
                               tokens: Tokenizer.tokenSet([p.name, company?.name]), label: p.name))
        }
        for t in tasks {
            let project = projectById[t.projectId]
            let company = project.flatMap { companyById[$0.companyId] }
            guard let clientId = project?.companyId else { continue }
            cands.append(.init(clientId: clientId, projectId: t.projectId, taskId: t.id, specificity: 2,
                               tokens: Tokenizer.tokenSet([t.title, project?.name, company?.name]), label: t.title))
        }
        self.candidates = cands
    }

    public static func load(_ db: AppDatabase) throws -> Classifier {
        Classifier(companies: try db.companies(), projects: try db.projects(),
                   tasks: try db.tasks(), signals: try db.allSignals())
    }

    /// Classify a session. `invitees` are supplied for meeting sessions; `pageTexts` optionally add
    /// lexical evidence. Returns nil when nothing resolves confidently.
    public func classify(_ session: Session, invitees: [MeetingInvitee] = [], pageTexts: [String] = []) -> Classification? {
        if let r1 = rung1(session, invitees: invitees) { return r1 }
        return rung2(session, invitees: invitees, pageTexts: pageTexts)
    }

    // Rung 1 — deterministic signal rules.
    private func rung1(_ session: Session, invitees: [MeetingInvitee]) -> Classification? {
        var values: [String] = []
        if let ck = session.contextKey {
            if ck.hasPrefix("web:") { values.append(String(ck.dropFirst(4))) }
            if ck.hasPrefix("slack:") { values.append(String(ck.dropFirst(6))) }
        }
        values.append(contentsOf: invitees.compactMap { $0.emailDomain })

        let matches = values.flatMap { v in (signalsByValue[v] ?? []).map { (v, $0) } }
            .filter { $0.1.clientId != nil }
        guard !matches.isEmpty else { return nil }
        let best = matches.max { a, b in
            (a.1.isAuthoritative ? 1 : 0, a.1.weight) < (b.1.isAuthoritative ? 1 : 0, b.1.weight)
        }!
        let sig = best.1
        return Classification(
            clientId: sig.clientId!, projectId: sig.projectId, taskId: nil,
            confidence: sig.isAuthoritative ? 0.97 : 0.85, rung: 1,
            rationale: "matched \(sig.signalType) '\(best.0)'", matchedSignalValue: best.0)
    }

    // Rung 2 — lexical matching against the Productive cache.
    private func rung2(_ session: Session, invitees: [MeetingInvitee], pageTexts: [String]) -> Classification? {
        var query = Tokenizer.tokenSet([session.title])
        if let ck = session.contextKey, ck.hasPrefix("web:") {
            query.formUnion(Tokenizer.tokens(String(ck.dropFirst(4))))
        }
        query.formUnion(invitees.compactMap { $0.emailDomain }.flatMap { Tokenizer.tokens($0) })
        query.formUnion(pageTexts.flatMap { Tokenizer.tokens($0) })
        guard !query.isEmpty else { return nil }

        let scored = candidates
            .map { (cand: $0, score: query.intersection($0.tokens).count) }
            .filter { $0.score >= 1 }
        guard let best = scored.max(by: { a, b in
            (a.score, -a.cand.specificity) < (b.score, -b.cand.specificity)  // higher score, then LESS specific
        }) else { return nil }

        // Ambiguity guard: a different client tied at the top score → don't guess (becomes a question).
        let tiedDifferentClient = scored.contains { $0.score == best.score && $0.cand.clientId != best.cand.clientId }
        if tiedDifferentClient { return nil }

        return Classification(
            clientId: best.cand.clientId, projectId: best.cand.projectId, taskId: best.cand.taskId,
            confidence: min(0.8, 0.45 + 0.12 * Double(best.score)), rung: 2,
            rationale: "lexical match '\(best.cand.label)' (score \(best.score))")
    }
}
