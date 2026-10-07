// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Paddock",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Paddock", targets: ["PaddockApp"]),
        .library(name: "PaddockCore", targets: ["PaddockCore"])
    ],
    targets: [
        .target(name: "PaddockCore"),
        .executableTarget(name: "PaddockApp", dependencies: ["PaddockCore"]),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore"])
    ],
    swiftLanguageModes: [.v6]
)
