import XCTest
import Foundation
@testable import PgdataFormats
@testable import WavetableFormats

// Tests for the FLAC reader. The files in Resources/FLAC are synthetic: `make.py` there builds
// them with ffmpeg (several compression levels, predictor types, and stereo modes) and with
// `flacenc.py`, a small encoder for what ffmpeg cannot write (8-, 12-, 20-, and 32-bit samples,
// wasted bits, variable block sizes, chosen subframe kinds, custom metadata blocks, and missing
// or wrong MD5 signatures). Every file's expected sample count and first-channel hash came from
// ffmpeg's decoding of it (also of the hand-made ones, so the two encoders agree on each file), and
// `make.py` checks the hand-made files decode to the samples it meant to write.

final class FLACTests: XCTestCase {

    /// Sample count, channel count, and FNV-1a 64 of the first channel as float32 little-endian
    /// (each sample scaled by 2^(bits−1)), from ffmpeg.
    static let expected: [String: (samples: Int, channels: Int, hash: UInt64)] = [
        "Pad_wt1024r.flac": (3172, 1, 0xa8738839f53b1dad),
        "comment_clm.flac": (2048, 1, 0x5c4ce7cfe4b8e671),
        "comment_frames_only.flac": (6144, 1, 0xf73c7c1298451221),
        "hand_12bit.flac": (4096, 1, 0x13863dd0ec7ebffc),
        "hand_20bit_lpc.flac": (4096, 1, 0x6bef9e7aee78c399),
        "hand_24bit_rightside_srge.flac": (4096, 2, 0x64c487732abb9b59),
        "hand_32bit_midside.flac": (2048, 2, 0xf884e41652807798),
        "hand_8bit.flac": (8192, 1, 0x0610c60beba5e947),
        "hand_md5_none.flac": (4096, 1, 0xc56d713e5a726365),
        "hand_stereo_sides_mlc.flac": (4096, 2, 0xc6f5b3da897c4a49),
        "hand_wasted_variable.flac": (4096, 1, 0xa76f7800ceccbb6a),
        "noise1_fullscale.flac": (2048, 1, 0x6ea0939b7e250e15),
        "odd_3x2048_plus100.flac": (6244, 1, 0x51d46fd0990df5cd),
        "silence4.flac": (8192, 1, 0x8f6955bf94ec2325),
        "stereo2_indep.flac": (4096, 2, 0xd3ec5465cde3ea4d),
        "stereo2_left_side.flac": (4096, 2, 0xd3ec5465cde3ea4d),
        "stereo2_mid_side.flac": (4096, 2, 0xd3ec5465cde3ea4d),
        "stereo2_right_side.flac": (4096, 2, 0xd3ec5465cde3ea4d),
        "table3_24bit_level12.flac": (6144, 1, 0x8cb53f580809d3dd),
        "table4_16bit_96k.flac": (8192, 1, 0xb8806bcb0a388c89),
        "table6_16bit_level0.flac": (12288, 1, 0xbb54ac6d0c443e45),
        "table6_16bit_level8.flac": (12288, 1, 0xbb54ac6d0c443e45),
        "table6_16bit_fixed.flac": (12288, 1, 0xbb54ac6d0c443e45),
    ]

    // MARK: - Decoding

    func testEveryFileDecodesAsFFmpegDoes() throws {
        var total = FLACDecoder.Stats()
        for (name, want) in Self.expected.sorted(by: { $0.key < $1.key }) {
            let d = try FLACDecoder.decode([UInt8](try resource(name)), fileName: name)
            XCTAssertEqual(d.firstChannel.count, want.samples, name)
            XCTAssertEqual(d.info.channels, want.channels, name)
            XCTAssertEqual(fnv1a(d.firstChannel), want.hash, name)
            XCTAssertEqual(d.info.totalSamples, want.samples, name)
            total.constant += d.stats.constant; total.verbatim += d.stats.verbatim
            total.fixed += d.stats.fixed; total.lpc += d.stats.lpc
            total.rice2 += d.stats.rice2; total.escaped += d.stats.escaped; total.wasted += d.stats.wasted
            total.independent += d.stats.independent; total.leftSide += d.stats.leftSide
            total.rightSide += d.stats.rightSide; total.midSide += d.stats.midSide
            total.variable += d.stats.variable
        }
        // The set exercises every subframe kind, both residual codings, escaped partitions,
        // wasted bits, every stereo mode, and both blocking strategies.
        XCTAssertGreaterThan(total.constant, 0); XCTAssertGreaterThan(total.verbatim, 0)
        XCTAssertGreaterThan(total.fixed, 0); XCTAssertGreaterThan(total.lpc, 0)
        XCTAssertGreaterThan(total.rice2, 0); XCTAssertGreaterThan(total.escaped, 0)
        XCTAssertGreaterThan(total.wasted, 0); XCTAssertGreaterThan(total.variable, 0)
        XCTAssertGreaterThan(total.independent, 0); XCTAssertGreaterThan(total.leftSide, 0)
        XCTAssertGreaterThan(total.rightSide, 0); XCTAssertGreaterThan(total.midSide, 0)
    }

