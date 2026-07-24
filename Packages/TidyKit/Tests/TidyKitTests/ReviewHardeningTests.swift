import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand
import TidySuggest
@testable import TidyIngest
@testable import TidyAI

/// Tests added from the project-wide review (2026-07-24) so each fixed defect is guarded.

// G9: transcript_utterances must age out via the parent meeting's time.
final class TranscriptRetentionTests: XCTestCase {
    func testPurgesOldTranscriptUtterances() throws {
        let db = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        // old meeting (day 5) + utterance; recent meeting (day 99) + utterance
        try db.upsertMeeting(Meeting(id: "old", source: "fathom", recordingStart: Int64(5 * 86_400),
                                     durationSeconds: 60, fetchedAt: 0, createdAt: 0))
        try db.replaceUtterances(meetingId: "old", [TranscriptUtterance(meetingId: "old", idx: 0, startSeconds: 0, text: "secret")])
        try db.upsertMeeting(Meeting(id: "new", source: "fathom", recordingStart: Int64(99 * 86_400),
                                     durationSeconds: 60, fetchedAt: 0, createdAt: 0))
        try db.replaceUtterances(meetingId: "new", [TranscriptUtterance(meetingId: "new", idx: 0, startSeconds: 0, text: "recent")])

        let deleted = try RetentionJob().purge(db, retentionDays: ["transcript_utterances": 90], now: now)
        XCTAssertEqual(deleted["transcript_utterances"], 1)
        XCTAssertEqual(try db.utterances(meetingId: "old").count, 0)   // purged
        XCTAssertEqual(try db.utterances(meetingId: "new").count, 1)   // kept
        // meetings summary rows are retained
        XCTAssertNotNil(try db.meeting(id: "old"))
    }
}

// G2: the gate must never be a no-op, even with an empty/default config.
final class SensitivityGateFloorTests: XCTestCase {
    func testEmptyConfigStillBlocksSensitiveContent() {
        let gate = SensitivityGate(config: Config())   // all sensitivity lists empty
        XCTAssertTrue(gate.isSensitive("the annual salary review"))
        XCTAssertTrue(gate.isSensitive("severance package terms"))
        XCTAssertFalse(gate.isSensitive("reviewed the donation page layout"))
    }
    func testEmptyTermsListStillHasFloor() {
        XCTAssertTrue(SensitivityGate(terms: []).isSensitive("discussed the layoff"))
    }
    func testFloorCanBeDisabledExplicitly() {
        XCTAssertFalse(SensitivityGate(terms: [], includeFloor: false).isSensitive("salary"))
    }
}

// Learning loop: strengthen the SAME signal type that fired (not a hardcoded url_host).
final class LearningSignalTypeTests: XCTestCase {
    func testStrengthensCorrectSignalType() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertCompanies([PDCompany(id: "acme", name: "Acme", syncedAt: 1)])
        // a user-confirmed slack_channel rule
        try db.strengthenSignal(type: "slack_channel", value: "C123", clientId: "acme",
                                projectId: nil, provenance: "user_confirmed", now: 1)
        try db.insertSession(Session(kind: "slack", startedAt: 1000, endedAt: 2000, durationSeconds: 1000,
                                     contextKey: "slack:C123", sourceRef: "C123", createdAt: 0))
        _ = try DayClassifier().run(db, from: 0, to: 100_000, now: 5)

        let signals = try db.signals(values: ["C123"])
        // Only a slack_channel signal for C123 — NOT a bogus url_host row.
        XCTAssertEqual(Set(signals.map(\.signalType)), ["slack_channel"])
        XCTAssertFalse(signals.contains { $0.signalType == "url_host" })
    }
}

// Gap analysis remainder must stay on a 15-minute increment.
final class GapRemainderTests: XCTestCase {
    func testRemainderIsRoundedIncrement() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertPeople([PDPerson(id: "me", name: "B", isSelf: true, syncedAt: 1)])
        try db.upsertTimeEntries([PDTimeEntry(id: "e", personId: "me", taskId: "t1", date: "2026-07-22", timeMinutes: 10, syncedAt: 1)])
        // 40 observed minutes, 10 already logged → ~30 remaining → clean 30 (a 15-multiple).
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 40 * 60, durationSeconds: 40 * 60,
                                     title: "task work", clientId: "acme", projectId: "p1", taskId: "t1",
                                     confidence: 0.9, producedByRung: 1, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)), selfPersonId: "me")
        _ = try engine.generate(day: "2026-07-22", from: 0, to: 1_000_000)
        let s = try db.suggestions(day: "2026-07-22").first
        XCTAssertEqual(s?.minutes, 30)
        XCTAssertEqual((s?.minutes ?? 0) % 15, 0)
    }
}

