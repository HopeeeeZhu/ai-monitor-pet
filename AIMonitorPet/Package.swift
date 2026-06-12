// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMonitorPet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AIMonitorPet",
            targets: ["AIMonitorPet"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AIMonitorPet",
            dependencies: []
        ),
    ]
)
