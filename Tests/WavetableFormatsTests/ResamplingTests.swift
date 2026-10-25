import XCTest
@testable import WavetableFormats

/// The band-limited cycle resize (the first seven tests are ported from ThirdWaveWT's
/// CycleResamplerTests), frame-count policies, the U table mipmap chain, and the PPG waves.
final class ResamplingTests: XCTestCase {
    private func sine(_ n: Int, amplitude: Float = 1, phase: Float = 0, harmonic: Int = 1) -> [Float] {
        (0..<n).map { amplitude * sin(2 * .pi * Float(harmonic * $0) / Float(n) + phase) }
    }

    /// A sum of harmonics 1…`count` with amplitudes 1/h and phases 0.7·h, evaluated at n points.
    private func rich(_ n: Int, harmonics count: Int) -> [Float] {
        (0..<n).map { i in
            var v = 0.0
            for h in 1...count { v += sin(2 * .pi * Double(h * i) / Double(n) + 0.7 * Double(h)) / Double(h) }
            return Float(v / 2)
        }
    }

    private func assertClose(_ a: [Float], _ b: [Float], _ accuracy: Float, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, accuracy, message, file: file, line: line)
    }

    // MARK: Ported from ThirdWaveWT

    func testIdentity() {
        let cycle = sine(1024)
        XCTAssertEqual(Resampling.resizeCycle(cycle, to: 1024), cycle)
    }

    func testSinePreservedUpsampling() {
        assertClose(Resampling.resizeCycle(sine(1024), to: 2048), sine(2048), 1e-5)
    }

    /// P tables are a 16× stretch, where a sloppy implementation would show first.
    func testSixteenTimesUpsampling() {
        assertClose(Resampling.resizeCycle(sine(128, amplitude: 0.5), to: 2048), sine(2048, amplitude: 0.5), 1e-5)
    }

    /// Band-limited interpolation passes exactly through the original samples.
    func testUpsampledPassesThroughOriginalSamples() {
        let cycle = rich(1024, harmonics: 120)
        let up = Resampling.resizeCycle(cycle, to: 2048)
        assertClose(stride(from: 0, to: 2048, by: 2).map { up[$0] }, cycle, 1e-4)
    }

    func testRoundTripUpThenDown() {
        let cycle = rich(1024, harmonics: 100)
        assertClose(Resampling.resizeCycle(Resampling.resizeCycle(cycle, to: 2048), to: 1024), cycle, 1e-4)
    }

    func testDCPreserved() {
        for v in Resampling.resizeCycle([Float](repeating: 0.25, count: 1024), to: 2048) { XCTAssertEqual(v, 0.25, accuracy: 1e-5) }
    }

    func testNyquistHandledWithoutAmplitudeError() {
        let cycle = (0..<1024).map { Float($0 % 2 == 0 ? 1 : -1) }   // pure Nyquist
        let up = Resampling.resizeCycle(cycle, to: 2048)
        assertClose(stride(from: 0, to: 2048, by: 2).map { up[$0] }, cycle, 1e-4)
        XCTAssertLessThanOrEqual(up.map(abs).max() ?? 0, 1.001)
    }

    // MARK: Shrinking

    func testShrinkingDropsHarmonicsAboveNewNyquistAndKeepsTheCosineAtIt() {
        let n = 1024
        let low = sine(n, amplitude: 0.5, harmonic: 3)
        let high = sine(n, amplitude: 0.3, harmonic: 300)                                       // above 256: dropped
        let atNyquist = (0..<n).map { Float(0.2 * cos(2 * Double.pi * Double(256 * $0) / Double(n))) }   // exactly 256: kept
        let mixed = (0..<n).map { low[$0] + high[$0] + atNyquist[$0] }
        let want = (0..<512).map { sine(512, amplitude: 0.5, harmonic: 3)[$0] + Float(0.2 * ($0 % 2 == 0 ? 1 : -1)) }
        assertClose(Resampling.resizeCycle(mixed, to: 512), want, 3e-5)
    }

    func testShrinkingKeepsHarmonicsBelowNyquist() {
        let cycle = rich(2048, harmonics: 40)
        assertClose(Resampling.resizeCycle(cycle, to: 128), rich(128, harmonics: 40), 1e-5)
    }

    // MARK: Sizes that are not powers of two

    func testNonPowerOfTwoUp() {
        assertClose(Resampling.resizeCycle(rich(600, harmonics: 30), to: 2048), rich(2048, harmonics: 30), 1e-5)
    }

    func testNonPowerOfTwoDown() {
        assertClose(Resampling.resizeCycle(rich(2048, harmonics: 30), to: 600), rich(600, harmonics: 30), 1e-5)
    }

    func testNonPowerOfTwoBothSides() {
        assertClose(Resampling.resizeCycle(rich(600, harmonics: 30), to: 450), rich(450, harmonics: 30), 1e-5)
        assertClose(Resampling.resizeCycle(rich(601, harmonics: 30), to: 1000), rich(1000, harmonics: 30), 1e-5)
    }

    func testNonPowerOfTwoNyquistPassesThroughOriginals() {
        let cycle = (0..<600).map { Float($0 % 2 == 0 ? 0.8 : -0.8) }
        let up = Resampling.resizeCycle(cycle, to: 1200)
        assertClose(stride(from: 0, to: 1200, by: 2).map { up[$0] }, cycle, 1e-5)
    }

    func testEdgeSizes() {
        XCTAssertEqual(Resampling.resizeCycle([1, 2, 3], to: 0), [])
        XCTAssertEqual(Resampling.resizeCycle([], to: 4), [0, 0, 0, 0])
        assertClose(Resampling.resizeCycle([0.5], to: 8), [Float](repeating: 0.5, count: 8), 1e-6)
        assertClose(Resampling.resizeCycle(sine(64), to: 1), [0], 1e-6)
    }

    // MARK: Frame count

    private let ten: [[Float]] = (0..<10).map { [Float($0), Float($0)] }

    func testPickEvenlyReduces() {
        XCTAssertEqual(Resampling.changeFrameCount(ten, to: 4, policy: .pickEvenly).map { $0[0] }, [0, 3, 6, 9])
    }

    func testPickEvenlyExpandsByRepeating() {
        let four = Array(ten.prefix(4))
        XCTAssertEqual(Resampling.changeFrameCount(four, to: 10, policy: .pickEvenly).map { $0[0] },
                       [0, 0, 1, 1, 1, 2, 2, 2, 3, 3])
    }

    func testInterpolateCrossfades() {
        let three = Array(ten.prefix(3))
        let out = Resampling.changeFrameCount(three, to: 5, policy: .interpolate)
        assertClose(out.map { $0[1] }, [0, 0.5, 1, 1.5, 2], 1e-6)
        let down = Resampling.changeFrameCount(ten, to: 4, policy: .interpolate)
        assertClose(down.map { $0[0] }, [0, 3, 6, 9], 1e-6)
        let odd = Resampling.changeFrameCount(ten, to: 7, policy: .interpolate)
        assertClose(odd.map { $0[0] }, [0, 1.5, 3, 4.5, 6, 7.5, 9], 1e-5)
    }

    func testFrameCountEdgeCases() {
        for policy in FrameCountPolicy.allCases {
            XCTAssertEqual(Resampling.changeFrameCount(ten, to: 10, policy: policy), ten)
            XCTAssertEqual(Resampling.changeFrameCount(ten, to: 1, policy: policy), [ten[0]])
            XCTAssertEqual(Resampling.changeFrameCount([ten[4]], to: 3, policy: policy), [ten[4], ten[4], ten[4]])
            XCTAssertEqual(Resampling.changeFrameCount(ten, to: 0, policy: policy), [])
            XCTAssertEqual(Resampling.changeFrameCount([], to: 5, policy: policy), [])
        }
    }

    // MARK: Mipmap chain

    /// 64 frames of 1,024 samples; frame w has 1 + w/2 harmonics (low, so level 512 loses none).
    private func lowHarmonicTable() -> [[Float]] {
        (0..<64).map { w in rich(1024, harmonics: 1 + w / 2).map { $0 * 0.5 } }
    }

    func testChainLengthAndLevel512() {
        let frames = lowHarmonicTable()
        let chain = Resampling.thirdWaveMipmapChain(frames)
        XCTAssertEqual(chain.count, 65_536)
        for (f, frame) in frames.enumerated() {
            assertClose(Array(chain[(f * 512)..<(f * 512 + 512)]), Resampling.resizeCycle(frame, to: 512), 1e-6, "frame \(f)")
        }
        let level256 = 64 * 512
        assertClose(Array(chain[level256..<(level256 + 256)]), Resampling.resizeCycle(frames[0], to: 256), 1e-6)
    }

    func testChainLowPassesTheSmallLevels() {
        let frames = (0..<64).map { _ in rich(1024, harmonics: 200) }
        let chain = Resampling.thirdWaveMipmapChain(frames)
        // (start of the level, its size, the highest harmonic it may keep)
        let levels = [(64 * (512 + 256), 128, 24), (64 * (512 + 256 + 128), 64, 12), (64 * (512 + 256 + 128 + 64), 64, 4)]
        for (start, size, top) in levels {
            for f in [0, 37, 63] {
                let wave = Array(chain[(start + f * size)..<(start + f * size + size)])
                let h = Resampling.Harmonics(of: wave)
                for k in (top + 1)...h.top {
                    XCTAssertEqual(hypot(h.re[k], h.im[k]), 0, accuracy: 1e-6, "level \(size) from \(start), harmonic \(k)")
                }
                XCTAssertGreaterThan(hypot(h.re[top], h.im[top]), 1e-4, "harmonic \(top) is kept")
            }
        }
    }

    func testChainStaysWithinTablePeak() {
        let square = (0..<1024).map { Float($0 < 512 ? 1 : -1) }
        let chain = Resampling.thirdWaveMipmapChain([[Float]](repeating: square, count: 64))
        XCTAssertLessThanOrEqual(chain.map(abs).max() ?? 0, 1.00001)
    }

    // MARK: PPG standard waves

    func testPPGStandardWaves() {
        XCTAssertEqual(PPGStandardWaves.frames.count, 4)
        XCTAssertTrue(PPGStandardWaves.frames.allSatisfy { $0.count == 128 })
        let t = PPGStandardWaves.triangle
        XCTAssertEqual([t[0], t[32], t[64], t[96]], [0, 1, 0, -1])
        let p = PPGStandardWaves.narrowPulse
        XCTAssertEqual([p[0], p[15], p[16], p[127]], [1, 1, -1, -1])
        let s = PPGStandardWaves.square
        XCTAssertEqual([s[0], s[63], s[64], s[127]], [1, 1, -1, -1])
        let w = PPGStandardWaves.sawtooth
        XCTAssertEqual([w[0], w[64], w[127]], [-1, 0, Float(2.0 * 127 / 128 - 1)])
        XCTAssertEqual(PPGStandardWaves.positions, 60...63)
    }
}

