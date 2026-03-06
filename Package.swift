// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingAI",
            path: "Sources"
        )
    ]
)
