// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClaudeGuard",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GuardDaemon", targets: ["GuardDaemon"]),
        .executable(name: "GuardMenu", targets: ["GuardMenu"]),
        .executable(name: "GuardCLI", targets: ["GuardCLI"]),
        .executable(name: "GuardMock", targets: ["GuardMock"]),
        .library(name: "GuardKit", targets: ["GuardKit"]),
    ],
    targets: [
        .executableTarget(name: "GuardBench", dependencies: ["GuardKit"]),
        .target(
            name: "CProc",
            path: "Sources/CProc",
            publicHeadersPath: "include"
        ),
        .target(
            name: "GuardKit",
            dependencies: ["CProc"],
            path: "Sources/GuardKit"
        ),
        .executableTarget(
            name: "GuardDaemon",
            dependencies: ["GuardKit"],
            path: "Sources/GuardDaemon"
        ),
        .executableTarget(
            name: "GuardMenu",
            dependencies: ["GuardKit"],
            path: "Sources/GuardMenu",
            linkerSettings: [
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "GuardCLI",
            dependencies: ["GuardKit"],
            path: "Sources/GuardCLI"
        ),
        .executableTarget(
            name: "GuardMock",
            path: "Sources/GuardMock"
        ),
        .testTarget(
            name: "GuardKitTests",
            dependencies: ["GuardKit"],
            path: "Tests/GuardKitTests"
        ),
    ]
)