final class ResamplingLargeOddSizeTests: XCTestCase {
    /// A Serum sidecar allows up to 9,999 samples per cycle; Bluestein's algorithm keeps a prime
    /// size as exact and as fast as a power of two.
    func testPrimeSizeCycleResizesExactly() {
        func cycle(_ n: Int) -> [Float] {
            (0..<n).map { i -> Float in
                let x: Double = 2 * Double.pi * Double(i) / Double(n)
                let a: Double = 0.6 * sin(x), b: Double = 0.3 * cos(7 * x), c: Double = 0.1 * sin(40 * x)
                return Float(a + b + c)
            }
        }
        let start = Date()
        for _ in 0..<8 {
            let out = Resampling.resizeCycle(cycle(9973), to: 2048)
            let want = cycle(2048)
            XCTAssertLessThan(zip(out, want).map { abs($0 - $1) }.max() ?? 1, 1e-5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "8 frames of 9,973 samples should resize in well under a second in a release build")
    }
}

final class ResamplingNyquistTests: XCTestCase {
    /// A cycle with content at its own Nyquist (the 512th harmonic of 1,024 samples) survives
    /// growing to 2,048 and shrinking back; the shrink keeps the cosine part at the new Nyquist.
    func testGrowThenShrinkIsExactWithNyquistContent() {
        let n = 1024
        let cycle: [Float] = (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / Double(n)
            return Float(0.5 * sin(x) + 0.1 * cos(Double(n / 2) * x))   // the Nyquist term alternates ±0.1
        }
        let back = Resampling.resizeCycle(Resampling.resizeCycle(cycle, to: 2048), to: n)
        XCTAssertEqual(back.count, n)
        XCTAssertLessThan(zip(back, cycle).map { abs($0 - $1) }.max() ?? 1, 1e-5)
    }

    /// Shrinking gives the band-limited waveform's samples at the new positions: harmonic 4 of
    /// an 8-sample cycle (its Nyquist) comes out as the alternating cosine it is there.
    func testShrinkKeepsTheCosineAtTheNewNyquist() {
        let n = 32
        let cycle: [Float] = (0..<n).map { i in Float(cos(2 * Double.pi * 4 * Double(i) / Double(n) + 0.3)) }
        let small = Resampling.resizeCycle(cycle, to: 8)
        for (k, v) in small.enumerated() {
            XCTAssertEqual(v, Float(cos(0.3)) * (k % 2 == 0 ? 1 : -1), accuracy: 1e-5)
        }
    }
}
