import Foundation

// RIFF/WAVE and Surge .wt byte writers for WavetableWriter. The WAV writer is adapted from
// ThirdWaveWT's WaveWriter (MIT, © 2026 Adam Arthur Bier): same chunk order (fmt, clm, data), with
// the interpolation flag added to the clm chunk, an optional clm chunk, and 16-bit PCM output.

extension WavetableWriter {
    /// Builds the bytes of the files WavetableWriter writes.
    enum Bytes {
        /// Sample encodings for a WAV.
        enum SampleFormat { case float32, pcm16 }

        /// The `clm ` chunk text: `<!>NNNN F0000000 wavetable (pgdata Packer)`, where NNNN is the
        /// frame size (at least four digits) and F the interpolation digit: 0 none, 1 crossfade,
        /// 2 spectral. Serum treats 2, 3, and 4 as spectral variants and Vital anything above 1;
        /// 2 is what Vital itself writes.
        static func clmText(frameSize: Int, interpolation: Interpolation) -> String {
            let digit: Character
            switch interpolation {
            case .none: digit = "0"
            case .crossfade: digit = "1"
            case .spectral: digit = "2"
            }
            return "<!>" + String(format: "%04d", frameSize) + " \(digit)0000000 wavetable (pgdata Packer)"
        }

        /// A mono WAV of `samples`, with a `clm ` chunk when `clm` is given. Float32 keeps values
        /// beyond ±1 as they are; 16-bit PCM rounds to the nearest step of 1/32,767 and clamps.
        static func wav(samples: [Float], sampleRate: Int, format: SampleFormat, clm: String?) -> Data {
            var payload: [UInt8] = []
            switch format {
            case .float32:
                payload.reserveCapacity(samples.count * 4)
                for v in samples { le32(&payload, v.bitPattern) }
            case .pcm16:
                payload.reserveCapacity(samples.count * 2)
                for v in samples {
                    let s = Int16(clamping: Int((Double(v) * 32_767).rounded()))
                    le16(&payload, UInt16(bitPattern: s))
                }
            }
            let bytesPerSample: UInt16 = format == .float32 ? 4 : 2

            var body: [UInt8] = Array("WAVE".utf8)
            body.reserveCapacity(payload.count + 128)
            body += Array("fmt ".utf8); le32(&body, 16)
            le16(&body, format == .float32 ? 3 : 1)                  // IEEE float or PCM
            le16(&body, 1)                                          // mono
            le32(&body, UInt32(sampleRate))
            le32(&body, UInt32(sampleRate) * UInt32(bytesPerSample)) // byte rate
            le16(&body, bytesPerSample)                             // block align
            le16(&body, bytesPerSample * 8)                         // bits per sample
            if let clm {
                var text = Array(clm.utf8.filter { $0 >= 0x20 && $0 < 0x7F })
                if text.count % 2 == 1 { text.append(0) }           // chunks are word-aligned
                body += Array("clm ".utf8); le32(&body, UInt32(text.count)); body += text
            }
            body += Array("data".utf8); le32(&body, UInt32(payload.count)); body += payload
            if payload.count % 2 == 1 { body.append(0) }

            var out: [UInt8] = Array("RIFF".utf8)
            out.reserveCapacity(body.count + 8)
            le32(&out, UInt32(body.count))
            return Data(out + body)
        }

        /// A Surge `.wt`: `vawt`, then little-endian u32 frame size, u16 frame count, u16 flags (0:
        /// a wavetable of float32 data, no metadata), then the samples as float32.
        static func surge(frames: [[Float]]) -> Data {
            var out: [UInt8] = Array("vawt".utf8)
            let size = frames.first?.count ?? 0
            out.reserveCapacity(12 + frames.count * size * 4)
            le32(&out, UInt32(size))
            le16(&out, UInt16(frames.count))
            le16(&out, 0)
            for f in frames { for v in f { le32(&out, v.bitPattern) } }
            return Data(out)
        }

        private static func le16(_ b: inout [UInt8], _ v: UInt16) {
            b.append(UInt8(truncatingIfNeeded: v)); b.append(UInt8(truncatingIfNeeded: v >> 8))
        }

        private static func le32(_ b: inout [UInt8], _ v: UInt32) {
            for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
        }
    }
}
