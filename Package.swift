// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fivet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "fivet",
            path: "Sources/fivet"
        )
    ]
)
