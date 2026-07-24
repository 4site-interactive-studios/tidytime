import Foundation
import GRDB

// Read-only Productive cache (Phase 2). String primary keys are the Productive ids, so re-sync is an
// UPSERT (`save`). Column names match docs/architecture/data-model.md.

public struct PDCompany: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pd_companies"
    public var id: String
    public var name: String
    public var companyType: String?
    public var domain: String?
    public var archived: Bool
    public var syncedAt: Int64
    public init(id: String, name: String, companyType: String? = nil, domain: String? = nil,
                archived: Bool = false, syncedAt: Int64) {
        self.id = id; self.name = name; self.companyType = companyType
        self.domain = domain; self.archived = archived; self.syncedAt = syncedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, name, companyType = "company_type", domain, archived, syncedAt = "synced_at"
    }
}

public struct PDProject: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pd_projects"
    public var id: String
    public var companyId: String
    public var name: String
    public var projectTypeId: Int?
    public var projectNumber: String?
    public var archived: Bool
    public var syncedAt: Int64
    public init(id: String, companyId: String, name: String, projectTypeId: Int? = nil,
                projectNumber: String? = nil, archived: Bool = false, syncedAt: Int64) {
        self.id = id; self.companyId = companyId; self.name = name; self.projectTypeId = projectTypeId
        self.projectNumber = projectNumber; self.archived = archived; self.syncedAt = syncedAt
    }
    /// Productive `project_type_id`: 1 = internal, 2 = client/deliverable.
    public var isClientWork: Bool { projectTypeId == 2 }
    enum CodingKeys: String, CodingKey {
        case id, companyId = "company_id", name, projectTypeId = "project_type_id"
        case projectNumber = "project_number", archived, syncedAt = "synced_at"
    }
}

public struct PDTask: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pd_tasks"
    public var id: String
    public var projectId: String
    public var taskListId: String?
    public var title: String
    public var description: String?
    public var taskNumber: Int?
    public var status: String?
    public var closed: Bool
    public var assigneeId: String?
    public var dueDate: String?
    public var syncedAt: Int64
    public init(id: String, projectId: String, taskListId: String? = nil, title: String,
                description: String? = nil, taskNumber: Int? = nil, status: String? = nil,
                closed: Bool = false, assigneeId: String? = nil, dueDate: String? = nil, syncedAt: Int64) {
        self.id = id; self.projectId = projectId; self.taskListId = taskListId; self.title = title
        self.description = description; self.taskNumber = taskNumber; self.status = status
        self.closed = closed; self.assigneeId = assigneeId; self.dueDate = dueDate; self.syncedAt = syncedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, projectId = "project_id", taskListId = "task_list_id", title, description
        case taskNumber = "task_number", status, closed, assigneeId = "assignee_id"
        case dueDate = "due_date", syncedAt = "synced_at"
    }
}

public struct PDTimeEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pd_time_entries"
    public var id: String
    public var personId: String
    public var taskId: String?
    public var projectId: String?
    public var serviceId: String?
    public var date: String
    public var timeMinutes: Int
    public var billableMinutes: Int?
    public var note: String?
    public var syncedAt: Int64
    public init(id: String, personId: String, taskId: String? = nil, projectId: String? = nil,
                serviceId: String? = nil, date: String, timeMinutes: Int, billableMinutes: Int? = nil,
                note: String? = nil, syncedAt: Int64) {
        self.id = id; self.personId = personId; self.taskId = taskId; self.projectId = projectId
        self.serviceId = serviceId; self.date = date; self.timeMinutes = timeMinutes
        self.billableMinutes = billableMinutes; self.note = note; self.syncedAt = syncedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, personId = "person_id", taskId = "task_id", projectId = "project_id"
        case serviceId = "service_id", date, timeMinutes = "time_minutes"
        case billableMinutes = "billable_minutes", note, syncedAt = "synced_at"
    }
}

public struct PDPerson: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pd_people"
    public var id: String
    public var name: String
    public var email: String?
    public var isSelf: Bool
    public var syncedAt: Int64
    public init(id: String, name: String, email: String? = nil, isSelf: Bool = false, syncedAt: Int64) {
        self.id = id; self.name = name; self.email = email; self.isSelf = isSelf; self.syncedAt = syncedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, name, email, isSelf = "is_self", syncedAt = "synced_at"
    }
}
