// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "muxy",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored at 1.3.2 with a local XCFramework: SwiftPM's artifact
        // downloader hangs on this asset, and pinning shields us from
        // upstream libghostty API churn. Refresh via Scripts/fetch-ghostty.sh.
        .package(path: "Vendor/libghostty-spm")
    ],
    targets: [
        .executableTarget(
            name: "muxy",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/muxy"
        )
    ]
)
