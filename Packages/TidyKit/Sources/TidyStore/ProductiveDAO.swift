import Foundation
import GRDB
import TidyCore

/// Upsert/fetch helpers for the Productive cache. `save` on a string-PK record is an UPSERT, so
/// re-sync overwrites in place.
extension AppDatabase {
    public func upsertCompanies(_ rows: [PDCompany]) throws {
        try writer.write { db in for r in rows { try r.save(db) } }
    }
    public func upsertProjects(_ rows: [PDProject]) throws {
        try writer.write { db in for r in rows { try r.save(db) } }
    }
    public func upsertTasks(_ rows: [PDTask]) throws {
        try writer.write { db in for r in rows { try r.save(db) } }
    }
    public func upsertTimeEntries(_ rows: [PDTimeEntry]) throws {
        try writer.write { db in for r in rows { try r.save(db) } }
    }
    public func upsertPeople(_ rows: [PDPerson]) throws {
        try writer.write { db in for r in rows { try r.save(db) } }
    }

    public func companies() throws -> [PDCompany] {
        try writer.read { db in try PDCompany.order(sql: "name").fetchAll(db) }
    }
    public func projects(companyId: String? = nil) throws -> [PDProject] {
        try writer.read { db in
            if let companyId {
                return try PDProject.filter(sql: "company_id = ?", arguments: [companyId]).fetchAll(db)
            }
            return try PDProject.fetchAll(db)
        }
    }
    public func tasks(projectId: String? = nil) throws -> [PDTask] {
        try writer.read { db in
            if let projectId {
                return try PDTask.filter(sql: "project_id = ?", arguments: [projectId]).fetchAll(db)
            }
            return try PDTask.fetchAll(db)
        }
    }
    public func project(id: String) throws -> PDProject? {
        try writer.read { db in try PDProject.fetchOne(db, key: id) }
    }
    public func company(id: String) throws -> PDCompany? {
        try writer.read { db in try PDCompany.fetchOne(db, key: id) }
    }
    public func task(id: String) throws -> PDTask? {
        try writer.read { db in try PDTask.fetchOne(db, key: id) }
    }
    /// Time entries the user already logged on `date` (YYYY-MM-DD) — the gap-analysis input.
    public func timeEntries(personId: String, date: String) throws -> [PDTimeEntry] {
        try writer.read { db in
            try PDTimeEntry.filter(sql: "person_id = ? AND date = ?", arguments: [personId, date]).fetchAll(db)
        }
    }

    // MARK: person-id resolution (setup)

    /// Mark the person whose email matches as self, clearing any prior self flag. Returns the id.
    @discardableResult
    public func resolveSelf(email: String) throws -> String? {
        try writer.write { db in
            try db.execute(sql: "UPDATE pd_people SET is_self = 0")
            let match = try PDPerson.filter(sql: "lower(email) = ?", arguments: [email.lowercased()]).fetchOne(db)
            guard let match else { return nil }
            try db.execute(sql: "UPDATE pd_people SET is_self = 1 WHERE id = ?", arguments: [match.id])
            return match.id
        }
    }

    public func selfPerson() throws -> PDPerson? {
        try writer.read { db in try PDPerson.filter(sql: "is_self = 1").fetchOne(db) }
    }
}
