import Foundation
import TidyCore
import TidyStore

// MARK: - Attribute payloads (explicit CodingKeys; no convertFromSnakeCase — see JSONAPI.swift)

// Every numeric-ish attribute below is decoded LENIENTLY (see `KeyedDecodingContainer.lenientInt`
// / `.lenientString` in JSONAPI.swift). Productive's reference doc shows `task_number` and
// `status` as integers; the live API sends `task_number` as a string. Rather than flip one type
// and wait to be surprised by the next one, every attribute whose JSON type we have not verified
// against live data accepts both representations and degrades to `nil` instead of throwing.
struct CompanyAttrs: Decodable, Sendable {
    let name: String
    let companyTypeId: Int?
    let domain: String?
    let archivedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, companyTypeId = "company_type_id", domain, archivedAt = "archived_at"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        companyTypeId = c.lenientInt(.companyTypeId)
        domain = c.lenientString(.domain)
        archivedAt = c.lenientTimestamp(.archivedAt)
    }
}
struct ProjectAttrs: Decodable, Sendable {
    let name: String
    let projectTypeId: Int?
    let number: String?
    let archivedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, projectTypeId = "project_type_id", number, archivedAt = "archived_at"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        projectTypeId = c.lenientInt(.projectTypeId)
        // `number` is modelled as a string but is a project number — the same string/int ambiguity
        // that bit `task_number`.
        number = c.lenientString(.number)
        archivedAt = c.lenientTimestamp(.archivedAt)
    }
}
struct TaskAttrs: Decodable, Sendable {
    let title: String
    let description: String?
    let taskNumber: Int?
    let status: String?
    let closedAt: String?
    let dueDate: String?
    enum CodingKeys: String, CodingKey {
        case title, description, taskNumber = "task_number", status
        case closedAt = "closed_at", dueDate = "due_date"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = c.lenientString(.description)
        // THE defect: live API sends this as "412", the doc showed 412.
        taskNumber = c.lenientInt(.taskNumber)
        // The second one, hiding behind the first — Swift decodes in property order, so the throw
        // on `task_number` meant `status` was never reached. The doc's own fixture shows `1`.
        status = c.lenientString(.status)
        // Presence flags, not free text — see lenientTimestamp. `closed` is derived as
        // `closedAt != nil`, so coercing a JSON false into "false" would close every task.
        closedAt = c.lenientTimestamp(.closedAt)
        dueDate = c.lenientTimestamp(.dueDate)
    }
}
struct TimeEntryAttrs: Decodable, Sendable {
    let date: String
    let time: Int
    let billableTime: Int?
    let note: String?
    enum CodingKeys: String, CodingKey { case date, time, billableTime = "billable_time", note }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // `date` is as load-bearing as `time`: an entry with no date cannot be placed on a day,
        // and silently defaulting it to "" would write a row that no day query can ever find.
        // Required, so the element-level skip drops just that entry and counts it.
        date = try c.lenientRequiredString(.date)
        // `time` is the load-bearing value (minutes logged). Lenient about representation, but
        // still REQUIRED: a time entry with no usable duration is not a row worth keeping, and the
        // element-level skip in JSONAPIDocument drops just that entry rather than the whole sync.
        time = try c.lenientRequiredInt(.time)
        billableTime = c.lenientInt(.billableTime)
        note = c.lenientString(.note)
    }
}
struct PersonAttrs: Decodable, Sendable {
    let name: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    enum CodingKeys: String, CodingKey { case name, firstName = "first_name", lastName = "last_name", email }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.lenientString(.name)
        firstName = c.lenientString(.firstName)
        lastName = c.lenientString(.lastName)
        email = c.lenientString(.email)
    }
}

// MARK: - Mapping resource → pd_* record

public enum PDMapper {
    static func company(_ r: JSONAPIResource<CompanyAttrs>, _ syncedAt: Int64) -> PDCompany {
        PDCompany(id: r.id, name: r.attributes.name,
                  companyType: r.attributes.companyTypeId.map(String.init),
                  domain: r.attributes.domain, archived: r.attributes.archivedAt != nil, syncedAt: syncedAt)
    }
    static func project(_ r: JSONAPIResource<ProjectAttrs>, _ syncedAt: Int64) -> PDProject {
        PDProject(id: r.id, companyId: r.relationshipId("company") ?? "", name: r.attributes.name,
                  projectTypeId: r.attributes.projectTypeId, projectNumber: r.attributes.number,
                  archived: r.attributes.archivedAt != nil, syncedAt: syncedAt)
    }
    static func task(_ r: JSONAPIResource<TaskAttrs>, _ syncedAt: Int64) -> PDTask {
        PDTask(id: r.id, projectId: r.relationshipId("project") ?? "",
               taskListId: r.relationshipId("task_list"), title: r.attributes.title,
               description: r.attributes.description, taskNumber: r.attributes.taskNumber,
               status: r.attributes.status, closed: r.attributes.closedAt != nil,
               assigneeId: r.relationshipId("assignee"), dueDate: r.attributes.dueDate, syncedAt: syncedAt)
    }
    static func timeEntry(_ r: JSONAPIResource<TimeEntryAttrs>, _ syncedAt: Int64) -> PDTimeEntry {
        PDTimeEntry(id: r.id, personId: r.relationshipId("person") ?? "",
                    taskId: r.relationshipId("task"), projectId: r.relationshipId("project"),
                    serviceId: r.relationshipId("service"), date: r.attributes.date,
                    timeMinutes: r.attributes.time, billableMinutes: r.attributes.billableTime,
                    note: r.attributes.note, syncedAt: syncedAt)
    }
    static func person(_ r: JSONAPIResource<PersonAttrs>, _ syncedAt: Int64) -> PDPerson {
        let name = r.attributes.name
            ?? [r.attributes.firstName, r.attributes.lastName].compactMap { $0 }.joined(separator: " ")
        return PDPerson(id: r.id, name: name.isEmpty ? "(unknown)" : name,
                        email: r.attributes.email, isSelf: false, syncedAt: syncedAt)
    }
}