    func testSameAudioAtEveryCompressionLevelAndStereoMode() throws {
        // ffmpeg encoded the same table three ways and the same stereo pair four ways.
        let tables = try ["table6_16bit_level0", "table6_16bit_level8", "table6_16bit_fixed"].map { try decode($0 + ".flac").firstChannel }
        XCTAssertEqual(tables[0], tables[1]); XCTAssertEqual(tables[0], tables[2])
        let pairs = try ["indep", "left_side", "right_side", "mid_side"].map { try decode("stereo2_\($0).flac").firstChannel }
        for p in pairs.dropFirst() { XCTAssertEqual(p, pairs[0]) }
        // The left channel is a saw at 0.8 of full scale, from −0.8 at sample 0.
        XCTAssertEqual(pairs[0][0], -0.8, accuracy: 1e-4)
        XCTAssertEqual(pairs[0][2048], -0.8, accuracy: 1e-4)
    }

    func testBitDepthScaling() throws {
        // Full-scale noise: 32,767 and −32,768 were put at samples 0 and 1.
        let noise = try decode("noise1_fullscale.flac").firstChannel
        XCTAssertEqual(noise[0], 32767.0 / 32768)
        XCTAssertEqual(noise[1], -1)
        XCTAssertEqual(try decode("silence4.flac").firstChannel, [Float](repeating: 0, count: 8192))
        // 8-bit: the second block is random 8-bit values, all multiples of 1/128.
        let eight = try decode("hand_8bit.flac")
        XCTAssertEqual(eight.info.bitsPerSample, 8)
        XCTAssertTrue(eight.firstChannel[2048..<4096].allSatisfy { ($0 * 128).rounded() == $0 * 128 })
        XCTAssertNotEqual(eight.firstChannel[2048..<4096].max(), 0)
        // 32-bit mid/side: a triangle from −2^30 in steps of 2^20, i.e. −0.5 rising by 1/2,048.
        let wide = try decode("hand_32bit_midside.flac")
        XCTAssertEqual(wide.info.bitsPerSample, 32)
        XCTAssertEqual(wide.firstChannel[0], -0.5)
        XCTAssertEqual(wide.firstChannel[1], -0.5 + 1.0 / 2048)
        XCTAssertEqual(wide.stats.midSide, 2)
        // 20-bit LPC and 12-bit FIXED decode to the same shapes as their 16-bit counterparts would:
        // both start at 0 (a sum of sines) and stay within ±0.9.
        for name in ["hand_20bit_lpc.flac", "hand_12bit.flac"] {
            let d = try decode(name)
            XCTAssertEqual(d.firstChannel[0], 0, accuracy: 1e-3, name)
            XCTAssertLessThanOrEqual(d.firstChannel.map { abs($0) }.max() ?? 0, 0.9 + 1e-6, name)
        }
    }

