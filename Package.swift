// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "QuotaFloat",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "QuotaFloat", targets: ["QuotaFloat"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/steipete/CodexBar.git",
      revision: "c94b855f308370c503c9f4caad9f1ca4e2151444")
  ],
  targets: [
    .executableTarget(
      name: "QuotaFloat",
      dependencies: [
        .product(name: "CodexBarCore", package: "CodexBar")
      ],
      path: "Sources/QuotaFloat",
      resources: []),
    .testTarget(
      name: "QuotaFloatTests",
      dependencies: ["QuotaFloat"]),
  ])
