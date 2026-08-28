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
    /// The signal (type + value) that produced a rung-1 match, used to strengthen the RIGHT rule.
    public var matchedSignalType: String?
    public var matchedSignalValue: String?
    public init(clientId: String, projectId: String? = nil, taskId: String? = nil, confidence: Double,
                rung: Int, rationale: String, matchedSignalType: String? = nil, matchedSignalValue: String? = nil) {
        self.clientId = clientId; self.projectId = projectId; self.taskId = taskId
        self.confidence = confidence; self.rung = rung; self.rationale = rationale
        self.matchedSignalType = matchedSignalType; self.matchedSignalValue = matchedSignalValue
    }
}

/// Classifies sessions using deterministic signal rules (rung 1) then lexical matching against the
/// Productive cache (rung 2). Immutable snapshot built via `load`.
public struct Classifier: Sendable {
    private let signalsByValue: [String: [EntitySignal]]
    private let candidates: [LexicalCandidate]
    /// Lookups for exact attribution — a task id read straight out of a URL needs no scoring.
    private let tasksById: [String: PDTask]
    private let projectsById: [String: PDProject]

    struct LexicalCandidate: Sendable {
        let clientId: String
        let projectId: String?
        let taskId: String?
        let specificity: Int   // 0 company, 1 project, 2 task
        let tokens: Set<String>
        let label: String
    }

