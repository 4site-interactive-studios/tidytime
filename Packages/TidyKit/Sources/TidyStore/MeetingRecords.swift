import Foundation
import GRDB

// Phase 3 records: meetings + invitees + transcript utterances + calendar events.
// Column names match docs/architecture/data-model.md.

public struct Meeting: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "meetings"
    public var id: String                 // Fathom recording id (stringified) or 'cal:<eventid>'
    public var source: String             // 'fathom' | 'calendar'
    public var title: String?
    public var scheduledStart: Int64?
    public var scheduledEnd: Int64?
    public var recordingStart: Int64?
    public var recordingEnd: Int64?
    public var durationSeconds: Int        // recording span if present, else scheduled
    public var hasTranscript: Bool
    public var hasSummary: Bool
    public var summary: String?
    public var externalUrl: String?
    public var calendarEventId: String?
    public var fetchedAt: Int64
    public var createdAt: Int64
    public init(id: String, source: String, title: String? = nil, scheduledStart: Int64? = nil,
                scheduledEnd: Int64? = nil, recordingStart: Int64? = nil, recordingEnd: Int64? = nil,
                durationSeconds: Int, hasTranscript: Bool = false, hasSummary: Bool = false,
                summary: String? = nil, externalUrl: String? = nil, calendarEventId: String? = nil,
                fetchedAt: Int64, createdAt: Int64) {
        self.id = id; self.source = source; self.title = title; self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd; self.recordingStart = recordingStart; self.recordingEnd = recordingEnd
        self.durationSeconds = durationSeconds; self.hasTranscript = hasTranscript; self.hasSummary = hasSummary
        self.summary = summary; self.externalUrl = externalUrl; self.calendarEventId = calendarEventId
        self.fetchedAt = fetchedAt; self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey {
        case id, source, title, scheduledStart = "scheduled_start", scheduledEnd = "scheduled_end"
        case recordingStart = "recording_start", recordingEnd = "recording_end"
        case durationSeconds = "duration_seconds", hasTranscript = "has_transcript"
        case hasSummary = "has_summary", summary, externalUrl = "external_url"
        case calendarEventId = "calendar_event_id", fetchedAt = "fetched_at", createdAt = "created_at"
    }
}

public struct MeetingInvitee: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "meeting_invitees"
    public var id: Int64?
    public var meetingId: String
    public var email: String?
    public var name: String?
    public var emailDomain: String?
    public var isExternal: Bool
    public init(id: Int64? = nil, meetingId: String, email: String? = nil, name: String? = nil,
                emailDomain: String? = nil, isExternal: Bool = false) {
        self.id = id; self.meetingId = meetingId; self.email = email; self.name = name
        self.emailDomain = emailDomain; self.isExternal = isExternal
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, meetingId = "meeting_id", email, name, emailDomain = "email_domain", isExternal = "is_external"
    }
}

public struct TranscriptUtterance: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "transcript_utterances"
    public var id: Int64?
    public var meetingId: String
    public var idx: Int
    public var speaker: String?
    public var speakerEmail: String?
    public var startSeconds: Double
    public var endSeconds: Double?
    public var text: String
    public init(id: Int64? = nil, meetingId: String, idx: Int, speaker: String? = nil,
                speakerEmail: String? = nil, startSeconds: Double, endSeconds: Double? = nil, text: String) {
        self.id = id; self.meetingId = meetingId; self.idx = idx; self.speaker = speaker
        self.speakerEmail = speakerEmail; self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.text = text
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, meetingId = "meeting_id", idx, speaker, speakerEmail = "speaker_email"
        case startSeconds = "start_seconds", endSeconds = "end_seconds", text
    }
}

public struct CalendarEvent: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "calendar_events"
    public var id: String
    public var calendarId: String
    public var title: String?
    public var description: String?
    public var location: String?
    public var startAt: Int64
    public var endAt: Int64
    public var allDay: Bool
    public var status: String?
    public var organizerEmail: String?
    public var attendeesJson: String?
    public var conferenceUrl: String?
    public var icalUid: String?
    public var updatedAt: Int64?
    public var fetchedAt: Int64
    public init(id: String, calendarId: String, title: String? = nil, description: String? = nil,
                location: String? = nil, startAt: Int64, endAt: Int64, allDay: Bool = false,
                status: String? = nil, organizerEmail: String? = nil, attendeesJson: String? = nil,
                conferenceUrl: String? = nil, icalUid: String? = nil, updatedAt: Int64? = nil, fetchedAt: Int64) {
        self.id = id; self.calendarId = calendarId; self.title = title; self.description = description
        self.location = location; self.startAt = startAt; self.endAt = endAt; self.allDay = allDay
        self.status = status; self.organizerEmail = organizerEmail; self.attendeesJson = attendeesJson
        self.conferenceUrl = conferenceUrl; self.icalUid = icalUid; self.updatedAt = updatedAt; self.fetchedAt = fetchedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, calendarId = "calendar_id", title, description, location
        case startAt = "start_at", endAt = "end_at", allDay = "all_day", status
        case organizerEmail = "organizer_email", attendeesJson = "attendees_json"
        case conferenceUrl = "conference_url", icalUid = "ical_uid", updatedAt = "updated_at", fetchedAt = "fetched_at"
    }
}
