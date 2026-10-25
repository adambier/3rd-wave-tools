import Foundation
@testable import PgdataFormats

// The synthetic programs and multisample the Core tests pack and plan with. The same builders
// serve the PgdataFormats tests (Tests/PgdataFormatsTests/FormatTests.swift); SwiftPM test targets
// cannot share code, so they are repeated here. Keep the two copies alike.

/// Builds a small but structurally faithful program: S = 181, 4 parts, 520 floats, int tail.
func makeProgram(sources: [Int32], version: String = "W3_PROG_5", floats: Int = 544) -> ProgramFile {
    let s = 181
    var v: [ProgramFile.Value] = [.int(Int32(s))]
    for _ in 0..<(4 * s + 3) { v.append(.int(0)) }
    for i in 0..<floats { v.append(.float(Float(i % 7) * 0.125)) }
    for i in 0..<40 { v.append(.int(Int32(i % 3))) }
    var p = ProgramFile(version: version, name: "Test Prog", values: v)
    for (k, id) in sources.enumerated() { p.setSourceID(id, at: k) }
    return p
}

func makeMultisample() -> Multisample {
    let audio: [UInt8] = (0..<200).map { UInt8($0 & 0xff) }
    let s = Multisample.Sample(name: NameField("Test C2"), length: 100, start: 0, end: 99, loopStart: 10, loopEnd: 90,
                               rootNote: 48, lowNote: 24, highNote: 60, loopMode: 1, crossfade: 5, crossfadeType: 2,
                               audio: audio)
    return Multisample(slotName: NameField("Test"), samples: [s])
}

/// A program in the current layout (181/137/182, no events) whose header adds up.
func makeCurrentProgram(sources: [Int32] = Array(repeating: 42, count: 12)) -> ProgramFile {
    var v: [ProgramFile.Value] = [.int(181), .int(137), .int(182), .int(0)]
    v += Array(repeating: .int(0), count: 4 * 181)
    v += (0..<(4 * 137)).map { .float(Float($0 % 7) * 0.125) }
    v += Array(repeating: .int(0), count: 182)
    var p = ProgramFile(version: "W3_PROG_5", name: "Current", values: v)
    for (k, id) in sources.enumerated() { p.setSourceID(id, at: k) }
    return p
}
