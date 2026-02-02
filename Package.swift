// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AWDLKiller",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AWDLKiller",
            path: "Sources"
        )
    ]
)
