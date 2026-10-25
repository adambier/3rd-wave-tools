import Foundation

/// Writes a wavetable for a destination.
public enum WavetableWriter {
    /// Converts `table` to `preset`'s format: frame size, frame count, sample format, metadata,
    /// and file name.
    public static func write(_ table: Wavetable, preset: OutputPreset, options: OutputOptions = OutputOptions()) throws -> OutputFile {
        fatalError("Not implemented yet")
    }
}

public extension OutputPreset {
    /// The name shown to the user (e.g., "Serum, Vital, Pigments, MiniFreak V (2,048)").
    var title: String { fatalError("Not implemented yet") }
    /// Where the preset's behaviour comes from: the apps or hardware it has been tested in (empty
    /// when it rests only on the maker's documentation).
    var testedIn: [String] { fatalError("Not implemented yet") }
}
