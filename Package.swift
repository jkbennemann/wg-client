// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WireGuardClient",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "wireguard-client-helper",
            dependencies: ["Shared"],
            path: "Sources/Helper"
        ),
        .executableTarget(
            name: "WireGuardClient",
            dependencies: ["Shared"],
            path: "Sources/App"
        ),
    ]
)
