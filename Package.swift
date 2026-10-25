// swift-tools-version:5.9
import PackageDescription
import Foundation

// 3rd-wave-tools — the pgdata Packer app and a Swift library for the Groove Synthesis 3rd Wave's
// file formats (.pro, .wt, .bin, .pgdata).
// Not affiliated with or endorsed by Groove Synthesis.
//
//   PgdataFormats      the library for other projects: the 3rd Wave's file formats, packing and
//                      unpacking, program conversion, factory table fingerprints; Foundation only,
//                      builds on macOS, Linux, and Windows
//   WavetableFormats   wavetables in the 3rd Wave's and other synths' formats: finding them in files,
//                      resizing them, and writing them for a destination (the Convert tab)
//   PgdataPackerCore   pgdata Packer's own decisions (pack and unpack plans, file names, Clean Up
//                      Names), without UI, for other front ends (a command-line tool, or a GUI on
//                      another platform) that should behave like the app; its API may change more
//                      between versions than PgdataFormats's
//   PgdataPacker       the macOS app ("pgdata Packer") (SwiftUI); declared only when building on macOS
//   tw3pg              developer harness used to verify the library against real files
//
// On a Mac the test target is opt-in (PGDATA_TESTS=1), as in ThirdWaveWT: with only the Command
// Line Tools, SwiftPM fails while looking for XCTest even for a plain `swift build`.
// The app does not need SwiftPM at all — see make-app.sh.

// Only a Mac may lack XCTest (with the Command Line Tools alone), so elsewhere the tests are
// always included.
let onMac: Bool = {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}()
let includeTests = !onMac || ProcessInfo.processInfo.environment["PGDATA_TESTS"] != nil
// The documentation plugin is needed only to build the PgdataFormats documentation site
// (PGDATA_DOCS=1 swift package generate-documentation …); projects that depend on this package
// don't fetch it.
let includeDocsPlugin = ProcessInfo.processInfo.environment["PGDATA_DOCS"] != nil

var targets: [Target] = [
    .target(name: "PgdataFormats"),
    .target(name: "WavetableFormats", dependencies: ["PgdataFormats"]),
    .target(name: "PgdataPackerCore", dependencies: ["PgdataFormats", "WavetableFormats"]),
    .executableTarget(name: "tw3pg", dependencies: ["PgdataFormats", "WavetableFormats", "PgdataPackerCore"]),
]
var products: [Product] = [
    .library(name: "PgdataFormats", targets: ["PgdataFormats"]),
    .library(name: "WavetableFormats", targets: ["WavetableFormats"]),
    .library(name: "PgdataPackerCore", targets: ["PgdataPackerCore"]),
    .executable(name: "tw3pg", targets: ["tw3pg"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "PgdataPacker", dependencies: ["PgdataFormats", "WavetableFormats", "PgdataPackerCore"]))
products.append(.executable(name: "PgdataPacker", targets: ["PgdataPacker"]))
#endif

if includeTests {
    targets.append(.testTarget(name: "PgdataFormatsTests", dependencies: ["PgdataFormats", "WavetableFormats", "PgdataPackerCore"]))
    targets.append(.testTarget(name: "WavetableFormatsTests", dependencies: ["PgdataFormats", "WavetableFormats", "PgdataPackerCore"]))
}

let package = Package(
    name: "3rd-wave-tools",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: includeDocsPlugin
        ? [.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")] : [],
    targets: targets
)
