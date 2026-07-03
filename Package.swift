// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AFrameEdit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AFrameKit", targets: ["AFrameKit"]),
        .executable(name: "aframe-capture", targets: ["AFrameCapture"]),
        .executable(name: "AFrameEdit", targets: ["AFrameEditApp"]),
    ],
    targets: [
        .target(name: "AFrameKit", path: "Sources/AFrameKit"),
        .executableTarget(
            name: "AFrameCapture",
            dependencies: ["AFrameKit"],
            path: "Sources/AFrameCapture"
        ),
        .executableTarget(
            name: "AFrameEditApp",
            dependencies: ["AFrameKit"],
            path: "Sources/AFrameEditApp",
            resources: [.process("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "AFrameKitTests",
            dependencies: ["AFrameKit"],
            path: "Tests/AFrameKitTests"
        ),
    ]
)
