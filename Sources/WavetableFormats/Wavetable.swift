import Foundation

// The shared types of WavetableFormats. Reading.swift finds wavetables in files, Writing.swift
// writes them for a destination, and Resampling.swift changes their frame size and count.
//
// WavetableFormats converts existing wavetables between formats. It does not build wavetables
// from other audio (slicing, pitch detection, drawing): that is the 3rd Wave's Wave Maker.

/// A wavetable: a sequence of frames, each one cycle of a waveform, all of the same length.
public struct Wavetable: Equatable, Sendable {
    /// The table's name, as its source file gives it (or the file name without its extension).
    public var name: String
    /// The frames, in order; each holds one cycle of `frameSize` samples, nominally within ±1.
    public var frames: [[Float]]
    /// Whether and how the source asks a synth to interpolate between frames, when it says.
    public var interpolation: Interpolation?

    /// Creates a wavetable from its name, frames, and interpolation, if known.
    public init(name: String, frames: [[Float]], interpolation: Interpolation? = nil) {
        self.name = name; self.frames = frames; self.interpolation = interpolation
    }

    /// Samples per frame (0 for an empty table).
    public var frameSize: Int { frames.first?.count ?? 0 }
    /// Number of frames.
    public var frameCount: Int { frames.count }
    /// The largest absolute sample.
    public var peak: Float { frames.reduce(0) { m, f in f.reduce(m) { max($0, abs($1)) } } }

    /// A peak as the reader's, the writer's, and the app's notes show it: two decimals ("1.14"),
    /// or enough to show that a peak just over full scale is over it ("1.0003"; "just over 1"
    /// when four decimals still read 1.0000), so a note never says "peak 1.00, over full scale".
    /// A peak of 10,000 or more, which only a damaged file has, is written as a power of ten
    /// ("2.2 × 10³⁶") rather than as a row of digits.
    public static func peakText(_ peak: Float) -> String {
        if peak >= 10_000 {
            let exponent = Int(log10(Double(peak)).rounded(.down))
            let mantissa = Double(peak) / pow(10, Double(exponent))
            let digits = String(format: "%.1f", mantissa)
            // 9.96 rounds to "10.0": one more power of ten instead.
            if digits == "10.0" { return "1.0 × 10" + superscript(exponent + 1) }
            return digits + " × 10" + superscript(exponent)
        }
        let shown = String(format: "%.2f", Double(peak))
        guard shown == "1.00", peak > 1 else { return shown }
        let finer = String(format: "%.4f", Double(peak))
        return finer == "1.0000" ? "just over 1" : finer
    }

    /// An exponent in superscript digits, for ``peakText(_:)``.
    static func superscript(_ n: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        return String(n).map { c -> Character in c.wholeNumberValue.map { digits[$0] } ?? c }.reduce(into: "") { $0.append($1) }
    }
}

/// How a synth moves between neighboring frames, as some file formats can record it.
public enum Interpolation: String, Equatable, Sendable, CaseIterable {
    /// Jumps from frame to frame (Serum's "no interp"; Tonverk's trailing `r`).
    case none
    /// Crossfades between neighboring frames.
    case crossfade
    /// Morphs between frames' spectra (Serum's and Vital's spectral morph).
    case spectral
}

/// The kind of file a wavetable was found in.
public enum SourceFormat: Equatable, Sendable {
    /// A 3rd Wave `.wt` text file: a P table (64 × 128) or a U table (64 × 1,024 plus its
    /// mipmap chain).
    case thirdWaveWavetable(isP: Bool)
    /// Embedded in a 3rd Wave `.pgdata`, under the slot label it was stored with (e.g., "U56").
    case unifiedProgram(slot: String, isP: Bool)
    /// A WAV file.
    case wav
    /// A FLAC file (as Phase Plant's library uses).
    case flac
    /// A Surge `.wt` binary file (header "vawt").
    case surgeWavetable
}

/// What a found table's frame size rests on, from the most certain to the least.
public enum FrameSizeEvidence: String, Equatable, Sendable {
    /// Stated in the file's contents: a WAV's `clm `, `srge`, or `uhWT` chunk, a Surge `.wt`
    /// header, or the fixed layout of a 3rd Wave table.
    case statedInFile
    /// A Tonverk-style `_wt<N>` tag in the file name.
    case fileName
    /// A Serum `.txt` file beside the WAV.
    case sidecar
    /// Evenly spaced `cue ` points or a single `smpl` loop: markers that ordinary samples have
    /// too, so less certain.
    case markers
    /// The file's length only: 2,048 per frame by convention, an estimate the user may need to change.
    case length
    /// Nothing settles it: the user must choose from `candidateFrameSizes`.
    case none
}

