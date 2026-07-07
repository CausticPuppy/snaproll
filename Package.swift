// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Snaproll",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AFrameKit", targets: ["AFrameKit"]),
        .executable(name: "aframe-capture", targets: ["AFrameCapture"]),
        .executable(name: "Snaproll", targets: ["SnaprollApp"]),
    ],
    targets: [
        .target(name: "AFrameKit", path: "Sources/AFrameKit"),
        .executableTarget(
            name: "AFrameCapture",
            dependencies: ["AFrameKit"],
            path: "Sources/AFrameCapture"
        ),
        .executableTarget(
            name: "SnaprollApp",
            dependencies: ["AFrameKit"],
            path: "Sources/SnaprollApp",
            resources: [.process("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "AFrameKitTests",
            dependencies: ["AFrameKit"],
            path: "Tests/AFrameKitTests"
        ),
    ]
)
