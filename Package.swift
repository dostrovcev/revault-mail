// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReVaultMail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReVaultMail",
            path: "Sources/ReVaultMail"
        )
    ]
)
