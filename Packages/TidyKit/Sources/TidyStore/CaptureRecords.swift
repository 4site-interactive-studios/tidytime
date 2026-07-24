import Foundation
import GRDB

// GRDB records for the Phase 1 (capture) tables. Column names match docs/architecture/data-model.md
// exactly via CodingKeys. Integer ids are auto-assigned on insert (`didInsert`).

public struct ActivitySample: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "activity_samples"
    public var id: Int64?
    public var startedAt: Int64
    public var endedAt: Int64?
    public var appBundleId: String
    public var appName: String
    public var windowTitle: String?
    public var isBrowser: Bool
    public var browser: String?
    public var url: String?
    public var source: String        // 'switch' | 'heartbeat'
    public var createdAt: Int64

    public init(id: Int64? = nil, startedAt: Int64, endedAt: Int64? = nil, appBundleId: String,
                appName: String, windowTitle: String? = nil, isBrowser: Bool = false,
                browser: String? = nil, url: String? = nil, source: String = "switch", createdAt: Int64) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.appBundleId = appBundleId; self.appName = appName; self.windowTitle = windowTitle
        self.isBrowser = isBrowser; self.browser = browser; self.url = url
        self.source = source; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, startedAt = "started_at", endedAt = "ended_at", appBundleId = "app_bundle_id"
        case appName = "app_name", windowTitle = "window_title", isBrowser = "is_browser"
        case browser, url, source, createdAt = "created_at"
    }
}

public struct PageSnapshot: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "page_snapshots"
    public var id: Int64?
    public var sampleId: Int64
    public var capturedAt: Int64
    public var url: String
    public var title: String?
    public var contentHash: String
    public var text: String
    public var textBytes: Int

    public init(id: Int64? = nil, sampleId: Int64, capturedAt: Int64, url: String, title: String? = nil,
                contentHash: String, text: String, textBytes: Int) {
        self.id = id; self.sampleId = sampleId; self.capturedAt = capturedAt; self.url = url
        self.title = title; self.contentHash = contentHash; self.text = text; self.textBytes = textBytes
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, sampleId = "sample_id", capturedAt = "captured_at", url, title
        case contentHash = "content_hash", text, textBytes = "text_bytes"
    }
}

public struct Session: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "sessions"
    public var id: Int64?
    public var kind: String              // 'screen' | 'meeting' | 'slack'
    public var startedAt: Int64
    public var endedAt: Int64
    public var durationSeconds: Int
    public var title: String?
    public var contextKey: String?
    public var primaryApp: String?
    public var sourceRef: String?
    public var clientId: String?
    public var projectId: String?
    public var taskId: String?
    public var confidence: Double?
    public var producedByRung: Int?
    public var rationale: String?
    public var isSensitive: Bool
    public var classifiedAt: Int64?
    public var createdAt: Int64

    public init(id: Int64? = nil, kind: String, startedAt: Int64, endedAt: Int64, durationSeconds: Int,
                title: String? = nil, contextKey: String? = nil, primaryApp: String? = nil,
                sourceRef: String? = nil, clientId: String? = nil, projectId: String? = nil,
                taskId: String? = nil, confidence: Double? = nil, producedByRung: Int? = nil,
                rationale: String? = nil, isSensitive: Bool = false, classifiedAt: Int64? = nil,
                createdAt: Int64) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.durationSeconds = durationSeconds; self.title = title; self.contextKey = contextKey
        self.primaryApp = primaryApp; self.sourceRef = sourceRef; self.clientId = clientId
        self.projectId = projectId; self.taskId = taskId; self.confidence = confidence
        self.producedByRung = producedByRung; self.rationale = rationale; self.isSensitive = isSensitive
        self.classifiedAt = classifiedAt; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, kind, startedAt = "started_at", endedAt = "ended_at", durationSeconds = "duration_seconds"
        case title, contextKey = "context_key", primaryApp = "primary_app", sourceRef = "source_ref"
        case clientId = "client_id", projectId = "project_id", taskId = "task_id", confidence
        case producedByRung = "produced_by_rung", rationale, isSensitive = "is_sensitive"
        case classifiedAt = "classified_at", createdAt = "created_at"
    }
}

public struct AwayGap: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "away_gaps"
    public var id: Int64?
    public var startedAt: Int64
    public var endedAt: Int64
    public var durationSeconds: Int
    public var cause: String          // 'idle' | 'lock' | 'sleep'
    public var attribution: String?   // 'break' | 'call' | 'other'
    public var note: String?
    public var clientId: String?
    public var projectId: String?
    public var resolvedAt: Int64?
    public var createdAt: Int64

    public init(id: Int64? = nil, startedAt: Int64, endedAt: Int64, durationSeconds: Int, cause: String,
                attribution: String? = nil, note: String? = nil, clientId: String? = nil,
                projectId: String? = nil, resolvedAt: Int64? = nil, createdAt: Int64) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.durationSeconds = durationSeconds; self.cause = cause; self.attribution = attribution
        self.note = note; self.clientId = clientId; self.projectId = projectId
        self.resolvedAt = resolvedAt; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, startedAt = "started_at", endedAt = "ended_at", durationSeconds = "duration_seconds"
        case cause, attribution, note, clientId = "client_id", projectId = "project_id"
        case resolvedAt = "resolved_at", createdAt = "created_at"
    }
}

public struct SyncState: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "sync_state"
    public var source: String         // PK: 'productive' | 'fathom' | 'google_calendar' | 'slack:<conv>'
    public var cursor: String?
    public var lastRunAt: Int64?
    public var lastSuccessAt: Int64?
    public var lastError: String?

    public init(source: String, cursor: String? = nil, lastRunAt: Int64? = nil,
                lastSuccessAt: Int64? = nil, lastError: String? = nil) {
        self.source = source; self.cursor = cursor; self.lastRunAt = lastRunAt
        self.lastSuccessAt = lastSuccessAt; self.lastError = lastError
    }
    enum CodingKeys: String, CodingKey {
        case source, cursor, lastRunAt = "last_run_at", lastSuccessAt = "last_success_at"
        case lastError = "last_error"
    }
}
