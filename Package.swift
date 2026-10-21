// swift-tools-version:5.9
import PackageDescription
import Foundation

// pgdata Packer — pack and unpack unified program data (.pgdata) for the Groove Synthesis 3rd Wave.
// Not affiliated with or endorsed by Groove Synthesis.
//
//   PgdataFormats   file formats and packing logic; Foundation only, builds on Linux too
//   PgdataPacker       the macOS app ("pgdata Packer") (SwiftUI); declared only when building on macOS
//   tw3pg              developer harness used to verify the library against real files
//
// The test target is opt-in (PGDATA_TESTS=1), as in ThirdWaveWT: on a Mac with only the
// Command Line Tools, SwiftPM fails while looking for XCTest even for a plain `swift build`.
// The app does not need SwiftPM at all — see make-app.sh.

let onLinux: Bool = {
    #if os(Linux)
    return true
    #else
    return false
    #endif
}()
let includeTests = onLinux || ProcessInfo.processInfo.environment["PGDATA_TESTS"] != nil

var targets: [Target] = [
    .target(name: "PgdataFormats"),
    .executableTarget(name: "tw3pg", dependencies: ["PgdataFormats"]),
]
var products: [Product] = [
    .library(name: "PgdataFormats", targets: ["PgdataFormats"]),
    .executable(name: "tw3pg", targets: ["tw3pg"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "PgdataPacker", dependencies: ["PgdataFormats"]))
products.append(.executable(name: "PgdataPacker", targets: ["PgdataPacker"]))
#endif

if includeTests {
    targets.append(.testTarget(name: "PgdataFormatsTests", dependencies: ["PgdataFormats"]))
}

let package = Package(
    name: "PgdataPacker",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