    func testMetadataBlocksAreRead() throws {
        let d = try decode("hand_stereo_sides_mlc.flac")
        XCTAssertEqual(d.applications.map { String(decoding: $0.id, as: UTF8.self) }, ["MsHk", " mlc"])
        XCTAssertEqual(d.applications[0].body.count, 8)
        XCTAssertEqual(String(decoding: d.applications[1].body, as: UTF8.self), "<!>1024 00000000 wavetable (test)")
        XCTAssertEqual(d.comments.map { $0.key }, ["ARTIST"])
        XCTAssertEqual(d.comments.map { $0.value }, ["Test"])
        XCTAssertEqual(d.stats.leftSide, 2)
        let s = try decode("hand_24bit_rightside_srge.flac")
        XCTAssertEqual(s.applications.map { String(decoding: $0.id, as: UTF8.self) }, ["srge"])
        XCTAssertEqual(s.stats.rightSide, 1)
        XCTAssertEqual(s.info.bitsPerSample, 24)
        XCTAssertEqual(s.info.sampleRate, 44100)
        let v = try decode("hand_wasted_variable.flac")
        XCTAssertEqual(v.stats.variable, 3)
        XCTAssertEqual(v.stats.wasted, 3)
        XCTAssertEqual(v.info.sampleRate, 32000)
        XCTAssertEqual(try decode("hand_20bit_lpc.flac").info.sampleRate, 50000)
    }

