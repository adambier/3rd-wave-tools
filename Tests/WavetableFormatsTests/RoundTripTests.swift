import XCTest
@testable import WavetableFormats

/// Writes a table to every preset with the real writer, reads the result back with the real reader,
/// and checks that what is detected matches what was written.
final class RoundTripTests: XCTestCase {
    /// 64 frames of 2,048 samples: frame f is a sine plus a little of harmonic 2 + f/8.
    private func table(frames: Int = 64, size: Int = 2048, interpolation: Interpolation? = nil) -> Wavetable {
        let fs = (0..<frames).map { f -> [Float] in
            let h = Float(2 + f / 8)
            return (0..<size).map { i in
                let x = 2 * Float.pi * Float(i) / Float(size)
                return 0.7 * sin(x) + 0.2 * sin(h * x)
            }
        }
        return Wavetable(name: "Round Trip", frames: fs, interpolation: interpolation)
    }

    private func readBack(_ out: OutputFile) throws -> FoundTable {
        let found = try WavetableReader.read(out.data, fileName: out.fileName)
        XCTAssertEqual(found.count, 1, out.fileName)
        return try XCTUnwrap(found.first)
    }

    func testEveryPresetReadsBackWithTheSizeItWrote() throws {
        for preset in OutputPreset.allCases {
            let out = try WavetableWriter.write(table(), preset: preset)
            let found = try readBack(out)
            let expectedSize = preset.frameSize ?? 2048
            if preset == .waveEdit {
                // 16,384 samples with no metadata: the reader asks rather than guesses.
                XCTAssertNil(found.frameSize)
                XCTAssertEqual(found.candidateFrameSizes.first, 256)
                XCTAssertEqual(found.wavetable(frameSize: 256)?.frameCount, 64)
                continue
            }
            XCTAssertEqual(found.frameSize, expectedSize, "\(preset)")
            let wt = try XCTUnwrap(found.wavetable(), "\(preset)")
            XCTAssertEqual(wt.frameCount, preset.requiredFrameCount ?? min(64, preset.maxFrameCount), "\(preset)")
            XCTAssertEqual(found.name, "Round Trip", "\(preset)")
        }
    }

    func testInterpolationSurvivesTheWAVPresets() throws {
        for interp in Interpolation.allCases {
            let opts = OutputOptions(interpolation: interp)
            XCTAssertEqual(try readBack(WavetableWriter.write(table(), preset: .wav2048, options: opts)).interpolation, interp)
            let tonverk = try readBack(WavetableWriter.write(table(), preset: .tonverk, options: opts))
            XCTAssertEqual(tonverk.interpolation, interp == Interpolation.none ? Interpolation.none : nil)
        }
    }

    func testTonverkNonDefaultSizeIsReadFromTheName() throws {
        let out = try WavetableWriter.write(table(size: 1024), preset: .tonverk)
        XCTAssertTrue(out.fileName.hasSuffix("_wt1024.wav"), out.fileName)
        let found = try readBack(out)
        XCTAssertEqual(found.frameSize, 1024)
    }

    func testThirdWaveUTableKeepsItsSamplesThroughAWAVAndBack() throws {
        // A 3rd Wave U table converted to a 2,048 WAV and back again keeps its 1,024-sample frames
        // (spectral resizing is exact for periodic cycles within a band-limited table).
        let u = table(size: 1024)
        let wav = try readBack(WavetableWriter.write(u, preset: .wav2048))
        let back = try readBack(WavetableWriter.write(XCTUnwrap(wav.wavetable()), preset: .thirdWaveU))
        let frames = try XCTUnwrap(back.wavetable()).frames
        var worst: Float = 0
        for (a, b) in zip(frames, u.frames) { for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) } }
        XCTAssertLessThan(worst, 1e-4)
    }

    func testPTableWithPPGWavesReadsBackAsA3rdWavePTable() throws {
        let out = try WavetableWriter.write(table(), preset: .thirdWaveP, options: OutputOptions(appendPPGStandardWaves: true))
        let found = try readBack(out)
        XCTAssertEqual(found.source, .thirdWaveWavetable(isP: true))
        let frames = try XCTUnwrap(found.wavetable()).frames
        for (k, wave) in PPGStandardWaves.frames.enumerated() {
            for (x, y) in zip(frames[60 + k], wave) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        }
    }
}
