// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "McDiff",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "McDiff", targets: ["McDiff"])],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .target(name: "McDiffCore"),
        .executableTarget(
            name: "McDiff",
            dependencies: ["McDiffCore", "Highlightr", .product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources")]),
        .testTarget(name: "McDiffCoreTests", dependencies: ["McDiffCore"]),
        .testTarget(name: "McDiffUITests", dependencies: ["McDiff", "McDiffCore"])
    ],
    swiftLanguageModes: [.v5]
)
