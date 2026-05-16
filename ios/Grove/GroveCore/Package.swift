// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "GroveCore",
  platforms: [
    // iOS 18 deployment target so this package is testable on stable CI
    // (Xcode 16.2 / macos-latest runners) independently of the app target's
    // iOS 26 deployment target. Pure logic only — no UIKit, no SwiftUI,
    // no iOS 26 APIs.
    .iOS(.v18),
    .macOS(.v15),  // Needed so `swift test` runs on CI without a simulator.
  ],
  products: [
    .library(name: "GroveCore", targets: ["GroveCore"]),
    // Shared test helpers consumed by both GroveCoreTests (SPM) and
    // GroveTests (Xcode). Declared as a regular library target so both
    // test bundles can import it — a .testTarget cannot be shared.
    .library(name: "OracleTestSupport", targets: ["OracleTestSupport"]),
  ],
  targets: [
    .target(
      name: "GroveCore",
      path: "Sources/GroveCore"
    ),
    .target(
      name: "OracleTestSupport",
      path: "Sources/OracleTestSupport"
    ),
    .testTarget(
      name: "GroveCoreTests",
      dependencies: ["GroveCore", "OracleTestSupport"],
      path: "Tests/GroveCoreTests",
      resources: [
        .process("Fixtures"),
      ]
    ),
  ]
)
