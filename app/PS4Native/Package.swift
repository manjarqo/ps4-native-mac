// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PS4Native",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "PS4Native", targets: ["PS4Native"])],
    targets: [
        .target(name: "PS4NativeKit"),
        .target(name: "PS4NativeUI", dependencies: ["PS4NativeKit"]),
        .executableTarget(name: "PS4Native", dependencies: ["PS4NativeUI", "PS4NativeKit"]),
        .testTarget(name: "PS4NativeKitTests", dependencies: ["PS4NativeKit", "PS4NativeUI"], resources: [.copy("Fixtures")]),
    ]
)