/// Where a claim about a table's frame size comes from: metadata inside the file, its name, a
/// file beside it, its markers, its fixed layout, or its length alone. The same places (a `clm `
/// chunk, a Tonverk tag, a Serum sidecar) can also ask for an interpolation.
public enum FrameSizeSource: Equatable, Sendable {
    /// A Serum-style `clm ` chunk in a WAV, or the same tag in a FLAC application block or
    /// comment.
    case clmChunk
    /// A Surge `srge` chunk (or FLAC application block).
    case srgeChunk
    /// A u-he `uhWT` chunk (or FLAC application block).
    case uhWTChunk
    /// A Tonverk `_wt<N>` tag at the end of the file name, with the tag's text (e.g., "_wt1024r").
    case tonverkFileName(tag: String)
    /// A Serum `.txt` file beside the WAV or FLAC file.
    case serumSidecar
    /// Evenly spaced `cue ` points.
    case cueMarkers
    /// A single `smpl` loop over the first frame.
    case loopMarkers
    /// The header of a Surge `.wt` file.
    case surgeHeader
    /// The fixed layout of a 3rd Wave P table (64 × 128) or U table (64 × 1,024).
    case thirdWaveTable(isP: Bool)
    /// The file's length alone: 2,048 samples per frame by convention.
    case fileLength
}

/// Something a reader found worth telling the user about a table: what it is (`kind`), which a
/// tool can weigh and shorten, and the sentence that says it (`text`).
public struct ReadNote: Equatable, Sendable {
    /// What a note is about. Each case covers one of the things the readers report.
    public enum Kind: Equatable, Sendable {
        /// The largest absolute sample, above 1 (the 3rd Wave's own tables and 16-bit files
        /// cannot hold more).
        case peak(Float)
        /// A file of `of` channels, of which only the first `used` are read.
        case channelsDropped(used: Int, of: Int)
        /// Two sources state different frame sizes; the one with precedence (`chosen`) is used.
        case sizeClaimsDisagree(chosen: FrameSizeSource, chosenSize: Int, other: FrameSizeSource, otherSize: Int)
        /// Two sources ask for different interpolations; the one with precedence is used.
        case interpolationClaimsDisagree(chosen: FrameSizeSource, chosenValue: Interpolation,
                                         other: FrameSizeSource, otherValue: Interpolation)
        /// Samples after the last whole frame are left out; when at least half a frame is left
        /// out, `shortOfAnotherFrame` says how many more samples would have made one.
        case samplesLeftOut(Int, shortOfAnotherFrame: Int?)
        /// The WAV's audio runs past the end of the file; what is there is read.
        case cutShort
        /// A source states a frame size that cannot be used, so it is ignored.
        case sizeTagRejected(source: FrameSizeSource, size: Int, reason: SizeRejection)
        /// A source's size cannot be read (a `clm ` tag without a number, an `srge` chunk too
        /// short), so it is ignored.
        case sizeTagUnreadable(source: FrameSizeSource)
        /// A Serum sidecar's size is outside the 32–9,999 Serum accepts, so it is ignored.
        case sidecarOutOfRange(Int)
        /// More frames than `limit`, the most some destinations take.
        case highFrameCount(Int, limit: Int)
        /// A Surge `.wt` whose frame size Surge itself does not write (not a power of two up
        /// to 4,096).
        case unusualSurgeFrameSize(Int)
        /// In a FLAC file, the Serum-style tag was found in a comment (`key`), not in an
        /// application block.
        case tagInComment(key: String)
        /// In a FLAC file, a comment mentions frames, cycles, or wavetables; it is not used.
        case commentMentionsFrames(key: String, value: String)
    }

    /// Why a stated frame size is ignored.
    public enum SizeRejection: Equatable, Sendable {
        /// Fewer than 2 samples per frame.
        case unusableSize
        /// The file holds fewer samples than one frame (`samples` of them).
        case fileShorterThanFrame(samples: Int)
    }

    /// What the note is about.
    public var kind: Kind
    /// The note as a sentence for the user.
    public var text: String