// meeting_segment kind is actually produced.
final class MeetingSegmentTests: XCTestCase {
    func testMeetingSessionYieldsMeetingSegment() throws {
        let db = try AppDatabase.inMemory()
        try db.insertSession(Session(kind: "meeting", startedAt: 0, endedAt: 30 * 60, durationSeconds: 30 * 60,
                                     title: "Client call", sourceRef: "m1", clientId: "acme", projectId: "p1",
                                     taskId: "t1", confidence: 0.8, producedByRung: 4, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        _ = try engine.generate(day: "2026-07-22", from: 0, to: 1_000_000)
        XCTAssertEqual(try db.suggestions(day: "2026-07-22").first?.kind, "meeting_segment")
    }
}

// Anthropic provider parse + request shape (was uncovered).
final class AnthropicParseTests: XCTestCase {
    func testParsesMessagesResponseAndSendsSchemaInSystem() async throws {
        let json = """
        { "content": [ {"type":"text","text":"14m Client A"}, {"type":"text","text":" · 6m internal"} ],
          "usage": { "input_tokens": 900, "output_tokens": 25 } }
        """
        let http = FakeHTTPClient([.json(json)])
        let provider = AnthropicProvider(http: http, apiKey: "sk-ant")
        let completion = try await provider.complete(model: "claude", systemPrompt: "split this",
                                                     userPrompt: "transcript", jsonSchema: "{\"type\":\"object\"}")
        XCTAssertEqual(completion.text, "14m Client A · 6m internal")
        XCTAssertEqual(completion.inputTokens, 900)
        XCTAssertEqual(completion.outputTokens, 25)
        let req = http.sentRequests[0]
        XCTAssertEqual(req.headers["x-api-key"], "sk-ant")
        XCTAssertEqual(req.headers["anthropic-version"], "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any]
        XCTAssertTrue((body?["system"] as? String)?.contains("\"type\":\"object\"") ?? false)
    }
    func testThrowsOnError() async throws {
        let provider = AnthropicProvider(http: FakeHTTPClient([.json("boom", status: 500)]), apiKey: "k")
        do { _ = try await provider.complete(model: "c", systemPrompt: nil, userPrompt: "x", jsonSchema: nil); XCTFail() }
        catch let IngestError.http(status, _) { XCTAssertEqual(status, 500) }
    }
}

// Fireworks structured-output body + error path (was uncovered).
final class FireworksStructuredOutputTests: XCTestCase {
    func testBuildsResponseFormatAndThrowsOnError() async throws {
        let ok = """
        { "choices": [ { "message": { "content": "{}" } } ], "usage": { "prompt_tokens": 5, "completion_tokens": 3 } }
        """
        let http = FakeHTTPClient([.json(ok)])
        let provider = FireworksProvider(http: http, apiKey: "fw")
        _ = try await provider.complete(model: "kimi", systemPrompt: nil, userPrompt: "classify",
                                        jsonSchema: "{\"type\":\"object\",\"properties\":{}}")
        let body = try JSONSerialization.jsonObject(with: http.sentRequests[0].body ?? Data()) as? [String: Any]
        let rf = body?["response_format"] as? [String: Any]
        XCTAssertEqual(rf?["type"] as? String, "json_schema")
        XCTAssertNotNil((rf?["json_schema"] as? [String: Any])?["schema"])

        let errProvider = FireworksProvider(http: FakeHTTPClient([.json("x", status: 500)]), apiKey: "fw")
        do { _ = try await errProvider.complete(model: "kimi", systemPrompt: nil, userPrompt: "x", jsonSchema: nil); XCTFail() }
        catch let IngestError.http(status, _) { XCTAssertEqual(status, 500) }
    }
}

// Dashboard CSV emits data rows (not just the header).
final class DashboardCSVTests: XCTestCase {
    func testCSVContainsDataRow() throws {
        let db = try AppDatabase.inMemory()
        try db.insertAICall(AICall(occurredAt: 42, jobType: "session_batch", provider: "fireworks",
                                   model: "kimi", inputTokens: 100, outputTokens: 50, costUsd: 0.25, outcome: "ok"))
        let csv = try DashboardBuilder(db: db).csv(from: 0, to: 100)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)  // header + one data row
        XCTAssertTrue(csv.contains("42,session_batch,fireworks,kimi,100,50,0.25,ok"))
    }
}

// RecapAssembler logged-minutes path (was uncovered).
final class RecapLoggedMinutesTests: XCTestCase {
    func testLoggedMinutesFromSelfEntries() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertPeople([PDPerson(id: "me", name: "B", isSelf: true, syncedAt: 1)])
        try db.upsertTimeEntries([
            PDTimeEntry(id: "e1", personId: "me", date: "2026-07-22", timeMinutes: 60, syncedAt: 1),
            PDTimeEntry(id: "e2", personId: "me", date: "2026-07-22", timeMinutes: 15, syncedAt: 1),
        ])
        let assembler = RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)), selfPersonId: "me")
        let recap = try assembler.assemble(day: "2026-07-22", from: 0, to: 1_000_000)
        XCTAssertEqual(recap.loggedMinutes, 75)
        XCTAssertEqual(try assembler.writeRollup(day: "2026-07-22", from: 0, to: 1_000_000).loggedMinutes, 75)
    }
}

// G3: automated guard that no CGWindowList window-name API is used in capture sources.
final class ScreenRecordingGuardrailTests: XCTestCase {
    func testNoCGWindowListInCaptureSources() throws {
        let dir = TestSupport.repoRoot()
            .appendingPathComponent("Packages/TidyKit/Sources/TidyCapture")
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let swift = files.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(swift.isEmpty, "no TidyCapture sources found at \(dir.path)")
        for url in swift {
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Strip line comments so the explanatory comment mentioning CGWindowList doesn't trip this.
            let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("CGWindowList"),
                           "G3 violation: CGWindowList used in \(url.lastPathComponent)")
        }
    }
}
