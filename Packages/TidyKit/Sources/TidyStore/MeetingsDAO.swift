import Foundation
import GRDB
import TidyCore

extension AppDatabase {
    // MARK: meetings

    public func upsertMeeting(_ meeting: Meeting) throws {
        try writer.write { db in try meeting.save(db) }
    }

    /// Replace a meeting's invitees (delete + insert) so re-sync doesn't duplicate rows.
    public func replaceInvitees(meetingId: String, _ invitees: [MeetingInvitee]) throws {
        try writer.write { db in
            try MeetingInvitee.filter(sql: "meeting_id = ?", arguments: [meetingId]).deleteAll(db)
            for var i in invitees { i.meetingId = meetingId; try i.insert(db) }
        }
    }

    public func replaceUtterances(meetingId: String, _ utterances: [TranscriptUtterance]) throws {
        try writer.write { db in
            try TranscriptUtterance.filter(sql: "meeting_id = ?", arguments: [meetingId]).deleteAll(db)
            for var u in utterances { u.meetingId = meetingId; try u.insert(db) }
        }
    }

    public func meeting(id: String) throws -> Meeting? {
        try writer.read { db in try Meeting.fetchOne(db, key: id) }
    }

    /// Remove any existing `kind='meeting'` session for this meeting, so re-sync doesn't duplicate.
    public func deleteMeetingSession(meetingId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE kind = 'meeting' AND source_ref = ?",
                           arguments: [meetingId])
        }
    }

    public func meetings(from start: Int64, to end: Int64) throws -> [Meeting] {
        try writer.read { db in
            try Meeting
                .filter(sql: "recording_start >= ? AND recording_start < ?", arguments: [start, end])
                .order(sql: "recording_start ASC")
                .fetchAll(db)
        }
    }

    public func invitees(meetingId: String) throws -> [MeetingInvitee] {
        try writer.read { db in
            try MeetingInvitee.filter(sql: "meeting_id = ?", arguments: [meetingId]).fetchAll(db)
        }
    }

    public func utterances(meetingId: String) throws -> [TranscriptUtterance] {
        try writer.read { db in
            try TranscriptUtterance
                .filter(sql: "meeting_id = ?", arguments: [meetingId]).order(sql: "idx ASC").fetchAll(db)
        }
    }

    // MARK: calendar

    public func upsertCalendarEvents(_ events: [CalendarEvent]) throws {
        try writer.write { db in for e in events { try e.save(db) } }
    }

    public func calendarEvents(from start: Int64, to end: Int64) throws -> [CalendarEvent] {
        try writer.read { db in
            try CalendarEvent
                .filter(sql: "start_at >= ? AND start_at < ?", arguments: [start, end])
                .order(sql: "start_at ASC").fetchAll(db)
        }
    }

    /// Delete a cancelled/removed event (Google returns `status == "cancelled"` in incremental sync).
    public func deleteCalendarEvent(id: String) throws {
        _ = try writer.write { db in try CalendarEvent.deleteOne(db, key: id) }
    }

    // MARK: away-gap resolution (away prompt answers)

    /// Resolve an away gap with the user's attribution (break/call/other) + optional client/project.
    public func resolveAwayGap(id: Int64, attribution: String, note: String? = nil,
                               clientId: String? = nil, projectId: String? = nil, resolvedAt: Int64) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE away_gaps SET attribution = ?, note = ?, client_id = ?, project_id = ?, resolved_at = ?
                WHERE id = ?
                """, arguments: [attribution, note, clientId, projectId, resolvedAt, id])
        }
    }

    public func unresolvedAwayGaps(from start: Int64, to end: Int64) throws -> [AwayGap] {
        try writer.read { db in
            try AwayGap
                .filter(sql: "resolved_at IS NULL AND started_at >= ? AND started_at < ?", arguments: [start, end])
                .order(sql: "started_at ASC").fetchAll(db)
        }
    }
}
