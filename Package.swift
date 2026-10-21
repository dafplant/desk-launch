// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "desk-launch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "desk-launch", targets: ["DeskLaunch"])
    ],
    targets: [
        .executableTarget(name: "DeskLaunch", path: "Sources/DeskLaunch")
    ]
)
