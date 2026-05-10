// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "OracleCore",
  platforms: [
    // iOS 18 deployment target so this package is testable on stable CI
    // (Xcode 16.2 / macos-latest runners) independently of the app target's
    // iOS 26 deployment target. Pure logic only — no UIKit, no SwiftUI,
    // no iOS 26 APIs.
    .iOS(.v18),
    .macOS(.v15),  // Needed so `swift test` runs on CI without a simulator.
  ],
  products: [
    .library(name: "OracleCore", targets: ["OracleCore"]),
  ],
  targets: [
    .target(
      name: "OracleCore",
      path: "Sources/OracleCore"
    ),
    .testTarget(
      name: "OracleCoreTests",
      dependencies: ["OracleCore"],
      path: "Tests/OracleCoreTests",
      resources: [
        .process("Fixtures"),
      ]
    ),
  ]
)
