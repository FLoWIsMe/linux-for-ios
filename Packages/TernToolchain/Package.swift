// swift-tools-version:5.9
// The ios_system framework is the only toolchain binary the app links against directly:
// Tern calls its C API (ios_system, ios_setStreams, ios_switchSession, ...) to run commands.
// All other command frameworks are loaded by ios_system at runtime and are embedded by
// scripts/embed-toolchain.py. Keeping ios_system here lets Swift Package Manager verify the
// checksum and lets Xcode handle linking, embedding and signing.
import PackageDescription

let package = Package(
    name: "TernToolchain",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TernToolchain", targets: ["ios_system"])
    ],
    targets: [
        .binaryTarget(
            name: "ios_system",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_system.xcframework.zip",
            checksum: "c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6"
        )
    ]
)