    /// Creates a note.
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

/// A wavetable found in a file, before or after its frame size is settled.
public struct FoundTable: Equatable, Sendable {
    /// The table's name.
    public var name: String
    /// The file it came from (its name, not its path).
    public var fileName: String
    /// The kind of file.
    public var source: SourceFormat
    /// All samples, frame after frame. For a 3rd Wave U table, the first 65,536 values (the
    /// table, without its mipmap chain); for a P table, the samples without their differences.
    public var samples: [Float]
    /// Samples per frame, or nil when the file does not say and its length allows several
    /// sizes (see `candidateFrameSizes`); a tool must then ask, not guess.
    public var frameSize: Int?
    /// How the frame size was decided, as a short phrase for display (e.g., "clm chunk",
    /// "Tonverk file name (_wt1024)", "3rd Wave U table", "file length").
    public var frameSizeBasis: String
    /// What settled `frameSize`, as a value (`frameSizeBasis` is the same in words); nil when
    /// the file leaves the size open.
    public var frameSizeSource: FrameSizeSource?
    /// Frame sizes the file's length allows: when `frameSize` is nil, the sizes to choose from;
    /// when it rests on the length only, the other sizes that fit.
    public var candidateFrameSizes: [Int]
    /// What `frameSize` rests on.
    public var frameSizeEvidence: FrameSizeEvidence
    /// Whether and how the file asks a synth to interpolate between frames, when it says.
    public var interpolation: Interpolation?
    /// For a table from a 3rd Wave `.wt` or `.pgdata`: the content fingerprint pgdata Packer's
    /// factory library uses (FNV-1a 64 of all the file's values as float32), so factory tables can
    /// be recognized. Nil for other sources.
    public var thirdWaveFingerprint: UInt64?
    /// Things worth telling the user about this table (e.g., samples beyond ±1), each with what
    /// it is about and its sentence.
    public var readNotes: [ReadNote]

    /// The notes as sentences (`readNotes`' text).
    public var notes: [String] { readNotes.map(\.text) }

    /// Creates a found table; see the properties for what each value means.
    public init(name: String, fileName: String, source: SourceFormat, samples: [Float], frameSize: Int?,
                frameSizeBasis: String, candidateFrameSizes: [Int] = [], interpolation: Interpolation? = nil,
                thirdWaveFingerprint: UInt64? = nil, readNotes: [ReadNote] = [],
                frameSizeEvidence: FrameSizeEvidence? = nil, frameSizeSource: FrameSizeSource? = nil) {
        self.name = name; self.fileName = fileName; self.source = source; self.samples = samples
        self.frameSize = frameSize; self.frameSizeBasis = frameSizeBasis
        self.candidateFrameSizes = candidateFrameSizes; self.interpolation = interpolation
        self.thirdWaveFingerprint = thirdWaveFingerprint; self.readNotes = readNotes
        self.frameSizeEvidence = frameSizeEvidence ?? (frameSize == nil ? .none : .statedInFile)
        self.frameSizeSource = frameSizeSource
    }

    /// The largest absolute sample (computed each time; cache it when it is needed often).
    public var peak: Float { samples.reduce(0) { max($0, abs($1)) } }

