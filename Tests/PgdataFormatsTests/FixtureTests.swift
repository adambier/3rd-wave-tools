import XCTest
import Foundation
@testable import PgdataFormats

// The published test files in fixtures/: small synthetic files of each kind, with a JSON file
// next to each saying what it parses to. They exist for people writing their own readers and
// writers (see fixtures/README.md). This test keeps them honest: every file must read and write
// back byte for byte and parse to exactly what its JSON says.
//
// To rebuild the files and their JSON after a deliberate change:
//   PGDATA_TESTS=1 PGDATA_REGENERATE_FIXTURES=1 swift test --filter FixtureTests
// The builders use sin(), whose last bit can differ between platforms, so a normal run checks the
// files in the repository rather than rebuilding and comparing bytes.

// MARK: - What each file parses to (the JSON next to it)

struct ProgramSummary: Codable, Equatable {
    var formatTag: String
    var name: String
    var integersPerPart: Int32
    var floatsPerPart: Int32
    var globalValues: Int32
    var eventRecords: Int32
    var programValueCount: Int
    var floatBlocksStartAtValue: Int
    var globalsStartAtValue: Int
    var eventRecordsStartAtValue: Int
    var oscillatorSourceIDs: [Int32]
    var oscillatorSources: [String]
    var part1FirstIntegers: [Int32]
    var part1FirstFloats: [String]
    var firstGlobals: [Int32]
    var events: [[Int32]]
}

struct WavetableSummary: Codable, Equatable {
    var kind: String
    var name: String
    var valueCount: Int
    var firstValues: [Float]
    var wave1FirstValues: [Float]
    var mipmap512FirstValues: [Float]?
    var largestSample: Float
}

struct SampleSummary: Codable, Equatable {
    var name: String
    var length: UInt32
    var sampleRate: Float
    var bitDepthCode: UInt8
    var start: UInt32, end: UInt32, loopStart: UInt32, loopEnd: UInt32
    var rootNote: UInt8, lowNote: UInt8, highNote: UInt8
    var loopMode: UInt8
    var crossfadeLength: UInt32
    var crossfadeType: UInt8
    var pitch: Float
    var secondRate: Float
    var volume: Float
    var firstFrames: [Int16]
}

struct MultisampleSummary: Codable, Equatable {
    var version: Int
    var slotName: String
    var samples: [SampleSummary]
}

struct SourceSummary: Codable, Equatable {
    var index: Int
    var typeCode: UInt8
    var sourceID: Int32
    var slot: String
    var hasData: Bool
    var embeddedName: String?
}

struct UnifiedSummary: Codable, Equatable {
    var programName: String
    var sources: [SourceSummary]
    var programWordCount: Int
    var oscillatorWords: [UInt32]
    var unpackedOscillatorSourceIDs: [Int32]
}

enum Summaries {
    static func ints(_ v: ArraySlice<ProgramFile.Value>) -> [Int32] {
        v.map { if case let .int(x, _) = $0 { return x }; return Int32.min }
    }

    static func program(_ p: ProgramFile) -> ProgramSummary {
        let h = ints(p.values[0..<4])
        let s = Int(h[0]), f = Int(h[1]), g = Int(h[2])
        let floatStart = 4 + 4 * s, globalStart = floatStart + 4 * f, eventStart = globalStart + g
        let ev = ints(p.values[eventStart...])
        return ProgramSummary(
            formatTag: p.version, name: p.name,
            integersPerPart: h[0], floatsPerPart: h[1], globalValues: h[2], eventRecords: h[3],
            programValueCount: p.values.count,
            floatBlocksStartAtValue: floatStart, globalsStartAtValue: globalStart, eventRecordsStartAtValue: eventStart,
            oscillatorSourceIDs: p.sourceIDs, oscillatorSources: p.sources.map(\.label),
            part1FirstIntegers: ints(p.values[4..<14]),
            part1FirstFloats: p.values[floatStart..<(floatStart + 4)].map(\.text),
            firstGlobals: ints(p.values[globalStart..<(globalStart + 6)]),
            events: stride(from: 0, to: ev.count, by: 6).map { Array(ev[$0..<min($0 + 6, ev.count)]) })
    }

    static func wavetable(_ w: WavetableFile) -> WavetableSummary {
        let perWave = w.kind == .p ? 256 : 1024
        return WavetableSummary(
            kind: w.kind.letter, name: w.name, valueCount: w.values.count,
            firstValues: Array(w.values[0..<8]),
            wave1FirstValues: Array(w.values[perWave..<(perWave + 4)]),
            mipmap512FirstValues: w.kind == .u ? Array(w.values[65_536..<65_540]) : nil,
            largestSample: w.peak)
    }

