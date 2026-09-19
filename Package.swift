// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Slopdiff",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Slopdiff", targets: ["Slopdiff"])],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .target(name: "SlopdiffCore"),
        .executableTarget(
            name: "Slopdiff",
            dependencies: ["SlopdiffCore", "Highlightr", .product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources")]),
        .testTarget(name: "SlopdiffCoreTests", dependencies: ["SlopdiffCore"]),
        .testTarget(name: "SlopdiffUITests", dependencies: ["Slopdiff", "SlopdiffCore"])
    ],
    swiftLanguageModes: [.v5]
)
