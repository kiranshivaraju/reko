// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Reko",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, UI-free logic: script parsing + speech-to-script alignment.
        .target(name: "RekoCore", path: "Sources/RekoCore"),
        // The menu-bar app (AppKit + SwiftUI).
        .executableTarget(name: "Reko", dependencies: ["RekoCore"], path: "Sources/Reko"),
        .testTarget(name: "RekoCoreTests", dependencies: ["RekoCore"], path: "Tests/RekoCoreTests"),
    ]
)