// MARK: - Request builder (GET only — guardrail G1)

public struct ProductiveRequestBuilder: Sendable {
    public let baseURL: URL
    public let organizationId: String
    public let token: String

    public init(baseURL: URL, organizationId: String, token: String) {
        self.baseURL = baseURL; self.organizationId = organizationId; self.token = token
    }

    public func get(path: String, query: [URLQueryItem] = []) throws -> HTTPRequest {
        try build(method: "GET", path: path, query: query)
    }

    /// Central build point. **Refuses any non-GET method** so no write can ever be constructed
    /// against Productive (guardrail G1). There is no public non-GET entry point.
    func build(method: String, path: String, query: [URLQueryItem]) throws -> HTTPRequest {
        guard method == "GET" else {
            throw IngestError.readOnlyViolation("Productive is read-only in v1 (G1); refused \(method) \(path)")
        }
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw IngestError.transport("bad URL for \(path)")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw IngestError.transport("bad URL components for \(path)") }
        return HTTPRequest(method: "GET", url: url, headers: [
            "X-Auth-Token": token,
            "X-Organization-Id": organizationId,
            "Content-Type": "application/vnd.api+json",
        ])
    }
}

// MARK: - Client protocol + live implementation

public protocol ProductiveClient: Sendable {
    func fetchCompanies() async throws -> [PDCompany]
    func fetchProjects() async throws -> [PDProject]
    func fetchTasks(assigneeId: String?) async throws -> [PDTask]
    func fetchTimeEntries(personId: String, after: String, before: String) async throws -> [PDTimeEntry]
    func fetchPeople() async throws -> [PDPerson]
}

public struct LiveProductiveClient: ProductiveClient {
    private let http: HTTPClient
    private let builder: ProductiveRequestBuilder
    private let clock: TidyClock
    private let backoff: Backoff
    private let maxRetries: Int
    private let pageSize: Int
    private let sleeper: @Sendable (TimeInterval) async -> Void
    /// Optional so tests stay silent; the app always passes one. Skipped resources are logged at
    /// error level — a mirror that quietly shrinks is worse than one that complains.
    private let logger: TidyLogger?

    public init(http: HTTPClient, builder: ProductiveRequestBuilder, clock: TidyClock = SystemClock(),
                backoff: Backoff = Backoff(), maxRetries: Int = 3, pageSize: Int = 200,
                logger: TidyLogger? = nil,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.logger = logger
        self.http = http; self.builder = builder; self.clock = clock; self.backoff = backoff
        self.maxRetries = maxRetries; self.pageSize = pageSize; self.sleeper = sleeper
    }

    // MARK: Relationship sideloading — the `include` parameter is LOAD-BEARING
    //
    // Productive omits relationship **linkage** entirely unless you ask for it. Verified against
    // the live API on 2026-08-28:
    //
    //   GET /tasks?page[size]=1                  -> "project": {"meta": {"included": false}}
    //   GET /tasks?page[size]=1&include=project  -> "project": {"data": {"type":"projects","id":"16332"}}
    //
    // Without it there is no `data` key, so `JSONAPIResource.relationshipId` correctly returns nil
    // and every foreign key lands as "" — 11,631 tasks belonging to no project, 965 projects to no
    // company, 160 time entries to no task AND no person (despite person being the filter that
    // fetched them). That empties the mirror, which starves classification, which is why the app
    // produced zero suggestions for a month. The parsing was never wrong; we simply never asked.
    //
    // Deliberately NOT adding `fields[…]` sparse fieldsets. The reference doc's samples show them,
    // but narrowing the attribute list is how you silently drop a field you already depend on —
    // the same failure that made `task_number` a type mismatch.
    static let includes: [String: String] = [
        "tasks": "project,assignee,task_list",
        "projects": "company",
        // `project` is here because PDMapper.timeEntry reads it — a time entry logged against a
        // project with no task would otherwise keep a NULL project_id by the very mechanism this
        // whole parameter exists to fix.
        "time_entries": "task,person,service,project",
        // companies and people have no relationship we read.
    ]

