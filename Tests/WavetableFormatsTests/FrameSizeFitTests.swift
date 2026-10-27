import XCTest
@testable import WavetableFormats
import PgdataFormats

/// The aid for choosing a frame size: how alike neighboring frames are at each candidate size.
final class FrameSizeFitTests: XCTestCase {
    /// `frames` cycles of `size` samples; frame k is a sine with a little of harmonic 2 + k/8,
    /// so neighboring frames are alike but not identical.
    private func table(frames: Int, size: Int) -> [Float] {
        (0..<frames).flatMap { f -> [Float] in
            let h = Float(2 + f / 8)
            return (0..<size).map { i in
                let x = 2 * Float.pi * Float(i) / Float(size)
                return 0.7 * sin(x) + 0.2 * sin(h * x)
            }
        }
    }

    func testTheRightSizeIsLikelyAndNeitherAFragmentNorAMultipleIs() {
        let samples = table(frames: 64, size: 128)   // 8,192 samples: 64 × 128 or 4 × 2,048
        let ratings = FrameSizeFit.rate(samples, sizes: [128, 2048])
        XCTAssertEqual(ratings.map(\.size), [128, 2048])
        XCTAssertTrue(ratings[0].isPlausible, "\(ratings[0].difference)")
        XCTAssertLessThan(ratings[1].difference, 0.5, "a multiple of the right size also has alike frames")
        XCTAssertFalse(ratings[1].isPlausible, "but no more alike than its half-frames: \(ratings[1].difference) against \(ratings[1].halfDifference)")
        XCTAssertEqual(FrameSizeFit.verdict(samples, sizes: [128, 2048]), .likely(128))

        let serum = table(frames: 4, size: 2048)      // the same length, but 4 frames of 2,048
        let r = FrameSizeFit.rate(serum, sizes: [128, 2048])
        XCTAssertFalse(r[0].isPlausible, "a fragment of a cycle differs from the next fragment: \(r[0].difference)")
        XCTAssertTrue(r[1].isPlausible, "\(r[1].difference)")
        XCTAssertEqual(FrameSizeFit.verdict(serum, sizes: [128, 2048]), .likely(2048))
    }

    func testUnrelatedFramesFitNoSizeAndSilenceSaysNothing() {
        // 64 frames of noise-like, unrelated frames: neither size stands out.
        var seed: UInt32 = 7
        let bank: [Float] = (0..<16_384).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }
        let v = FrameSizeFit.verdict(bank, sizes: [256, 2048])
        XCTAssertNotEqual(v, .likely(256))
        XCTAssertNotEqual(v, .likely(2048))
        XCTAssertEqual(FrameSizeFit.rate([Float](repeating: 0, count: 4096), sizes: [2048]), [])
        XCTAssertEqual(FrameSizeFit.verdict([Float](repeating: 0, count: 4096), sizes: [2048]), .unclear)
        XCTAssertEqual(FrameSizeFit.rate(table(frames: 1, size: 2048), sizes: [2048]), [], "one frame cannot be compared with a next one")
        XCTAssertEqual(FrameSizeFit.likelySize(.likely(128)), 128)
        XCTAssertNil(FrameSizeFit.likelySize(.tie))
    }

    func testAFoundTableRatesTheSizesItsFileLeavesOpen() {
        // No size from the file, 8,192 samples: 64 × 128 or 4 × 2,048; the samples say 128.
        let open = FoundTable(name: "Open", fileName: "Open.wav", source: .wav, samples: table(frames: 64, size: 128),
                              frameSize: nil, frameSizeBasis: "not stated", candidateFrameSizes: [128, 2048])
        XCTAssertEqual(open.frameSizeFit(), .likely(128))
        XCTAssertEqual(open.estimatedFrameSize(), 128)
        XCTAssertNil(open.wavetable(), "nothing chosen: the reader's own view stays open")
        XCTAssertEqual(open.wavetable(frameSize: open.estimatedFrameSize())?.frameSize, 128)
        // The Serum-style convention from the length alone gives way to what the samples say.
        let length = FoundTable(name: "Length", fileName: "Length.wav", source: .wav, samples: table(frames: 64, size: 128),
                                frameSize: 2048, frameSizeBasis: "file length", candidateFrameSizes: [128],
                                frameSizeEvidence: .length)
        XCTAssertEqual(length.frameSizeFit(), .likely(128))
        XCTAssertEqual(length.estimatedFrameSize(), 128)
        // A size the file states is not rated, whatever the samples say.
        let stated = FoundTable(name: "Stated", fileName: "Stated.wav", source: .wav, samples: table(frames: 64, size: 128),
                                frameSize: 2048, frameSizeBasis: "clm chunk", candidateFrameSizes: [128])
        XCTAssertEqual(stated.frameSizeFit(), .unclear)
        XCTAssertEqual(stated.estimatedFrameSize(), 2048)
        // Nothing open and no size: nothing to say.
        let none = FoundTable(name: "None", fileName: "None.wav", source: .wav, samples: table(frames: 3, size: 100),
                              frameSize: nil, frameSizeBasis: "not stated")
        XCTAssertEqual(none.frameSizeFit(), .unclear)
        XCTAssertNil(none.estimatedFrameSize())
    }

    func testTonverkRawSamplesDefaultFollowsTheSourceAndTheMark() {
        let samples = table(frames: 2, size: 128)
        let p = FoundTable(name: "P", fileName: "p.wt", source: .thirdWaveWavetable(isP: true), samples: samples, frameSize: 128, frameSizeBasis: "3rd Wave P table")
        let u = FoundTable(name: "U", fileName: "u.wt", source: .thirdWaveWavetable(isP: false), samples: samples, frameSize: 128, frameSizeBasis: "3rd Wave U table")
        let embeddedP = FoundTable(name: "E", fileName: "e.pgdata", source: .unifiedProgram(slot: "P36", isP: true), samples: samples, frameSize: 128, frameSizeBasis: "3rd Wave P table")
        let marked = FoundTable(name: "M", fileName: "M_wt128r.wav", source: .wav, samples: samples, frameSize: 128, frameSizeBasis: "name",
                                readNotes: [ReadNote(.tonverkRawSamples, "r")])
        let plain = FoundTable(name: "W", fileName: "w.wav", source: .wav, samples: samples, frameSize: 128, frameSizeBasis: "clm chunk")
        XCTAssertEqual([p, u, embeddedP, marked, plain].map(\.tonverkRawSamplesDefault), [true, false, true, true, false])
        // The writer itself leaves nil as false: a caller resolves the default where the FoundTable is.
        let out = try? WavetableWriter.write(p.wavetable()!, preset: .tonverk)
        XCTAssertEqual(out?.fileName, "P_wt128.wav")
        var o = OutputOptions()
        o.tonverkRawSamples = p.tonverkRawSamplesDefault
        XCTAssertEqual(try WavetableWriter.write(p.wavetable()!, preset: .tonverk, options: o).fileName, "P_wt128r.wav")
    }
}
