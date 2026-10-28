// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "CallAssistant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CallAssistant", targets: ["CallAssistant"])],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CallCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CallAssistant", dependencies: ["CallCore", .product(name: "WhisperKit", package: "argmax-oss-swift")], resources: [.copy("Resources/Canvas"), .copy("Resources/Extension"), .copy("Resources/AgentDependencies")]),
        .testTarget(name: "CallCoreTests", dependencies: ["CallCore"]),
        .testTarget(name: "AppTests", dependencies: ["CallAssistant"])
    ]
)