    /// The table cut into frames of `size` samples (default: `frameSize`); nil when no size is
    /// known or the samples do not divide evenly.
    public func wavetable(frameSize size: Int? = nil) -> Wavetable? {
        guard let n = size ?? frameSize, n > 0, !samples.isEmpty, samples.count % n == 0 else { return nil }
        let frames = stride(from: 0, to: samples.count, by: n).map { Array(samples[$0..<($0 + n)]) }
        return Wavetable(name: name, frames: frames, interpolation: interpolation)
    }
}

/// A destination for a converted wavetable.
public enum OutputPreset: String, Equatable, Sendable, CaseIterable {
    // The 3rd Wave's two kinds first, P before U as the 3rd Wave orders them; `allCases` is the
    // order the Wavetables page lists destinations in.
    /// A 3rd Wave P table `.wt`: 64 frames of 128 samples, each stored with its differences.
    case thirdWaveP
    /// A 3rd Wave U table `.wt`: 64 frames of 1,024 samples, plus a band-limited mipmap chain.
    case thirdWaveU
    /// A 32-bit float WAV of 2,048-sample frames with a `clm ` chunk, up to 256 frames (Serum,
    /// Vital, Pigments, and others).
    case wav2048
    /// A 32-bit float WAV of 64 frames of 2,048 samples with a `clm ` chunk, for MiniFreak V to
    /// import and send to a MiniFreak (which stores 64 frames; the writer reduces larger tables
    /// itself rather than leave it to MiniFreak V).
    case miniFreak
    /// A WAV for Tonverk, its frame size and interpolation in the file name.
    case tonverk
    /// A WAV of exactly 256 frames of 2,048 samples (Phase Plant).
    case phasePlant
    /// A Surge `.wt` binary file.
    case surge
    /// A 16-bit WAV of 64 frames of 256 samples (WaveEdit, for the Synthesis Technology E370/E352).
    case waveEdit
}

/// How to reach a destination's frame count when the source has a different one.
public enum FrameCountPolicy: String, Equatable, Sendable, CaseIterable {
    /// Keep the first and last frames and space the rest evenly (no new waveforms).
    case pickEvenly
    /// Crossfade between neighboring source frames.
    case interpolate
}

/// Choices that apply to a conversion.
public struct OutputOptions: Equatable, Sendable {
    /// How to reach the destination's frame count, when it differs from the source's.
    public var frameCountPolicy: FrameCountPolicy
    /// The interpolation to record, for destinations whose files can say (Serum-style `clm `
    /// chunks, Tonverk names); nil keeps the source's, or the destination's default.
    public var interpolation: Interpolation?
    /// Tonverk only: the frame size to write (64, 128, …, 4,096); nil keeps the source's when
    /// Tonverk accepts it, otherwise 2,048.
    public var tonverkFrameSize: Int?
    /// 3rd Wave P tables only: fit the table into frames 0–59 (by `frameCountPolicy`, keeping its
    /// first and last frames) and put the PPG's four standard waveforms (triangle, narrow pulse,
    /// square, sawtooth) at 60–63, as the 3rd Wave's PPG-derived tables have them.
    public var appendPPGStandardWaves: Bool

    /// Creates options; the defaults pick frames evenly and keep the source's interpolation.
    public init(frameCountPolicy: FrameCountPolicy = .pickEvenly, interpolation: Interpolation? = nil,
                tonverkFrameSize: Int? = nil, appendPPGStandardWaves: Bool = false) {
        self.frameCountPolicy = frameCountPolicy; self.interpolation = interpolation
        self.tonverkFrameSize = tonverkFrameSize; self.appendPPGStandardWaves = appendPPGStandardWaves
    }
}

/// A converted file, ready to write.
public struct OutputFile: Equatable, Sendable {
    /// The file name to write, with its extension.
    public var fileName: String
    /// The folder it belongs in on its destination, when there is a convention (e.g., "WAVES" on
    /// the 3rd Wave's USB drive).
    public var folder: String?
    /// The file's bytes.
    public var data: Data
    /// What the conversion did that the user should know (e.g., frame count changed, scaled to fit).
    public var notes: [String]

    /// Creates an output file.
    public init(fileName: String, folder: String? = nil, data: Data, notes: [String] = []) {
        self.fileName = fileName; self.folder = folder; self.data = data; self.notes = notes
    }
}

/// Why a file could not be read or a table could not be converted: what went wrong (`kind`), and
/// the reason as a sentence for the user (`description`).
public struct WavetableError: Error, Equatable, CustomStringConvertible, Sendable {
    /// What went wrong.
    public enum Kind: Equatable, Sendable {
        /// A file of a known format that is cut short, inconsistent with itself, or fails a
        /// check (a WAV without its format chunk, a FLAC frame with a wrong checksum, a Surge
        /// header promising more data than the file holds, a 3rd Wave file that will not parse).
        case damaged
        /// A file of a known format in a form this library does not read: a big-endian (RIFX)
        /// WAV, or a WAV marked as a wavetable whose samples are compressed or of an unhandled
        /// sample format.
        case unsupported
        /// A file marked as a wavetable (a `clm `, `srge`, or `uhWT` chunk, a Tonverk tag) whose
        /// stated frame size cannot be used, with nothing else to go on.
        case notAWavetable
        /// A table that cannot be written for the destination: empty, with frames of unequal
        /// length, with values that are not finite, or with an option the destination does not
        /// take.
        case cannotConvert
        /// The file could not be read from disk.
        case ioFailure
    }

    /// What went wrong.
    public var kind: Kind
    /// The reason, as a sentence.
    public var description: String

    /// Creates an error of `kind` with its reason.
    public init(_ kind: Kind, _ description: String) { self.kind = kind; self.description = description }

    /// Creates an error with its reason, of kind `.damaged` (the readers' usual complaint).
    public init(_ description: String) { self.init(.damaged, description) }
}