    /// Live vocabulary only.
    ///
    /// On a real agency workspace **11,433 of 11,631 tasks are closed and 877 of 965 projects are
    /// archived** — 98% and 91%. Matching today's window titles against a decade of finished work
    /// is what produced cards like "CI:60 Zoom Doom": a single common word ("zoom", "page", "app")
    /// hitting a task closed years ago. Dead work cannot be worked on today, so it is not evidence.
    ///
    /// `EntityBootstrap` already filtered archived rows when minting signals; this is the same rule
    /// applied to the lexical candidates, which is where the bulk of the noise actually came from.
    /// A closed task is still resolvable by the exact-URL rung, which does not use this list —
    /// opening an old task in the browser is unambiguous evidence regardless of its status.
    public init(companies: [PDCompany], projects: [PDProject], tasks: [PDTask], signals: [EntitySignal]) {
        // Keep every task reachable by id: an OPEN task page in the browser is exact evidence even
        // if the task is closed, and refusing to attribute it would be strictly worse.
        let allTasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let companies = companies.filter { !$0.archived }
        let projects = projects.filter { !$0.archived }
        let tasks = tasks.filter { !$0.closed }
        self.signalsByValue = Dictionary(grouping: signals, by: { $0.signalValue })

        let companyById = Dictionary(companies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projectById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.projectsById = projectById
        self.tasksById = allTasksById
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

    /// Classify a session. `invitees` are supplied for meeting sessions; `pageTexts` and `urls`
    /// optionally add evidence. Returns nil when nothing resolves confidently.
    public func classify(_ session: Session, invitees: [MeetingInvitee] = [],
                         pageTexts: [String] = [], urls: [String] = []) -> Classification? {
        if let exact = rungExactTask(urls) { return exact }
        if let r1 = rung1(session, invitees: invitees) {
            // A signal match resolves the CLIENT; it rarely names a task. Rung 2 can name one, and a
            // time entry needs a task — so preferring rung 1 wholesale trades a more useful answer
            // for a more confident one. Measured live: adding the keyword arm moved 4 sessions from
            // task-level rung-2 attribution to client-only rung-1.
            //
            // When rung 2 independently agrees on the same client AND can be more specific, take its
            // attribution. Two independent signals agreeing is stronger evidence than either alone,
            // so the rung-1 confidence is kept.
            if r1.taskId == nil,
               let r2 = rung2(session, invitees: invitees, pageTexts: pageTexts),
               r2.clientId == r1.clientId, r2.taskId != nil || r2.projectId != nil {
                return Classification(
                    clientId: r1.clientId, projectId: r2.projectId ?? r1.projectId, taskId: r2.taskId,
                    confidence: max(r1.confidence, r2.confidence), rung: r1.rung,
                    rationale: "\(r1.rationale), refined by \(r2.rationale)",
                    matchedSignalType: r1.matchedSignalType, matchedSignalValue: r1.matchedSignalValue)
            }
            return r1
        }
        return rung2(session, invitees: invitees, pageTexts: pageTexts)
    }

    // Rung 1 (exact) — the task was open in the browser, so its id is in the address bar.
    //
    // This outranks signal matching because it is evidence, not inference: no vocabulary, no
    // tokens, no scoring. It also matters disproportionately on a workspace like this one, where
    // the captured hosts are tools (Slack, Productive, EN, BugHerd) rather than client domains, so
    // the documented `url_host -> client` route resolves almost nothing.
    //
    // It is the ONLY path that sets `task_id`, which gap analysis needs to avoid re-suggesting time
    // the user already logged.
    private func rungExactTask(_ urls: [String]) -> Classification? {
        for url in urls {
            guard let id = Classifier.productiveTaskId(in: url), let task = tasksById[id] else { continue }
            let project = task.projectId.isEmpty ? nil : projectsById[task.projectId]
            // A task whose project we cannot resolve to a client is not attributable — do not
            // invent an empty client id, which is what an unlinked mirror produced for weeks.
            guard let clientId = project?.companyId, !clientId.isEmpty else { continue }
            return Classification(
                clientId: clientId, projectId: task.projectId, taskId: task.id,
                confidence: 0.97, rung: 1,
                rationale: "task open in Productive (#\(task.taskNumber.map(String.init) ?? task.id))",
                matchedSignalType: nil, matchedSignalValue: nil)
        }
        return nil
    }

    /// Extract a Productive task id from a web-app URL.
    ///
    /// Both shapes occur live and both must match — captured samples contain
    /// `/2650-acme/task/18833587?taskActivityId=…` **and** `/2650-acme/tasks/task/18609405`:
    ///
    ///     app.productive.io/<org-slug>/task/<id>
    ///     app.productive.io/<org-slug>/tasks/task/<id>
    ///
    /// Deliberately NOT matched: `/tasks?filter=<base64>`, a filtered task LIST. That base64 blob
    /// contains digits and would otherwise yield a bogus id.
    public static func productiveTaskId(in url: String) -> String? {
        guard url.contains("productive.io") else { return nil }
        // Strip query and fragment first so a filter blob can never be scanned for digits.
        let path = url.split(separator: "?").first.map(String.init)?
            .split(separator: "#").first.map(String.init) ?? url
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "task"), i + 1 < parts.count else { return nil }
        let candidate = parts[i + 1]
        guard !candidate.isEmpty, candidate.allSatisfy(\.isNumber) else { return nil }
        return candidate
    }

    // Rung 1 — deterministic signal rules.
    //
    // Two arms, because signals come in two shapes and matching only the first made the second
    // **unreadable**: exact values (`url_host`, `email_domain`) are compared whole, while `keyword`
    // signals are name TOKENS and can never equal a hostname or a Slack conversation id. Bootstrapping
    // 1,185 keyword rows against a rung that only did whole-string lookup produced rows nothing could
    // consume. `docs/architecture/classification-ladder.md` specifies both arms — "context_key **(or
    // dominant token set)**" — and only the first had been built.
    private func rung1(_ session: Session, invitees: [MeetingInvitee]) -> Classification? {
        var values: [String] = []
        if let ck = session.contextKey {
            if ck.hasPrefix("web:") { values.append(String(ck.dropFirst(4))) }
            if ck.hasPrefix("slack:") { values.append(String(ck.dropFirst(6))) }
        }
        values.append(contentsOf: invitees.compactMap { $0.emailDomain })

        let matches = values.flatMap { v in (signalsByValue[v] ?? []).map { (v, $0) } }
            .filter { $0.1.clientId != nil }
        guard !matches.isEmpty else { return rung1Keyword(session) }
        let best = matches.max { a, b in
            (a.1.isAuthoritative ? 1 : 0, a.1.weight) < (b.1.isAuthoritative ? 1 : 0, b.1.weight)
        }!
        let sig = best.1
        return Classification(
            clientId: sig.clientId!, projectId: sig.projectId, taskId: nil,
            confidence: sig.isAuthoritative ? 0.97 : 0.85, rung: 1,
            rationale: "matched \(sig.signalType) '\(best.0)'",
            matchedSignalType: sig.signalType, matchedSignalValue: best.0)
    }

    /// Rung 1, token arm: a `keyword` signal matched against the session's own words.
    ///
    /// Deliberately more conservative than the exact-value arm. A hostname match is unambiguous
    /// evidence; a single word in a window title is weaker, so bootstrapped keyword hits get 0.82
    /// rather than 0.85. A `user_confirmed` keyword is different — the user said so — and keeps 0.97.
    ///
    /// **Disagreement returns nil rather than picking a winner.** The bootstrap already guarantees a
    /// token maps to one client, but a session can contain tokens for two different clients (an
    /// email listing both). Guessing there is exactly the confident-wrong-answer this whole design
    /// avoids; falling through to rung 2, which has its own ambiguity guard, is correct.
    private func rung1Keyword(_ session: Session) -> Classification? {
        var query = Tokenizer.tokenSet([session.title])
        if let ck = session.contextKey, ck.hasPrefix("web:") {
            query.formUnion(Tokenizer.tokens(String(ck.dropFirst(4))))
        }
        guard !query.isEmpty else { return nil }

        let hits = query.flatMap { token in
            (signalsByValue[token] ?? [])
                .filter { $0.signalType == "keyword" && $0.clientId != nil }
                .map { (token, $0) }
        }
        guard !hits.isEmpty else { return nil }

        // A user-confirmed rule outranks everything and settles disagreement by itself.
        if let confirmed = hits.filter({ $0.1.isAuthoritative })
            .max(by: { $0.1.weight < $1.1.weight }) {
            return Classification(
                clientId: confirmed.1.clientId!, projectId: confirmed.1.projectId, taskId: nil,
                confidence: 0.97, rung: 1,
                rationale: "you confirmed '\(confirmed.0)' means this client",
                matchedSignalType: confirmed.1.signalType, matchedSignalValue: confirmed.0)
        }

        guard Set(hits.map { $0.1.clientId! }).count == 1 else { return nil }
        let best = hits.max(by: { $0.1.weight < $1.1.weight })!
        return Classification(
            clientId: best.1.clientId!, projectId: best.1.projectId, taskId: nil,
            confidence: 0.82, rung: 1,
            rationale: "matched keyword '\(best.0)'",
            matchedSignalType: best.1.signalType, matchedSignalValue: best.0)
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
