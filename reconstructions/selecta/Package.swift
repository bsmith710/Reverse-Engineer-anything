// swift-tools-version: 6.0
import PackageDescription

// SelectaCore holds every platform-neutral piece of Selecta: the action model,
// template resolution, selection classification, conversions, AI request
// building, and the action engine. It builds and tests on Linux so the logic
// can be verified without Xcode; Apple-only executors are compiled in behind
// `canImport` checks.
let package = Package(
  name: "Selecta",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "SelectaCore", targets: ["SelectaCore"])
  ],
  targets: [
    .target(name: "SelectaCore"),
    .testTarget(name: "SelectaCoreTests", dependencies: ["SelectaCore"]),
  ]
)