    static func multisample(_ m: Multisample) -> MultisampleSummary {
        MultisampleSummary(version: m.sourceVersion, slotName: m.name, samples: m.samples.map { s in
            let frames = stride(from: 0, to: min(8, s.audio.count), by: 2).map {
                Int16(bitPattern: UInt16(s.audio[$0]) | UInt16(s.audio[$0 + 1]) << 8)
            }
            return SampleSummary(name: s.name.text, length: s.length, sampleRate: s.sampleRate, bitDepthCode: s.bitDepth,
                                 start: s.start, end: s.end, loopStart: s.loopStart, loopEnd: s.loopEnd,
                                 rootNote: s.rootNote, lowNote: s.lowNote, highNote: s.highNote, loopMode: s.loopMode,
                                 crossfadeLength: s.crossfade, crossfadeType: s.crossfadeType, pitch: s.pitch,
                                 secondRate: s.secondRate, volume: s.volume, firstFrames: frames)
        })
    }

    static func unified(_ u: UnifiedProgram) -> UnifiedSummary {
        UnifiedSummary(
            programName: u.programName.text,
            sources: u.sources.enumerated().map { k, src in
                var embedded: String?
                switch src.payload {
                case .none: embedded = nil
                case let .wavetable(name, _): embedded = name.text
                case let .multisample(m): embedded = m.name
                }
                return SourceSummary(index: k, typeCode: src.ref.typeCode, sourceID: src.ref.id, slot: src.ref.label,
                                     hasData: src.hasData, embeddedName: embedded)
            },
            programWordCount: u.words.count,
            oscillatorWords: u.oscillatorWordIndices.map { u.words[$0] },
            unpackedOscillatorSourceIDs: Unpacker.unpack(u).program.sourceIDs)
    }
}

// MARK: - Building the files

enum FixtureBuilder {
    /// A current-layout program (W3_PROG_5, 181/137/182) that uses one source from each id range.
    static func currentProgram() -> ProgramFile {
        let s = 181, f = 137, g = 182
        var ints = Array(repeating: Array(repeating: Int32(0), count: s), count: 4)
        let sources: [[Int32]] = [[0, 34, 41], [1000, 2049, 4000], [2, 35, 42], [2, 35, 42]]
        for k in 0..<4 {
            ints[k][0] = sources[k][0]; ints[k][1] = sources[k][1]; ints[k][2] = sources[k][2]
            ints[k][34] = 100
        }
        var floats = Array(repeating: Array(repeating: Float(0), count: f), count: 4)
        for k in 0..<4 { floats[k][53] = 120; floats[k][124] = 0.5; floats[k][127] = 4 }
        var globals = Array(repeating: Int32(0), count: g)
        globals[0] = 2; globals[1] = 2; globals[24] = 3
        let events: [[Int32]] = [
            [3, 0, 2, 100 * 256 + 60, 0, 0],                                   // a note, parts 1 and 2
            [1, 108, 1, Int32(bitPattern: Float(0.5).bitPattern), 64, 0],      // automation, part 1
        ]
        var v: [ProgramFile.Value] = [.int(Int32(s)), .int(Int32(f)), .int(Int32(g)), .int(Int32(events.count))]
        for p in ints { v += p.map { .int($0) } }
        for p in floats { v += p.map { .float($0) } }
        v += globals.map { .int($0) }
        for e in events { v += e.map { .int($0) } }
        return ProgramFile(version: "W3_PROG_5", name: "Fixture Current", values: v)
    }

    /// A program in the 2022 layout (W3_PROG_3, 173/126/73), with event records that name parts by
    /// number, as such files do.
    static func w3prog3Program() -> ProgramFile {
        let s = 173, f = 126, g = 73
        var ints = Array(repeating: Array(repeating: Int32(0), count: s), count: 4)
        for k in 0..<4 { ints[k][0] = 15; ints[k][1] = 34; ints[k][2] = 41 }
        var floats = Array(repeating: Array(repeating: Float(0), count: f), count: 4)
        for k in 0..<4 { floats[k][53] = 120; floats[k][113] = 0; floats[k][124] = 0.5 }
        var globals = Array(repeating: Int32(0), count: g)
        globals[0] = 2; globals[1] = 5; globals[21] = 60; globals[22] = 60; globals[23] = 60
        globals[24] = 3; globals[25] = 2; globals[26] = 4; globals[27] = 8
        let events: [[Int32]] = [
            [0, 0, 2, 100 * 256 + 60, 0, 0],                                   // a note recorded on part 1
            [1, 108, 1, Int32(bitPattern: Float(0.25).bitPattern), 0, 0],      // automation on part 2
        ]
        var v: [ProgramFile.Value] = [.int(Int32(s)), .int(Int32(f)), .int(Int32(g)), .int(Int32(events.count))]
        for p in ints { v += p.map { .int($0) } }
        for p in floats { v += p.map { .float($0) } }
        v += globals.map { .int($0) }
        for e in events { v += e.map { .int($0) } }
        return ProgramFile(version: "W3_PROG_3", name: "Fixture 2022 Layout", values: v)
    }

