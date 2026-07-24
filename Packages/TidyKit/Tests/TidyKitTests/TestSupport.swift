import Foundation
import XCTest

/// Shared test helpers.
enum TestSupport {
    /// Repo root, derived from this file's location: .../tidytime/Packages/TidyKit/Tests/TidyKitTests/…
    static func repoRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // file → TidyKitTests → Tests → TidyKit → Packages → root
        return url
    }

    /// A fresh temp directory, auto-removed by `cleanup`.
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidytime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