    public func fetchCompanies() async throws -> [PDCompany] {
        try await fetchAll(path: "companies", query: [], map: PDMapper.company)
    }
    public func fetchProjects() async throws -> [PDProject] {
        try await fetchAll(path: "projects", query: [], map: PDMapper.project)
    }
    public func fetchTasks(assigneeId: String?) async throws -> [PDTask] {
        var q: [URLQueryItem] = []
        if let assigneeId { q.append(URLQueryItem(name: "filter[assignee_id]", value: assigneeId)) }
        return try await fetchAll(path: "tasks", query: q, map: PDMapper.task)
    }
    public func fetchTimeEntries(personId: String, after: String, before: String) async throws -> [PDTimeEntry] {
        let q = [
            URLQueryItem(name: "filter[person_id]", value: personId),
            URLQueryItem(name: "filter[after]", value: after),
            URLQueryItem(name: "filter[before]", value: before),
        ]
        return try await fetchAll(path: "time_entries", query: q, map: PDMapper.timeEntry)
    }
    public func fetchPeople() async throws -> [PDPerson] {
        try await fetchAll(path: "people", query: [], map: PDMapper.person)
    }

    // MARK: internals

    private func fetchAll<A: Decodable & Sendable, R>(
        path: String, query: [URLQueryItem], map: @Sendable (JSONAPIResource<A>, Int64) -> R
    ) async throws -> [R] {
        let syncedAt = Int64(clock.now.timeIntervalSince1970)
        var out: [R] = []
        var skipped = 0
        var unlinked = 0
        var page = 1
        while true {
            var q = query
            if let include = Self.includes[path] {
                q.append(URLQueryItem(name: "include", value: include))
            }
            q.append(URLQueryItem(name: "page[number]", value: String(page)))
            q.append(URLQueryItem(name: "page[size]", value: String(pageSize)))
            let response = try await sendWithRetry(builder.get(path: path, query: q))
            let doc: JSONAPIDocument<A>
            do {
                doc = try JSONDecoder().decode(JSONAPIDocument<A>.self, from: response.body)
            } catch {
                throw IngestError.decoding("\(path): \(error)")
            }
            out.append(contentsOf: doc.data.map { map($0, syncedAt) })
            skipped += doc.skipped
            // A resource we asked to sideload but that came back with no relationship linkage at all.
            if Self.includes[path] != nil {
                unlinked += doc.data.filter { ($0.relationships?.values.contains { $0.data != nil } ?? false) == false }.count
            }
            // Page-fullness must be judged on RESOURCES RECEIVED, not resources kept. A page whose
            // rows all failed to decode still means "there is more after this"; testing
            // `doc.data.count` alone would silently truncate the walk at the first bad page.
            let received = doc.data.count + doc.skipped
            if let links = doc.links {
                if links.next == nil { break }
            } else if received < pageSize {
                break
            }
            if received == 0 { break }
            page += 1
            if page > 100 {
                // The valve is a runaway guard, not a policy. Hitting it silently returns a
                // truncated array the caller cannot tell from a complete walk — and an unfiltered
                // task fetch reaches it routinely (20,000 rows observed live). Say so.
                logger?.error("productive fetch hit its page cap — results are TRUNCATED", [
                    "path": path, "pages": String(page - 1), "rows": String(out.count),
                    "fix": "narrow the query (set organization.productive_self_email) — this is not a complete sync",
                ])
                break
            }
        }
        if skipped > 0 {
            logger?.error("productive resources skipped — they failed to decode", [
                "path": path, "skipped": String(skipped), "kept": String(out.count),
            ])
        }
        // An empty foreign key is how the severed mirror hid for a month: PDMapper coerces a
        // missing relationship to "" and every downstream join silently matches nothing. If a whole
        // page comes back unlinked, the `include` above is missing or the API changed — say so
        // rather than writing thousands of orphan rows quietly.
        if !out.isEmpty, Self.includes[path] != nil, unlinked == out.count {
            logger?.error("productive rows have NO relationships — the mirror will be unusable", [
                "path": path, "rows": String(out.count),
                "expected_include": Self.includes[path] ?? "",
                "effect": "foreign keys are empty; classification and suggestions cannot work",
            ])
        }
        return out
    }

    private func sendWithRetry(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response = try await http.send(request)
            if response.status == 429, attempt < maxRetries {
                let retryAfter = response.serverRequestedDelay
                await sleeper(backoff.delay(attempt: attempt, retryAfter: retryAfter))
                attempt += 1
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw IngestError.http(status: response.status,
                                       body: String(decoding: response.body, as: UTF8.self))
            }
            return response
        }
    }
}
