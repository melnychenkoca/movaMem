// swift-tools-version: 6.0
import PackageDescription

// The macOS platform floor is REQUIRED, not optional. Without it, Swift Testing's
// @Test macro expands to code that fails with "'isolation()' is only available in
// macOS 10.15 or newer".
let package = Package(
    name: "movaMem",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "movaMem",
            path: "Sources/movaMem"
        ),
        .testTarget(
            name: "movaMemTests",
            dependencies: ["movaMem"],
            path: "Tests/movaMemTests"
        ),
    ]
)
