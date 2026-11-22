// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Steward",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "StewardKit", targets: ["StewardKit"]),
        .executable(name: "Steward", targets: ["Steward"]),
    ],
    targets: [
        .target(name: "StewardKit"),
        .executableTarget(name: "Steward", dependencies: ["StewardKit"]),
        .testTarget(name: "StewardKitTests", dependencies: ["StewardKit"]),
    ],
    swiftLanguageModes: [.v5]
)
