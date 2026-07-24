import XCTest
import Foundation
import TidyCore
import TidyStore

final class StoreTests: XCTestCase {
    func testInMemoryOpensAndMigrates() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v1-core"))
        let counts = try db.tableRowCounts()
        XCTAssertEqual(counts["app_metadata"], 0)
    }

    func testMetadataRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        try db.setMetadata(MetadataKey.schemaVersion, "1", clock: clock)
        XCTAssertEqual(try db.metadata(MetadataKey.schemaVersion), "1")
        // upsert overwrites
        try db.setMetadata(MetadataKey.schemaVersion, "2", clock: clock)
        XCTAssertEqual(try db.metadata(MetadataKey.schemaVersion), "2")
        XCTAssertEqual(try db.tableRowCounts()["app_metadata"], 1)
    }

    func testInstallIdIsStable() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let first = try db.installId(clock: clock, makeId: { "fixed-id" })
        XCTAssertEqual(first, "fixed-id")
        // A second call must return the same id, ignoring a new generator.
        let second = try db.installId(clock: clock, makeId: { "different-id" })
        XCTAssertEqual(second, "fixed-id")
    }

    func testOnDiskOpenPersists() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("tidytime.sqlite")
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        do {
            let db = try AppDatabase.open(at: url)
            try db.setMetadata("greeting", "hello", clock: clock)
        }
        // Reopen and confirm the value survived.
        let db2 = try AppDatabase.open(at: url)
        XCTAssertEqual(try db2.metadata("greeting"), "hello")
    }
}
