import XCTest
import Foundation
import TidyCore
import TidySurface

/// The recap and the stats were separate windows, which made them feel like separate features. They
/// are two halves of one question — what did I do, and how is the week going — so they are now two
/// tabs of one window, and the menu item you click decides which tab you land on.
final class MainWindowTests: XCTestCase {

    // MARK: The menu item names a tab, not just a window

    func testRecapAndStatsMapToTheirTabs() {
        XCTAssertEqual(MainTab(.recap), .recap)
        XCTAssertEqual(MainTab(.stats), .stats)
    }

    /// Settings and Doctor are their own windows and must not be swallowed into the tabbed one.
    func testOtherWindowsAreNotTabs() {
        XCTAssertNil(MainTab(.settings))
        XCTAssertNil(MainTab(.doctor))
    }

    /// The shell caches one NSWindow per key. If Recap and Stats had distinct keys, clicking the
    /// second menu item would open a duplicate window rather than switching tabs.
    func testRecapAndStatsShareOneWindow() {
        XCTAssertEqual(AppWindow.recap.windowKey, AppWindow.stats.windowKey)
        XCTAssertNotEqual(AppWindow.settings.windowKey, AppWindow.recap.windowKey)
        XCTAssertNotEqual(AppWindow.doctor.windowKey, AppWindow.settings.windowKey)
        XCTAssertEqual(Set(AppWindow.allCases.map(\.windowKey)).count, 3,
                       "four menu items, three windows")
    }

    // MARK: The rename

    /// "Dashboard" named a place in the app, which only helps someone who already knows the app.
    func testTheTabIsCalledStats() {
        XCTAssertEqual(MainTab.stats.title, "Stats")
        XCTAssertEqual(AppWindow.stats.title, "Stats")
        XCTAssertFalse(AppWindow.allCases.map(\.title).contains("Dashboard"))
    }

    func testNoMenuItemStillSaysDashboard() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidySurface/MenuBarPopover.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.contains("Dashboard…"))
        XCTAssertTrue(src.contains("Button(\"Stats…\")"))
        XCTAssertTrue(src.contains("Button(\"Recap…\")"))
    }

    // MARK: The model the menu bar writes to

    /// A `@State` inside the view could not be reached from the menu bar, and rebuilding the window
    /// to change tabs would discard the recap's selected day. Hence a model owned by the shell.
    @MainActor
    func testTheTabIsSettableFromOutsideTheView() {
        let model = MainWindowModel()
        XCTAssertEqual(model.tab, .recap, "opening cold lands on the recap")
        model.tab = MainTab(.stats)!
        XCTAssertEqual(model.tab, .stats)
    }

    /// The shell must set the tab BEFORE fronting an existing window, or clicking "Stats…" on an
    /// open window showing the recap just raises a window still showing the recap.
    func testShellSetsTheTabBeforeFrontingAnExistingWindow() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot().appendingPathComponent("App/TidyTimeApp.swift"),
            encoding: .utf8)
        let setTab = try XCTUnwrap(src.range(of: "mainModel.tab = tab"))
        let frontExisting = try XCTUnwrap(src.range(of: "if let existing = windows[window.windowKey]"))
        XCTAssertLessThan(setTab.lowerBound, frontExisting.lowerBound,
                          "the early-return for an already-open window would skip the tab change")
    }

    /// Both tabs live in one window, so the shell must build MainWindow for either menu item.
    func testShellBuildsTheCombinedWindowForBothItems() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot().appendingPathComponent("App/TidyTimeApp.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("case .recap, .stats: root = AnyView(MainWindow("))
        XCTAssertFalse(src.contains("AnyView(DashboardView(env: env))"),
                       "Stats is reached through the tab now, not as its own window")
    }
}
