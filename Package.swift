// swift-tools-version:5.9
import PackageDescription

// ThirdWavePG — pack and unpack Groove Synthesis 3rd Wave unified program data.
//
// ThirdWaveFormats is pure Swift + Foundation so it builds and tests on Linux too.
// The SwiftUI app target is macOS-only and is declared only when building there.

var targets: [Target] = [
    .target(name: "ThirdWaveFormats"),
    .executableTarget(name: "tw3pg", dependencies: ["ThirdWaveFormats"]),
    .testTarget(name: "ThirdWaveFormatsTests", dependencies: ["ThirdWaveFormats"]),
]
var products: [Product] = [
    .library(name: "ThirdWaveFormats", targets: ["ThirdWaveFormats"]),
    .executable(name: "tw3pg", targets: ["tw3pg"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "ThirdWavePG", dependencies: ["ThirdWaveFormats"]))
products.append(.executable(name: "ThirdWavePG", targets: ["ThirdWavePG"]))
#endif

let package = Package(
    name: "ThirdWavePG",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
