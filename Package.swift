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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .plugin(name: "BuildIdentity", capability: .buildTool()),
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "GoblinCore", dependencies: ["CSQLite"], plugins: [.plugin(name: "BuildIdentity")]),
        .target(name: "GoblinEngines", dependencies: ["GoblinCore", .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "WhisperKit", package: "argmax-oss-swift")], resources: [.process("Resources")]),
        .executableTarget(name: "GoblinApp", dependencies: ["GoblinCore", "GoblinEngines"], resources: [.copy("Assets")]),
        .executableTarget(name: "GoblinCLI", dependencies: ["GoblinCore", "GoblinEngines", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "GoblinCoreTests", dependencies: ["GoblinCore"]),
        .executableTarget(name: "HistorySmoke", dependencies: ["GoblinCore", "CSQLite"], path: "Tests/HistorySmoke"),
        .executableTarget(name: "DiagnosticsSmoke", dependencies: ["GoblinCore"], path: "Tests/DiagnosticsSmoke"),
        .executableTarget(name: "EvaluationSmoke", dependencies: ["GoblinCore", "GoblinEngines"], path: "Tests/EvaluationSmoke", exclude: ["fixtures"]),
    ]
)
