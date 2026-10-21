// swift-tools-version:5.9
import PackageDescription
import Foundation

// ThirdWavePG — pack and unpack Groove Synthesis 3rd Wave unified program data (.pgdata).
//
//   ThirdWaveFormats   file formats and packing logic; Foundation only, builds on Linux too
//   ThirdWavePG        the macOS app (SwiftUI); declared only when building on macOS
//   tw3pg              developer harness used to verify the library against real files
//
// The test target is opt-in (THIRDWAVE_TESTS=1), as in ThirdWaveWT: on a Mac with only the
// Command Line Tools, SwiftPM fails while looking for XCTest even for a plain `swift build`.
// The app does not need SwiftPM at all — see make-app.sh.

let onLinux: Bool = {
    #if os(Linux)
    return true
    #else
    return false
    #endif
}()
let includeTests = onLinux || ProcessInfo.processInfo.environment["THIRDWAVE_TESTS"] != nil

var targets: [Target] = [
    .target(name: "ThirdWaveFormats"),
    .executableTarget(name: "tw3pg", dependencies: ["ThirdWaveFormats"]),
]
var products: [Product] = [
    .library(name: "ThirdWaveFormats", targets: ["ThirdWaveFormats"]),
    .executable(name: "tw3pg", targets: ["tw3pg"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "ThirdWavePG", dependencies: ["ThirdWaveFormats"]))
products.append(.executable(name: "ThirdWavePG", targets: ["ThirdWavePG"]))
#endif

if includeTests {
    targets.append(.testTarget(name: "ThirdWaveFormatsTests", dependencies: ["ThirdWaveFormats"]))
}

let package = Package(
    name: "ThirdWavePG",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
