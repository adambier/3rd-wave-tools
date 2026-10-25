import Foundation
#if canImport(PgdataFormats)
import PgdataFormats
#endif

/// Finds the wavetables in a file.
///
/// Files are judged by their content, not their extension: a Surge `.wt` starts with `vawt`, a
/// 3rd Wave `.wt` is text starting `PNAME` or `UNAME`, a `.pgdata` starts with `W3_UNIPROG_1`, and
/// a WAV is a RIFF file of type `WAVE`. Anything else holds no wavetable.
///
/// The format-specific parts are in `ReadThirdWave.swift`, `ReadSurge.swift`, and `ReadWAV.swift`.
public enum WavetableReader {
    /// The file extensions worth reading, lowercased.
    static let wavetableExtensions: Set<String> = ["wt", "pgdata", "wav", "wave"]

    /// Whether a file name is worth reading at all: `.wt`, `.pgdata`, `.wav`, or `.wave` (in any
    /// case), and not a hidden file (one whose name starts with a period).
    public static func mayContainWavetables(fileName: String) -> Bool {
        guard !fileName.hasPrefix("."), let dot = fileName.lastIndex(of: ".") else { return false }
        return wavetableExtensions.contains(fileName[fileName.index(after: dot)...].lowercased())
    }

    /// Every wavetable in `data`, judged by content rather than extension; empty when the file
    /// holds none (e.g., a program, a multisample, a one-shot sample, or audio whose length does
    /// not divide into frames). `sidecarText` is the contents of a Serum-style `.txt` sidecar for a
    /// WAV, if one exists.
    ///
    /// - Throws: ``WavetableError`` when the file is recognisably a wavetable format (a Surge
    ///   `.wt`, a 3rd Wave `.wt` or `.pgdata`, or a WAV) but is damaged, or is a WAV marked as a
    ///   wavetable in a sample format this reader does not decode.
    public static func read(_ data: Data, fileName: String, sidecarText: String? = nil) throws -> [FoundTable] {
        let bytes = [UInt8](data)
        if hasPrefix(bytes, "vawt") { return try readSurge(bytes, fileName: fileName) }
        if isRIFFWave(bytes) { return try readWAV(bytes, fileName: fileName, sidecarText: sidecarText) }
        if hasPrefix(bytes, "RIFX"), bytes.count >= 12, hasPrefix(Array(bytes[8..<12]), "WAVE") {
            throw WavetableError("\"\(fileName)\" is a big-endian WAV (RIFX), which Convert does not read.")
        }
        if hasPrefix(bytes, UnifiedProgram.magicText) { return try readUnifiedProgram(bytes, fileName: fileName) }
        if let text = thirdWaveText(bytes) { return try readThirdWaveText(text, fileName: fileName) }
        return []
    }

    /// Reads a file, and for a WAV also its Serum-style sidecar (`<name>.txt`, or `FolderInfo.txt`
    /// in the same folder) when present.
    ///
    /// - Throws: ``WavetableError`` when the file cannot be read, or for the reasons
    ///   ``read(_:fileName:sidecarText:)`` gives.
    public static func read(url: URL) throws -> [FoundTable] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw WavetableError("\"\(url.lastPathComponent)\" could not be read: \(error.localizedDescription)")
        }
        var sidecar: String?
        if data.count >= 12, isRIFFWave([UInt8](data.prefix(12))) {
            let folder = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            for name in [stem + ".txt", "FolderInfo.txt"] {
                if let d = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                    sidecar = String(data: d, encoding: .utf8) ?? String(d.map { Character(Unicode.Scalar($0)) })
                    break
                }
            }
        }
        return try read(data, fileName: url.lastPathComponent, sidecarText: sidecar)
    }
}

// MARK: - Helpers shared by the Read*.swift files

extension WavetableReader {
    /// Whether `bytes` begins with the ASCII text `prefix`.
    static func hasPrefix(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        return bytes.count >= p.count && Array(bytes[0..<p.count]) == p
    }

    /// Whether `bytes` begins with a RIFF header of form type `WAVE`.
    static func isRIFFWave(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12 && hasPrefix(bytes, "RIFF") && hasPrefix(Array(bytes[8..<12]), "WAVE")
    }

    /// Little-endian unsigned 16-bit value at `o`.
    static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }

    /// Little-endian unsigned 32-bit value at `o`.
    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// The file name without its extension.
    static func fileStem(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }

    /// An integer with thousands separators ("16,384"), independent of locale.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }

    /// A note for samples beyond ±1, or nil when the peak is within it.
    static func peakNote(_ peak: Float) -> String? {
        guard peak > 1 else { return nil }
        return "Its samples reach \(String(format: "%.2f", Double(peak))), beyond ±1."
    }

    /// A note for a table of more than 256 frames, or nil.
    static func frameCountNote(_ frames: Int) -> String? {
        guard frames > 256 else { return nil }
        return "It has \(grouped(frames)) frames, more than the 256 that Serum and Pigments take."
    }
}
