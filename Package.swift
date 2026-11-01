// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostClipboard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GhostClipboardCore",
            targets: ["GhostClipboardCore"]
        ),
        .executable(
            name: "GhostClipboard",
            targets: ["GhostClipboardApp"]
        ),
        .executable(
            name: "ghostclipboard-cli",
            targets: ["GhostClipboardCLI"]
        )
    ],
    targets: [
        .target(
            name: "GhostClipboardCore",
            path: "Sources/GhostClipboardCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "GhostClipboardApp",
            dependencies: ["GhostClipboardCore"],
            path: "Sources/GhostClipboardApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .executableTarget(
            name: "GhostClipboardCLI",
            dependencies: ["GhostClipboardCore"],
            path: "Sources/GhostClipboardCLI"
        ),
        .executableTarget(
            name: "GhostClipboardTests",
            dependencies: ["GhostClipboardCore"],
            path: "Tests/GhostClipboardTests"
        )
    ]
)
