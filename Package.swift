// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Goblin",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GoblinCore", targets: ["GoblinCore"]),
        .library(name: "GoblinEngines", targets: ["GoblinEngines"]),
        .executable(name: "GoblinApp", targets: ["GoblinApp"]),
        .executable(name: "goblin", targets: ["GoblinCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "GoblinCore", dependencies: ["CSQLite"]),
        .target(name: "GoblinEngines", dependencies: ["GoblinCore"]),
        .executableTarget(name: "GoblinApp", dependencies: ["GoblinCore", "GoblinEngines"]),
        .executableTarget(name: "GoblinCLI", dependencies: ["GoblinCore", "GoblinEngines"]),
        .executableTarget(name: "HistorySmoke", dependencies: ["GoblinCore", "CSQLite"], path: "Tests/HistorySmoke"),
    ]
)
