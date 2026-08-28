import XCTest
import Foundation
import TidyCore
import TidySurface

/// Papercuts found by actually using the app, not by reading it.
final class DoctorPapercutTests: XCTestCase {

    // MARK: A row must never say "ready" in red

    /// The contradiction: colour said broken, word said fine, reason sat collapsed behind
    /// "How to fix". Whatever the row is coloured, the text has to carry the failure.
    func testReadyWithAnErrorSaysSoInTheRow() {
        let label = DoctorTips.ingestLabel(
            .ready, lastError: "transport error: slack error: channel_not_found")
        XCTAssertNotEqual(label, "ready", "a failing source must not render as the bare word ready")
        XCTAssertTrue(label.contains("last sync failed"))
        XCTAssertTrue(label.contains("channel_not_found"))
    }

    func testReadyWithNoErrorIsUnchanged() {
        XCTAssertEqual(DoctorTips.ingestLabel(.ready, lastError: nil), "ready")
        XCTAssertEqual(DoctorTips.ingestLabel(.ready, lastError: ""), "ready",
                       "an empty error string is not an error")
    }

    /// A source that cannot run keeps its own explanation — the error belongs to the ready case.
    func testNotReadySourcesKeepTheirExplanation() {
        let readiness = IngestCoordinator.Readiness.missingConfig("google.client_id")
        XCTAssertEqual(DoctorTips.ingestLabel(readiness, lastError: "stale error"),
                       readiness.explanation)
    }

    /// A row is one line in a narrow window; the full text stays in the tip below it.
    func testLongErrorsAreTrimmedForTheRow() {
        let long = String(repeating: "x", count: 400)
        let label = DoctorTips.ingestLabel(.ready, lastError: long)
        XCTAssertLessThan(label.count, 100)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    /// Multi-line errors (the new Fathom rate-limit message is a paragraph) must not blow up the row.
    func testMultilineErrorCollapsesToItsFirstClause() {
        let multiline = "fathom rate limit: still refused after 6 attempts over 95s.\nFathom meters transcript reads separately: 30 requests per 60s."
        let label = DoctorTips.ingestLabel(.ready, lastError: multiline)
        XCTAssertFalse(label.contains("\n"), "a row is one line")
        XCTAssertTrue(label.contains("fathom rate limit"))
    }

    // MARK: Tips must say WHERE the button is

    /// "Sync now" exists only in Doctor. The natural place to look is the menu bar popover, which
    /// has no such control — so naming the button without naming its location sends people hunting.
    func testTipsThatNameSyncNowAlsoSayWhereItIs() throws {
        let tip = DoctorTips.tip(for: .slack, readiness: .ready,
                                 lastError: "transport error: slack error: channel_not_found",
                                 configPath: "/tmp/config.json")
        let text = try XCTUnwrap(tip).steps.joined(separator: " ")
        XCTAssertTrue(text.contains("Sync now"))
        XCTAssertTrue(text.contains("Doctor") || text.contains("Sources list"),
                      "naming the button without its location is the papercut")
        XCTAssertTrue(text.contains("popover"),
                      "say explicitly that the menu bar popover does not have it")
    }

    /// The full error still reaches the user, even though the row shows only a summary.
    func testTheTipStillCarriesTheFullError() throws {
        let long = "transport error: " + String(repeating: "detail ", count: 40)
        let tip = DoctorTips.tip(for: .fathom, readiness: .ready, lastError: long,
                                 configPath: "/tmp/config.json")
        let text = try XCTUnwrap(tip).steps.joined(separator: " ")
        XCTAssertTrue(text.contains(long), "the row is trimmed; the tip must not be")
    }
}
