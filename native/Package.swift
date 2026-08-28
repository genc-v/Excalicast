// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Excalicast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Excalicast",
            path: "Sources/excali"
        )
    ]
)
