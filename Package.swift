// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TimeLens",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic shared by the app and the tests: URL → website, categories, the tracking
        // state machine, bucketing and the stats/insights math.
        .target(name: "TimeLensCore"),

        // The menu bar app, tracker, wellbeing controls and dashboard.
        .executableTarget(
            name: "TimeLens",
            dependencies: ["TimeLensCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        .testTarget(name: "TimeLensTests", dependencies: ["TimeLensCore"]),
    ],
    swiftLanguageModes: [.v5]
)
