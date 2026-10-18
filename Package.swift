// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingMonitor", targets: ["MeetingMonitor"]),
    ],
    targets: [
        .executableTarget(
            name: "MeetingMonitor",
            path: "MeetingMonitor",
            exclude: [
                "Resources/Info.plist",
                "Resources/MeetingMonitor.entitlements",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "MeetingMonitorTests",
            dependencies: ["MeetingMonitor"],
            path: "MeetingMonitorTests",
            // Tests read the fixture from the source tree (#filePath).
            exclude: ["Fixtures"]
        ),
    ]
)
