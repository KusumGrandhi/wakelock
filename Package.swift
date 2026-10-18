// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wakelock",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, testable logic: lease table, socket command parsing, pmset parsing, safety policy.
        .target(name: "WakelockCore", path: "Sources/WakelockCore"),
        // The menu bar app: IOKit, pmset, socket server, SwiftUI.
        .executableTarget(
            name: "Wakelock",
            dependencies: ["WakelockCore"],
            path: "Sources/Wakelock",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Dependency-free test runner (Command Line Tools ship without XCTest).
        .executableTarget(
            name: "WakelockCoreTests",
            dependencies: ["WakelockCore"],
            path: "Tests/WakelockCoreTests"
        ),
    ]
)
