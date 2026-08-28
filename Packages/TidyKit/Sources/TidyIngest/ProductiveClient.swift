import Foundation
import TidyCore
import TidyStore

// MARK: - Attribute payloads (explicit CodingKeys; no convertFromSnakeCase — see JSONAPI.swift)

struct CompanyAttrs: Decodable, Sendable {
    let name: String
    let companyTypeId: Int?
    let domain: String?
    let archivedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, companyTypeId = "company_type_id", domain, archivedAt = "archived_at"
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
}
struct TimeEntryAttrs: Decodable, Sendable {
    let date: String
    let time: Int
    let billableTime: Int?
    let note: String?
    enum CodingKeys: String, CodingKey { case date, time, billableTime = "billable_time", note }
}
struct PersonAttrs: Decodable, Sendable {
    let name: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    enum CodingKeys: String, CodingKey { case name, firstName = "first_name", lastName = "last_name", email }
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

    public init(http: HTTPClient, builder: ProductiveRequestBuilder, clock: TidyClock = SystemClock(),
                backoff: Backoff = Backoff(), maxRetries: Int = 3, pageSize: Int = 200,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.http = http; self.builder = builder; self.clock = clock; self.backoff = backoff
        self.maxRetries = maxRetries; self.pageSize = pageSize; self.sleeper = sleeper
    }

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
        var page = 1
        while true {
            var q = query
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
            if let links = doc.links {
                if links.next == nil { break }
            } else if doc.data.count < pageSize {
                break
            }
            if doc.data.isEmpty { break }
            page += 1
            if page > 100 { break }  // safety valve
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
