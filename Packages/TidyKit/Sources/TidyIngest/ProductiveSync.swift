import Foundation
import TidyCore
import TidyStore

/// Orchestrates a read-only Productive sync into the local cache and records the cursor in
/// `sync_state`. Works against any `ProductiveClient` (live or fake).
public struct ProductiveSync: Sendable {
    private let client: ProductiveClient
    private let db: AppDatabase
    private let clock: TidyClock
    private let selfEmail: String?
    private let logger: TidyLogger?

    public init(client: ProductiveClient, db: AppDatabase, clock: TidyClock = SystemClock(),
                selfEmail: String? = nil, logger: TidyLogger? = nil) {
        self.client = client; self.db = db; self.clock = clock; self.selfEmail = selfEmail
        self.logger = logger
    }

    public struct Summary: Sendable, Equatable {
        public var companies: Int
        public var projects: Int
        public var people: Int
        public var tasks: Int
        public var timeEntries: Int
        public var selfPersonId: String?
    }

    /// Full read-only refresh. `dateRange` bounds the time-entry pull (YYYY-MM-DD strings).
    @discardableResult
    public func run(assigneeId: String? = nil, after: String, before: String) async throws -> Summary {
        let now = Int64(clock.now.timeIntervalSince1970)
        do {
            let companies = try await client.fetchCompanies()
            try db.upsertCompanies(companies)

            let projects = try await client.fetchProjects()
            try db.upsertProjects(projects)

            let people = try await client.fetchPeople()
            try db.upsertPeople(people)

            var selfId: String?
            if let selfEmail {
                selfId = try db.resolveSelf(email: selfEmail)
                if selfId == nil {
                    // Silent here is dangerous: an unresolved self falls through to an org-wide
                    // task fetch and skips time entries entirely, which looks exactly like a
                    // working sync with an empty table. Say so.
                    logger?.error("productive self-email matched no person — falling back", [
                        "email_configured": "yes",
                        "effect": "tasks unfiltered and time entries skipped unless productive_person_id is set",
                    ])
                }
            }

            // The two precedences below are DIFFERENT ON PURPOSE, and unifying them is a bug.
            //
            // Tasks (`assigneeId ?? selfId`) is a fetch-SCOPE question, where an explicit config id
            // is the more specific instruction and reasonably wins.
            //
            // Time entries (`selfId ?? assigneeId`) must agree with what the rest of the app calls
            // "self": `db.selfPerson()` reads `pd_people.is_self`, which is written ONLY by
            // `resolveSelf(email:)` — i.e. from `selfId`. `SuggestionEngine` then queries
            // `timeEntries(personId: selfPersonId)`. Flip this to `assigneeId ?? selfId` and, when
            // the two differ, it queries a person whose entries were never fetched — silently zero
            // logged time. (I tried unifying them; this is why it was reverted.)
            let effectiveAssignee = assigneeId ?? selfId

            let tasks = try await client.fetchTasks(assigneeId: effectiveAssignee)
            try db.upsertTasks(tasks)
            if effectiveAssignee == nil {
                logger?.error("productive has no person id — fetching tasks for the WHOLE organization", [
                    "fix": "set organization.productive_self_email (or productive_person_id) in config.json",
                    "effect": "time entries are skipped and the task fetch may hit its page cap",
                ])
            }

            var entries: [PDTimeEntry] = []
            if let personId = selfId ?? assigneeId {
                entries = try await client.fetchTimeEntries(personId: personId, after: after, before: before)
                try db.upsertTimeEntries(entries)
            }

            try db.saveSyncState(SyncState(source: "productive", cursor: before,
                                           lastRunAt: now, lastSuccessAt: now, lastError: nil))
            return Summary(companies: companies.count, projects: projects.count, people: people.count,
                           tasks: tasks.count, timeEntries: entries.count, selfPersonId: selfId)
        } catch {
            // Record the failure but keep the previous cursor.
            let prior = try? db.syncState("productive")
            try? db.saveSyncState(SyncState(source: "productive", cursor: prior?.cursor,
                                            lastRunAt: now, lastSuccessAt: prior?.lastSuccessAt,
                                            lastError: "\(error)"))
            throw error
        }
    }
}

/// Test double returning canned arrays.
public struct FakeProductiveClient: ProductiveClient {
    public var companies: [PDCompany]
    public var projects: [PDProject]
    public var tasks: [PDTask]
    public var timeEntries: [PDTimeEntry]
    public var people: [PDPerson]

    public init(companies: [PDCompany] = [], projects: [PDProject] = [], tasks: [PDTask] = [],
                timeEntries: [PDTimeEntry] = [], people: [PDPerson] = []) {
        self.companies = companies; self.projects = projects; self.tasks = tasks
        self.timeEntries = timeEntries; self.people = people
    }

    public func fetchCompanies() async throws -> [PDCompany] { companies }
    public func fetchProjects() async throws -> [PDProject] { projects }
    public func fetchTasks(assigneeId: String?) async throws -> [PDTask] {
        guard let assigneeId else { return tasks }
        return tasks.filter { $0.assigneeId == assigneeId }
    }
    public func fetchTimeEntries(personId: String, after: String, before: String) async throws -> [PDTimeEntry] {
        timeEntries.filter { $0.personId == personId && $0.date >= after && $0.date <= before }
    }
    public func fetchPeople() async throws -> [PDPerson] { people }
}

/// Builds the web deep-link for a task from the configured pattern.
///
/// Two different org identifiers exist and they are **not** interchangeable:
/// - `{org}` → the numeric id (`2650`), which is what `X-Organization-Id` requires.
/// - `{org_slug}` → the web URL segment (`2650-4site-interactive-studios-inc`), which is what
///   `app.productive.io` actually routes on.
///
/// The original implementation substituted the numeric id into the web URL and used the path
/// `/task/{id}`. The real shape, confirmed against a live task on 2026-08-28, is
/// `https://app.productive.io/{slug}/tasks/task/{id}` — wrong on both counts, so every link it
/// produced would have 404'd. `{org}` still substitutes exactly as before, so a config that
/// already uses it keeps working.
public enum ProductiveDeepLink {
    /// `nil` when the pattern needs a value the config does not supply — callers **must** hide the
    /// affordance rather than open a URL that cannot resolve.
    ///
    /// Returning `nil` rather than substituting an empty string is deliberate. An empty slug
    /// yields `https://app.productive.io//tasks/task/18609405`: a link that promises a task and
    /// delivers a 404. In an app whose entire posture is "we only show you things, we never write"
    /// (guardrail G1), one dead affordance discredits the suggestion carrying it — and it costs a
    /// context switch to discover. Falling back to the numeric id was also rejected: whether
    /// Productive's router redirects id → slug is an unverified guess, and shipping a guess as a
    /// silent fallback recreates exactly the bug being fixed, failing invisibly.
    public static func url(taskId: String, organizationId: String,
                           organizationSlug: String = "", pattern: String) -> String? {
        let slug = organizationSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskId.isEmpty else { return nil }
        if pattern.contains("{org_slug}"), slug.isEmpty { return nil }
        if pattern.contains("{org}"), id.isEmpty || id == "REPLACE_WITH_ORG_ID" { return nil }
        // Slug first: `{org}` cannot match inside `{org_slug}` (the `}` intervenes), so the order
        // is not load-bearing today — but it is pinned by test so a future token rename can't
        // silently turn `{org_slug}` into `<numeric>_slug`.
        return pattern
            .replacingOccurrences(of: "{org_slug}", with: slug)
            .replacingOccurrences(of: "{org}", with: id)
            .replacingOccurrences(of: "{task_id}", with: taskId)
    }
}
