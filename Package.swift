// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2.git", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetingAI",
            dependencies: [
                .product(name: "AlibabaCloudOSS", package: "alibabacloud-oss-swift-sdk-v2")
            ],
            path: "Sources"
        )
    ]
)
