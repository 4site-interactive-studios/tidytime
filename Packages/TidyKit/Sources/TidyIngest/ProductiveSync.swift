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

    public init(client: ProductiveClient, db: AppDatabase, clock: TidyClock = SystemClock(),
                selfEmail: String? = nil) {
        self.client = client; self.db = db; self.clock = clock; self.selfEmail = selfEmail
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
            if let selfEmail { selfId = try db.resolveSelf(email: selfEmail) }
            let effectiveAssignee = assigneeId ?? selfId

            let tasks = try await client.fetchTasks(assigneeId: effectiveAssignee)
            try db.upsertTasks(tasks)

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
public enum ProductiveDeepLink {
    public static func url(taskId: String, organizationId: String, pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "{org}", with: organizationId)
            .replacingOccurrences(of: "{task_id}", with: taskId)
    }
}
