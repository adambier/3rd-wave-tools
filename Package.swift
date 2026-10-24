// swift-tools-version:5.9
import PackageDescription
import Foundation

// 3rd-wave-tools — the pgdata Packer app and a Swift library for the Groove Synthesis 3rd Wave's
// file formats (.pro, .wt, .bin, .pgdata).
// Not affiliated with or endorsed by Groove Synthesis.
//
//   PgdataFormats      the library for other projects: the 3rd Wave's file formats, packing and
//                      unpacking, program conversion, factory table fingerprints; Foundation only,
//                      builds on Linux too
//   PgdataPackerCore   the app's own decision logic (pack and unpack plans, file names, Clean Up
//                      Names); UI-free and tested, but not offered as a product
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
    .target(name: "PgdataPackerCore", dependencies: ["PgdataFormats"]),
    .executableTarget(name: "tw3pg", dependencies: ["PgdataFormats", "PgdataPackerCore"]),
]
var products: [Product] = [
    .library(name: "PgdataFormats", targets: ["PgdataFormats"]),
    .executable(name: "tw3pg", targets: ["tw3pg"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "PgdataPacker", dependencies: ["PgdataFormats", "PgdataPackerCore"]))
products.append(.executable(name: "PgdataPacker", targets: ["PgdataPacker"]))
#endif

if includeTests {
    targets.append(.testTarget(name: "PgdataFormatsTests", dependencies: ["PgdataFormats", "PgdataPackerCore"]))
}

let package = Package(
    name: "3rd-wave-tools",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