    /// A P table: 60 waves morphing from sine to sawtooth, then the PPG's four standard waves.
    static func pTable() -> WavetableFile {
        var vals: [Float] = []
        for w in 0..<64 {
            var wave: [Float] = []
            for i in 0..<128 {
                let x = Double(i) / 128
                let v: Double
                switch w {
                case 60: v = x < 0.25 ? 4 * x : (x < 0.75 ? 2 - 4 * x : 4 * x - 4)    // triangle
                case 61: v = x < 0.125 ? 1 : -1                                       // narrow pulse
                case 62: v = x < 0.5 ? 1 : -1                                         // square
                case 63: v = 2 * x - 1                                                // sawtooth
                default:
                    let t = Double(w) / 59
                    v = (1 - t) * sin(2 * .pi * x) + t * (2 * x - 1)
                }
                wave.append(Float(v))
            }
            for i in 0..<128 { vals.append(wave[i]); vals.append(wave[(i + 1) % 128] - wave[i]) }
        }
        return WavetableFile(kind: .p, name: "Fixture P Sine to Saw", values: vals)
    }

    /// A U table: wave w is a band-limited sawtooth of 1 + w/2 harmonics, followed by the mipmap
    /// chain (512, 256, 128, 64, and 64 samples per wave), each level keeping the harmonics below
    /// its cutoff, as section 5.1 of FORMATS.md recommends a writer do.
    static func uTable() -> WavetableFile {
        let levels: [(size: Int, maxHarmonic: Int)] = [(1024, 384), (512, 192), (256, 96), (128, 48), (64, 24), (64, 3)]
        var out = [[Float]](repeating: [], count: levels.count)
        for w in 0..<64 {
            let harmonics = 1 + w / 2
            func sample(_ i: Int, _ n: Int, _ maxH: Int) -> Double {
                var v = 0.0
                for h in 1...harmonics where h < maxH { v += sin(2 * .pi * Double(h * i) / Double(n)) / Double(h) }
                return v
            }
            var peak = 0.0
            for i in 0..<1024 { peak = max(peak, abs(sample(i, 1024, 384))) }
            let gain = 0.9 / peak
            for (l, level) in levels.enumerated() {
                for i in 0..<level.size { out[l].append(Float(sample(i, level.size, level.maxHarmonic) * gain)) }
            }
        }
        return WavetableFile(kind: .u, name: "Fixture U Saw Harmonics", values: out.flatMap { $0 })
    }

    /// A multisample of two short samples, a sine below middle C and a square from it up. Note
    /// names follow `Multisample.noteName`, which calls middle C (note 60) C3.
    static func multisample() -> Multisample {
        func audio(_ frames: Int, _ f: (Int) -> Double) -> [UInt8] {
            (0..<frames).flatMap { i -> [UInt8] in
                let v = UInt16(bitPattern: Int16(f(i) * 8000))
                return [UInt8(v & 0xff), UInt8(v >> 8)]
            }
        }
        let sine = Multisample.Sample(name: NameField("Fixture Sine C2"), length: 64, start: 0, end: 63, loopStart: 0, loopEnd: 63,
                                      rootNote: 48, lowNote: 0, highNote: 59, loopMode: 2, crossfade: 0, crossfadeType: 0,
                                      audio: audio(64) { sin(2 * .pi * Double($0) / 32) })
        let square = Multisample.Sample(name: NameField("Fixture Square C4"), length: 64, start: 0, end: 63, loopStart: 16, loopEnd: 63,
                                        rootNote: 72, lowNote: 60, highNote: 127, loopMode: 1, crossfade: 4, crossfadeType: 2,
                                        audio: audio(64) { ($0 % 16) < 8 ? 1 : -1 })
        return Multisample(slotName: NameField("Fixture Multisample"), samples: [sine, square])
    }

