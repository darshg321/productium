// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "H", platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../../Packages/ProductiumCore")],
  targets: [.executableTarget(name: "H", dependencies: [.product(name: "ProductiumCore", package: "ProductiumCore")])])
