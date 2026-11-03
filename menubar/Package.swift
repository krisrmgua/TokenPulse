// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenPulse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TokenPulse", targets: ["TokenPulse"]),
        .library(name: "TokenPulseCore", targets: ["TokenPulseCore"]),
    ],
    targets: [
        .target(
            name: "TokenPulseCore",
            path: "Sources/TokenPulseCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "TokenPulse",
            dependencies: ["TokenPulseCore"],
            path: "Sources/TokenPulse"
        ),
        .testTarget(
            name: "TokenPulseCoreTests",
            dependencies: ["TokenPulseCore"],
            path: "Tests/TokenPulseCoreTests"
        ),
    ]
)