    /// The current program packed with the U table (in U56) and the multisample (in S00) embedded,
    /// and its factory and analog sources listed without data.
    static func unified() throws -> UnifiedProgram {
        let p = currentProgram()
        var content: [SourceRef: SourceContent] = [:]
        for ref in p.distinctSources where !ref.isBuiltIn { content[ref] = .reference }
        content[.u(56)] = .wavetable(uTable())
        content[.s(0)] = .multisample(multisample())
        return try Packer.pack(p, content: content)
    }
}

// MARK: - The test

final class FixtureTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    enum Kind { case program, wavetable, multisample, unified }
    static let files: [(name: String, kind: Kind)] = [
        ("program-current.pro", .program),
        ("program-2022-layout.pro", .program),
        ("program-2022-layout-converted.pro", .program),
        ("wavetable-p.wt", .wavetable),
        ("wavetable-u.wt", .wavetable),
        ("multisample.bin", .multisample),
        ("unified.pgdata", .unified),
    ]

    func summaryJSON(_ data: Data, _ kind: Kind) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch kind {
        case .program: return try e.encode(Summaries.program(try ProgramFile(data: data)))
        case .wavetable: return try e.encode(Summaries.wavetable(try WavetableFile(data: data)))
        case .multisample: return try e.encode(Summaries.multisample(try Multisample(binData: data)))
        case .unified: return try e.encode(Summaries.unified(try UnifiedProgram(data: data)))
        }
    }

    func expected(_ json: Data, _ kind: Kind, matches data: Data) throws {
        let d = JSONDecoder()
        switch kind {
        case .program: XCTAssertEqual(try d.decode(ProgramSummary.self, from: json), Summaries.program(try ProgramFile(data: data)))
        case .wavetable: XCTAssertEqual(try d.decode(WavetableSummary.self, from: json), Summaries.wavetable(try WavetableFile(data: data)))
        case .multisample: XCTAssertEqual(try d.decode(MultisampleSummary.self, from: json), Summaries.multisample(try Multisample(binData: data)))
        case .unified: XCTAssertEqual(try d.decode(UnifiedSummary.self, from: json), Summaries.unified(try UnifiedProgram(data: data)))
        }
    }

    func reserialized(_ data: Data, _ kind: Kind) throws -> Data {
        switch kind {
        case .program: return try ProgramFile(data: data).serialized()
        case .wavetable: return try WavetableFile(data: data).serialized()
        case .multisample: return try Multisample(binData: data).binData()
        case .unified: return try UnifiedProgram(data: data).serialized()
        }
    }

    func regenerate() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let old = FixtureBuilder.w3prog3Program()
        let built: [String: Data] = [
            "program-current.pro": FixtureBuilder.currentProgram().serialized(),
            "program-2022-layout.pro": old.serialized(),
            "program-2022-layout-converted.pro": try ProgramConverter.convert(old).serialized(),
            "wavetable-p.wt": FixtureBuilder.pTable().serialized(),
            "wavetable-u.wt": FixtureBuilder.uTable().serialized(),
            "multisample.bin": FixtureBuilder.multisample().binData(),
            "unified.pgdata": try FixtureBuilder.unified().serialized(),
        ]
        for (name, kind) in Self.files {
            let data = built[name]!
            try data.write(to: Self.dir.appendingPathComponent(name))
            try summaryJSON(data, kind).write(to: Self.dir.appendingPathComponent(name + ".json"))
        }
    }

    func testFixtures() throws {
        if ProcessInfo.processInfo.environment["PGDATA_REGENERATE_FIXTURES"] != nil { try regenerate() }
        for (name, kind) in Self.files {
            let url = Self.dir.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(try reserialized(data, kind), data, "\(name) does not write back byte for byte")
            try expected(try Data(contentsOf: url.appendingPathExtension("json")), kind, matches: data)
        }
        // The relationships the README describes.
        let current = try Data(contentsOf: Self.dir.appendingPathComponent("program-current.pro"))
        let unified = try UnifiedProgram(data: Data(contentsOf: Self.dir.appendingPathComponent("unified.pgdata")))
        XCTAssertEqual(Unpacker.unpack(unified).program.serialized(), current, "unified.pgdata does not unpack to program-current.pro")
        let old = try ProgramFile(data: Data(contentsOf: Self.dir.appendingPathComponent("program-2022-layout.pro")))
        let converted = try Data(contentsOf: Self.dir.appendingPathComponent("program-2022-layout-converted.pro"))
        XCTAssertEqual(try ProgramConverter.convert(old).serialized(), converted, "the converter no longer gives program-2022-layout-converted.pro")
    }
}