    func testMD5IsCheckedWhenPresent() throws {
        let none = try decode("hand_md5_none.flac")
        XCTAssertEqual(none.info.md5, [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(none.firstChannel.count, 4096)
        XCTAssertThrowsError(try decode("hand_md5_wrong.flac")) { e in
            XCTAssertEqual("\(e)", "\"hand_md5_wrong.flac\" is a FLAC file, but its audio does not match the MD5 signature in its stream description; it is damaged.")
            XCTAssertEqual((e as? WavetableError)?.kind, .damaged)
        }
    }

    // MARK: - Damaged files

    func testCutShortAndCorruptFilesAreReported() throws {
        let good = try resource("table6_16bit_level0.flac")
        let name = "t.flac"
        let lastFrame = try decode("table6_16bit_level0.flac").frames - 1
        // Cut off inside the last frame.
        XCTAssertThrowsError(try WavetableReader.read(good.prefix(good.count - 10), fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but it ends in the middle of frame \(lastFrame); it is cut short or damaged.")
            XCTAssertEqual((e as? WavetableError)?.kind, .damaged)
        }
        // Cut off inside the metadata.
        XCTAssertThrowsError(try WavetableReader.read(good.prefix(20), fileName: name)) { e in
            XCTAssertTrue("\(e)".contains("cut short"), "\(e)")
        }
        // A wrong frame CRC-16 (the last two bytes of the file).
        var bad = good
        bad[bad.count - 1] ^= 0x01
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but frame \(lastFrame) fails its checksum (CRC-16); it is damaged.")
        }
        // A wrong header CRC-8: the first frame's header is 5 bytes, then its CRC.
        let first = try firstFrameOffset(good)
        bad = good
        bad[first + 5] ^= 0x01
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but frame 0 fails its header checksum (CRC-8); it is damaged.")
        }
        // A wrong sync code.
        bad = good
        bad[first] = 0
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but frame 0 does not begin with a frame sync code; it is damaged.")
        }
        // The frame's sample size disagrees with STREAMINFO (bits 1–3 of the fourth header byte:
        // 16-bit is code 4, 8-bit is 1).
        bad = good
        bad[first + 3] = (bad[first + 3] & 0b1111_0001) | (1 << 1)
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertTrue("\(e)".contains("says 8-bit samples, but the stream description says 16-bit"), "\(e)")
        }
        // Metadata: no STREAMINFO first, an invalid block type, a block past the end.
        let padding: [UInt8] = [0x81, 0, 0, 4, 0, 0, 0, 0]
        XCTAssertThrowsError(try WavetableReader.read(Data("fLaC".utf8) + Data(padding), fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but it does not begin with its stream description (STREAMINFO); it is damaged.")
        }
        bad = good
        bad[4] = 0x7F
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but a header block has the invalid type 127; it is damaged.")
        }
        bad = good
        bad[5] = 0xFF
        XCTAssertThrowsError(try WavetableReader.read(bad, fileName: name)) { e in
            XCTAssertEqual("\(e)", "\"t.flac\" is a FLAC file, but a header block (type 0) runs past the end of the file; it is cut short.")
        }
        // Not FLAC at all: no wavetable, no error.
        XCTAssertEqual(try WavetableReader.read(Data("fLaX".utf8) + good.dropFirst(4), fileName: name), [])
        XCTAssertEqual(try WavetableReader.read(Data("fLa".utf8), fileName: name), [])
    }

    // MARK: - The wavetable rules

    func testFileNamesAndSniffing() throws {
        XCTAssertTrue(WavetableReader.mayContainWavetables(fileName: "a.flac"))
        XCTAssertTrue(WavetableReader.mayContainWavetables(fileName: "B.FLAC"))
        XCTAssertFalse(WavetableReader.mayContainWavetables(fileName: ".a.flac"))
        // Content decides, not the extension.
        let t = try WavetableReader.read(try resource("table6_16bit_level0.flac"), fileName: "Table.wav")
        XCTAssertEqual(t.first?.frameSize, 2048)
    }

    func testLengthRulesApplyAsForWAV() throws {
        let t = try XCTUnwrap(WavetableReader.read(try resource("table6_16bit_level8.flac"), fileName: "Evolving Saw.flac").first)
        XCTAssertEqual(t.name, "Evolving Saw")
        XCTAssertEqual(t.fileName, "Evolving Saw.flac")
        XCTAssertEqual(t.source, .flac)
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.frameSizeEvidence, .length)
        XCTAssertEqual(t.frameSizeBasis, "file length only (2,048 per frame by convention, the Serum-style size; the file does not specify a frame size)")
        XCTAssertEqual(t.candidateFrameSizes, [64, 128, 256, 512, 1024, 4096])
        XCTAssertEqual(t.samples.count, 6 * 2048)
        XCTAssertEqual(t.notes, [])
        XCTAssertEqual(t.wavetable()?.frameCount, 6)
        // 8,192 samples is open between 64 × 128 and 4 × 2,048, as for a WAV.
        let open = try XCTUnwrap(WavetableReader.read(try resource("silence4.flac"), fileName: "s.flac").first)
        XCTAssertNil(open.frameSize)
        XCTAssertEqual(open.candidateFrameSizes, [128, 2048])
        // A length that does not divide, or stereo without metadata, is not a wavetable.
        XCTAssertEqual(try WavetableReader.read(try resource("odd_3x2048_plus100.flac"), fileName: "o.flac"), [])
        XCTAssertEqual(try WavetableReader.read(try resource("stereo2_mid_side.flac"), fileName: "st.flac"), [])
        XCTAssertEqual(try WavetableReader.read(try resource("hand_32bit_midside.flac"), fileName: "w.flac"), [])
        // A multisample note name is not a wavetable either.
        XCTAssertEqual(try WavetableReader.read(try resource("table6_16bit_level0.flac"), fileName: "Saw C3.flac"), [])
    }

    func testTonverkTagInTheName() throws {
        let t = try XCTUnwrap(WavetableReader.read(try resource("Pad_wt1024r.flac"), fileName: "Pad_wt1024r.flac").first)
        XCTAssertEqual(t.name, "Pad")
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeEvidence, .fileName)
        XCTAssertEqual(t.frameSizeBasis, "Tonverk tag in the file name (_wt1024r)")
        XCTAssertNil(t.interpolation, "Tonverk's r is not an interpolation claim")
        XCTAssertTrue(t.isMarkedForTonverkRawSamples)
        XCTAssertEqual(t.samples.count, 3 * 1024)
        XCTAssertEqual(t.notes, ["The file name ends in “r”, Tonverk’s mark for raw sample playback (no interpolation between a frame’s samples).",
                                 "100 samples after the last whole frame are left out."])
    }

    func testSerumSidecarBesideTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FLACTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flac = dir.appendingPathComponent("Four.flac")
        try resource("comment_frames_only.flac").write(to: flac)
        try "[1024]\n[no interp]\n".write(to: dir.appendingPathComponent("Four.txt"), atomically: true, encoding: .utf8)
        let t = try XCTUnwrap(WavetableReader.read(url: flac).first)
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeEvidence, .sidecar)
        XCTAssertEqual(t.interpolation, Interpolation.none)
        XCTAssertEqual(t.wavetable()?.frameCount, 6)
    }

    func testApplicationBlocksCountAsChunks() throws {
        // Phase Plant's library stores a Serum clm chunk as an application block with its id
        // byte-reversed (" mlc"), beside a "MsHk" block that says nothing about frames.
        let t = try XCTUnwrap(WavetableReader.read(try resource("hand_stereo_sides_mlc.flac"), fileName: "Sides.flac").first)
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeEvidence, .statedInFile)
        XCTAssertEqual(t.frameSizeBasis, "Serum-style tag inside the file (clm block)")
        XCTAssertEqual(t.interpolation, Interpolation.none)
        XCTAssertEqual(t.wavetable()?.frameCount, 4)
        XCTAssertEqual(t.notes, ["Stereo file: only the left channel is used."])
        // A Surge srge block, forwards.
        let s = try XCTUnwrap(WavetableReader.read(try resource("hand_24bit_rightside_srge.flac"), fileName: "Srge.flac").first)
        XCTAssertEqual(s.frameSize, 1024)
        XCTAssertEqual(s.frameSizeBasis, "Surge tag inside the file (srge block)")
        XCTAssertEqual(s.wavetable()?.frameCount, 4)
    }

    func testComments() throws {
        // A Serum tag as a comment's value is used, and said to have come from the comments.
        let c = try XCTUnwrap(WavetableReader.read(try resource("comment_clm.flac"), fileName: "c.flac").first)
        XCTAssertEqual(c.frameSize, 1024)
        XCTAssertEqual(c.frameSizeEvidence, .statedInFile)
        XCTAssertEqual(c.interpolation, Interpolation.none)
        XCTAssertEqual(c.wavetable()?.frameCount, 2)
        XCTAssertEqual(c.notes, ["The Serum-style tag was found in the file’s comments (COMMENT), not in a block of its own."])
        // A comment that only mentions frames is reported, not used.
        let f = try XCTUnwrap(WavetableReader.read(try resource("comment_frames_only.flac"), fileName: "f.flac").first)
        XCTAssertEqual(f.frameSize, 2048)
        XCTAssertEqual(f.frameSizeEvidence, .length)
        XCTAssertEqual(f.notes, ["The file’s comments say \"FRAMES=3\"; a frame size is not taken from a comment."])
    }

    func testWastedBitsAndVariableBlocksReadAsOneTable() throws {
        let t = try XCTUnwrap(WavetableReader.read(try resource("hand_wasted_variable.flac"), fileName: "v.flac").first)
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.wavetable()?.frameCount, 2)
        // Samples are multiples of 16/32,768: the four wasted bits came back as zeros.
        XCTAssertTrue(t.samples.allSatisfy { ($0 * 2048).rounded() == $0 * 2048 })
    }

    // MARK: - Helpers

    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent("FLAC").appendingPathComponent(name))
    }

    private func decode(_ name: String) throws -> FLACDecoder.Decoded {
        try FLACDecoder.decode([UInt8](try resource(name)), fileName: name)
    }

    /// The offset of the first frame: after the metadata blocks.
    private func firstFrameOffset(_ d: Data) throws -> Int {
        let b = [UInt8](d)
        var off = 4
        while true {
            let last = b[off] & 0x80 != 0
            off += 4 + (Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3]))
            if last { return off }
        }
    }

    /// FNV-1a 64 of samples as float32 little-endian.
    private func fnv1a(_ samples: [Float]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for s in samples {
            let bits = s.bitPattern
            for k in 0..<4 {
                h ^= UInt64((bits >> (8 * UInt32(k))) & 0xFF)
                h = h &* 0x0000_0100_0000_01b3
            }
        }
        return h
    }
}

final class FLACHostileHeaderTests: XCTestCase {
    /// A STREAMINFO claiming 2³⁶ − 1 samples with no frames must throw, not allocate.
    func testHugeSampleCountDoesNotAllocate() {
        var b: [UInt8] = Array("fLaC".utf8)
        b += [0x80, 0x00, 0x00, 0x22]                       // last block, STREAMINFO, 34 bytes
        b += [0x10, 0x00, 0x10, 0x00]                       // block sizes 4096
        b += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]           // frame sizes
        // 20 bits rate (48000), 3 bits channels-1 (0), 5 bits bps-1 (15), 36 bits total = all ones
        let tail: [UInt8] = [0x0B, 0xB8, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        b += tail
        b += [UInt8](repeating: 0, count: 16)               // MD5
        XCTAssertThrowsError(try WavetableReader.read(Data(b), fileName: "huge.flac"))
    }
}
