// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "RAMPCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RAMPCore", targets: ["RAMPCore"]),
        // Pure hosts-file logic shared by the app and the privileged helper (plan 03-01).
        .library(name: "RAMPHostsKit", targets: ["RAMPHostsKit"]),
        // Dev CLI: install / up / status / reload / paths without the GUI (plan 02-05).
        .executable(name: "rampctl", targets: ["rampctl"]),
    ],
    targets: [
        // Swift 6 language mode implies complete strict concurrency checking.
        .target(name: "RAMPHostsKit"),
        .target(name: "RAMPCore", dependencies: ["RAMPHostsKit"]),
        .executableTarget(name: "rampctl", dependencies: ["RAMPCore"]),
        // Fixtures/mamp: anonymized MAMP PRO confs (plan 07-03), read via #filePath, not bundled.
        .testTarget(name: "RAMPCoreTests", dependencies: ["RAMPCore"], exclude: ["Fixtures/mamp"]),
        .testTarget(name: "RAMPHostsKitTests", dependencies: ["RAMPHostsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
