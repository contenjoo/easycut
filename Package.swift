// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EasyCut",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EasyCut",
            path: "Sources/EasyCut"
        )
    ]
)
