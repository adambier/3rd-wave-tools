import Foundation

// TEMPORARY — DELETE AT MERGE.
//
// Stand-ins for the OutputPreset members that Writing.swift (built in parallel on another branch)
// provides, so the Convert tab's code in PgdataPackerCore and the app compiles on the 1.1-app
// branch. The values follow the shared brief; the real members replace them. ConvertPlanTests
// rely on these values: isThirdWave true for .thirdWaveU and .thirdWaveP only; frameSize 1,024
// for .thirdWaveU and 128 for .thirdWaveP; maxFrameCount 64 for both.
//
// Types assumed here: basis String, isThirdWave Bool, frameSize Int? (nil: the destination keeps
// the source's frame size, or decides it from options, as Tonverk does), maxFrameCount Int.
// ConvertPlan reads frameSize only through `??`, so a non-optional Int there also compiles.

public extension OutputPreset {
    /// TEMPORARY stand-in (see the file comment): what the preset's behaviour rests on.
    var basis: String {
        switch self {
        case .thirdWaveU, .thirdWaveP: return "The 3rd Wave's .wt format as pgdata Packer reads and writes it (FORMATS.md 5.1)."
        case .wav2048: return "Serum's manual, and Vital's and Surge's source code, for the clm chunk."
        case .miniFreak: return "Arturia's MiniFreak V documentation."
        case .tonverk: return "Elektron's Tonverk manual, for the file-name tags."
        case .phasePlant: return "Kilohearts' Phase Plant documentation."
        case .surge: return "Surge XT's source code, for the .wt header."
        case .waveEdit: return "Synthesis Technology's WaveEdit documentation."
        }
    }
    /// TEMPORARY stand-in (see the file comment): whether the output is a 3rd Wave .wt.
    var isThirdWave: Bool { self == .thirdWaveU || self == .thirdWaveP }
    /// TEMPORARY stand-in (see the file comment): samples per frame written, or nil when it
    /// follows the source or the options.
    var frameSize: Int? {
        switch self {
        case .thirdWaveU: return 1024
        case .thirdWaveP: return 128
        case .wav2048, .miniFreak, .phasePlant: return 2048
        case .waveEdit: return 256
        case .tonverk, .surge: return nil
        }
    }
    /// TEMPORARY stand-in (see the file comment): the most frames the destination takes.
    var maxFrameCount: Int {
        switch self {
        case .thirdWaveU, .thirdWaveP, .miniFreak, .tonverk, .waveEdit: return 64
        case .wav2048, .phasePlant: return 256
        case .surge: return 512
        }
    }
}
