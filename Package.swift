// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTool",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MyTool", targets: ["MyTool"])],
    targets: [
        .target(name: "MyToolKit"),
        .target(name: "MyScreenCore"),
        .target(name: "MyScreen", dependencies: ["MyScreenCore", "MyToolKit"]),
        .target(name: "MyClip", dependencies: ["MyToolKit"]),
        .target(name: "MyActive", dependencies: ["MyToolKit"]),
        .executableTarget(name: "MyTool", dependencies: ["MyToolKit", "MyScreen", "MyClip", "MyActive"]),
        .testTarget(name: "MyToolTests", dependencies: ["MyTool"]),
        .testTarget(name: "MyToolKitTests", dependencies: ["MyToolKit"]),
        .testTarget(name: "MyClipTests", dependencies: ["MyClip"]),
        .testTarget(name: "MyActiveTests", dependencies: ["MyActive"]),
        .testTarget(name: "MyScreenCoreTests", dependencies: ["MyScreenCore"]),
        .testTarget(name: "MyScreenTests", dependencies: ["MyScreen"])
    ],
    swiftLanguageModes: [.v5]
)
