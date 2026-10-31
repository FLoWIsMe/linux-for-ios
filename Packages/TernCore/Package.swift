// swift-tools-version:5.9
// TernCore is the platform independent heart of Tern: the shell interpreter, the line editor,
// completion, history, syntax highlighting and the interactive session that ties them together.
// It depends on Foundation only, so it builds and tests on macOS and Linux without Xcode.
import PackageDescription

let package = Package(
    name: "TernCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TernCore", targets: ["TernCore"])
    ],
    targets: [
        .target(
            name: "TernCore",
            path: "Sources/TernCore"
        ),
        .testTarget(
            name: "TernCoreTests",
            dependencies: ["TernCore"],
            path: "Tests/TernCoreTests"
        )
    ]
)
