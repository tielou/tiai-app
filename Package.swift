// swift-tools-version:6.0
import PackageDescription

// tiAiKit builds for macOS as well as iOS, which is not a second product: it
// is what lets `swift build` and `swift test` verify the models, the client
// and the streaming parser on a machine without a simulator. The app target
// is a thin shell over this package.
//
// Consequence, inherited from the tiControl app: no UIKit-only API in
// Sources/TiAiKit. Anything genuinely iOS-only goes behind `#if os(iOS)` in
// Support/Compatibility.swift or into the app target.
//
// Deployment targets are deliberately below what the phones run (iOS 27).
// The kit has to compile with the Command Line Tools SDK on the dev machine
// (macOS 15), and an app built against a newer SDK still gets the newer
// system behaviour on the device. Bumping these is a build-tooling decision,
// not a feature decision.
let package = Package(
    name: "TiAiKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TiAiKit", targets: ["TiAiKit"]),
        .executable(name: "tiaiprobe", targets: ["TiAiProbe"]),
    ],
    dependencies: [
        // The one dependency, and it is load-bearing rather than convenient:
        // when a completion carries a message id, the server writes the reply
        // to the chat and emits the content over socket.io, and the REST body
        // comes back empty. There is no way to get both over REST. See
        // docs/M0-FINDINGS.md -- this was assumed to be an M4 nicety until the
        // probe proved it is the only streaming path.
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.1"),
    ],

    targets: [
        .target(
            name: "TiAiKit",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ]
        ),
        // The M0 spike: a command-line client that exercises the Open WebUI
        // contract end to end against a real server. Kept in the package so
        // `swift run tiaiprobe` works on any machine with the CLT.
        .executableTarget(name: "TiAiProbe", dependencies: ["TiAiKit"]),
        .testTarget(
            name: "TiAiKitTests",
            dependencies: ["TiAiKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
