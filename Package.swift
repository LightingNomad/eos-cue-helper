// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EOSCueHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EOSCueHelper",
            path: "Sources/EOSCueHelper"
        )
    ]
)
