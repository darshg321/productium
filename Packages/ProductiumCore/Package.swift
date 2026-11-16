// swift-tools-version:5.9
import PackageDescription

// Pure-Foundation planning engine. No UIKit/SwiftUI/HealthKit imports, so it
// builds and tests on Linux (no Mac needed) as well as inside the iOS app.
let package = Package(
    name: "ProductiumCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ProductiumCore", targets: ["ProductiumCore"])],
    targets: [
        .target(name: "ProductiumCore"),
        .testTarget(name: "ProductiumCoreTests", dependencies: ["ProductiumCore"]),
    ]
)
