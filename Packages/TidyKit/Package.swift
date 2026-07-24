// swift-tools-version:6.0
// TidyKit — all TidyTime logic as library targets. The Xcode app target (App/) is a thin
// shell that depends on these products. See docs/architecture/module-map.md.
import PackageDescription

let package = Package(
    name: "TidyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TidyCore", targets: ["TidyCore"]),
        .library(name: "TidyStore", targets: ["TidyStore"]),
        .library(name: "TidyCapture", targets: ["TidyCapture"]),
        .library(name: "TidyIngest", targets: ["TidyIngest"]),
        .library(name: "TidyUnderstand", targets: ["TidyUnderstand"]),
        .library(name: "TidyAI", targets: ["TidyAI"]),
        .library(name: "TidySuggest", targets: ["TidySuggest"]),
        .library(name: "TidySurface", targets: ["TidySurface"]),
    ],
    dependencies: [
        // SQLite toolkit. Confirm the latest 7.x at build time (docs/reference are dated).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TidyCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            exclude: ["README.md"]
        ),
        .target(
            name: "TidyStore",
            dependencies: ["TidyCore", .product(name: "GRDB", package: "GRDB.swift")],
            exclude: ["README.md"]
        ),
        .target(name: "TidyCapture", dependencies: ["TidyCore", "TidyStore"], exclude: ["README.md"]),
        .target(name: "TidyIngest", dependencies: ["TidyCore", "TidyStore"], exclude: ["README.md"]),
        // Understand talks to the AI router through a protocol declared in TidyCore, so it does
        // NOT depend on the TidyAI target — keeps the graph acyclic and Phase 5 buildable
        // before Phase 6 exists.
        .target(name: "TidyUnderstand", dependencies: ["TidyCore", "TidyStore"], exclude: ["README.md"]),
        // TidyAI reuses TidyIngest's HTTP layer (HTTPClient/Backoff) for the cloud providers rather
        // than duplicating it, and depends on TidyUnderstand for the SensitivityGate. Still acyclic.
        .target(name: "TidyAI", dependencies: ["TidyCore", "TidyStore", "TidyIngest", "TidyUnderstand"], exclude: ["README.md"]),
        .target(name: "TidySuggest", dependencies: ["TidyCore", "TidyStore", "TidyUnderstand", "TidyAI"], exclude: ["README.md"]),
        .target(name: "TidySurface", dependencies: ["TidyCore", "TidyStore", "TidySuggest"], exclude: ["README.md"]),
        .testTarget(
            name: "TidyKitTests",
            dependencies: [
                "TidyCore", "TidyStore", "TidyCapture", "TidyIngest",
                "TidyUnderstand", "TidyAI", "TidySuggest", "TidySurface",
            ],
            exclude: ["README.md"]
        ),
    ]
)
