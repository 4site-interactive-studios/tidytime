import XCTest
import Foundation
import TidyCore

final class RedactionTests: XCTestCase {
    func testRedactsBearerToken() {
        let out = Redactor.redact("Authorization: Bearer abc123.def-456")
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertTrue(out.contains(Redactor.mask))
    }

    func testRedactsSlackToken() {
        let out = Redactor.redact("token=xoxp-123-456-secret")
        XCTAssertFalse(out.contains("xoxp-123-456-secret"))
    }

    func testRedactsExplicitSecret() {
        let out = Redactor.redact("the value is HUNTER2 today", secrets: ["HUNTER2"])
        XCTAssertFalse(out.contains("HUNTER2"))
        XCTAssertTrue(out.contains(Redactor.mask))
    }

    func testLeavesOrdinaryTextAlone() {
        let out = Redactor.redact("classified session as Client A / Project X")
        XCTAssertEqual(out, "classified session as Client A / Project X")
    }
}

final class SecretStoreTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.get(SecretKey.productiveToken))
        try store.set(SecretKey.productiveToken, "tok-123")
        XCTAssertEqual(try store.get(SecretKey.productiveToken), "tok-123")
        XCTAssertEqual(try store.allKeys(), [SecretKey.productiveToken])
        try store.delete(SecretKey.productiveToken)
        XCTAssertNil(try store.get(SecretKey.productiveToken))
        XCTAssertEqual(try store.allKeys(), [])
    }
}

final class TidyLogTests: XCTestCase {
    func testInMemorySinkCapturesAndRedacts() {
        let sink = InMemoryLogSink()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let log = TidyLogger(category: "test", sink: sink, clock: clock,
                             secrets: { ["SUPERSECRET"] })
        log.info("synced ok", ["token": "SUPERSECRET", "count": "5"])
        XCTAssertEqual(sink.records.count, 1)
        let r = sink.records[0]
        XCTAssertEqual(r.level, .info)
        XCTAssertEqual(r.category, "test")
        XCTAssertEqual(r.fields["count"], "5")
        XCTAssertEqual(r.fields["token"], Redactor.mask)
        XCTAssertEqual(r.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMinLevelFilters() {
        let sink = InMemoryLogSink()
        let log = TidyLogger(category: "test", sink: sink, minLevel: .warn)
        log.debug("noise")
        log.info("more noise")
        log.warn("real")
        log.error("bad")
        XCTAssertEqual(sink.records.map(\.level), [.warn, .error])
    }

    func testFileSinkWritesJSONLAndTailReadsBack() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("logs/tidytime.jsonl")
        let sink = try FileLogSink(url: url)
        let log = TidyLogger(category: "ingest", sink: sink)
        log.info("first")
        log.warn("second")
        let lines = LogReader.tail(url, lines: 10)
        XCTAssertEqual(lines.count, 2)
        // Each line is valid JSON decoding back to a LogRecord.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(LogRecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(rec.message, "first")
        XCTAssertEqual(rec.category, "ingest")
    }
}

final class HostInfoTests: XCTestCase {
    func testHostInfoNonEmpty() {
        XCTAssertFalse(HostInfo.osVersion.isEmpty)
        XCTAssertEqual(HostInfo.appVersion, TidyTime.version)
        XCTAssertFalse(HostInfo.deviceModel.isEmpty)
    }
}
