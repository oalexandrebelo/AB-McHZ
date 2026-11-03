// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AB-McHZ",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HetzCore", targets: ["HetzCore"]),
        .executable(name: "hetzctl", targets: ["hetzctl"]),
        .executable(name: "AB-McHZ", targets: ["ABMcHZApp"]),
    ],
    targets: [
        .target(name: "HetzCore"),
        .executableTarget(name: "hetzctl", dependencies: ["HetzCore"]),
        .executableTarget(name: "ABMcHZApp", dependencies: ["HetzCore"]),
        .testTarget(name: "HetzCoreTests", dependencies: ["HetzCore"]),
    ]
)
