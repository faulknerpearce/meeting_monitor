// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingMonitor", targets: ["MeetingMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingMonitor",
            path: "MeetingMonitor",
            exclude: [
                "Resources/Info.plist",
                "Resources/MeetingMonitor.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Fixtures/meetings_fixture.json")
            ]
        ),
        .testTarget(
            name: "MeetingMonitorTests",
            dependencies: ["MeetingMonitor"],
            path: "MeetingMonitorTests"
        ),
    ]
)
