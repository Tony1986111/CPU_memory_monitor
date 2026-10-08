// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CPUMemoryMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CPUMemoryMonitor", path: "Sources")
    ]
)
