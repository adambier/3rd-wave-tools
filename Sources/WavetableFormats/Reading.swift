import Foundation

/// Finds the wavetables in a file.
public enum WavetableReader {
    /// Whether a file name is worth reading at all (by extension: `.wt`, `.pgdata`, `.wav`).
    public static func mayContainWavetables(fileName: String) -> Bool {
        fatalError("Not implemented yet")
    }

    /// Every wavetable in `data`, judged by content rather than extension; empty when the file
    /// holds none (e.g., a program or a multisample). `sidecarText` is the contents of a
    /// Serum-style `.txt` sidecar for a WAV, if one exists.
    public static func read(_ data: Data, fileName: String, sidecarText: String? = nil) throws -> [FoundTable] {
        fatalError("Not implemented yet")
    }

    /// Reads a file, and for a WAV also its Serum-style sidecar (`<name>.txt`, or `FolderInfo.txt`
    /// in the same folder) when present.
    public static func read(url: URL) throws -> [FoundTable] {
        fatalError("Not implemented yet")
    }
}
