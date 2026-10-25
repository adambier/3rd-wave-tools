import Foundation
#if canImport(PgdataFormats)
import PgdataFormats
#endif

// The 3rd Wave's own wavetables: `.wt` text files and the tables embedded in a `.pgdata`. Both are
// read with PgdataFormats, and each table's fingerprint is computed exactly as FactoryLibrary
// computes its factory fingerprints (WavetableFile.fingerprint: FNV-1a 64 of all the values as
// float32, the U table's mipmap chain included), so FactoryLibrary.builtIn.slot(withFingerprint:)
// recognises factory tables.

extension WavetableReader {
    /// The text of a 3rd Wave `.wt` (without a UTF-8 byte-order mark), or nil when `bytes` does not
    /// start with `PNAME` or `UNAME` (after an optional byte-order mark and leading spaces).
    static func thirdWaveText(_ bytes: [UInt8]) -> [UInt8]? {
        var b = bytes[...]
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { b = b.dropFirst(3) }
        let body = b.drop { $0 == 0x20 || $0 == 0x09 }
        guard body.starts(with: Array("PNAME".utf8)) || body.starts(with: Array("UNAME".utf8)) else { return nil }
        return Array(b)
    }

    /// The table in a 3rd Wave `.wt` file's text.
    static func readThirdWaveText(_ text: [UInt8], fileName: String) throws -> [FoundTable] {
        let wt: WavetableFile
        do { wt = try WavetableFile(data: Data(text)) } catch {
            throw WavetableError("\"\(fileName)\" begins like a 3rd Wave wavetable but could not be read: \(error)")
        }
        let name = wt.name.isEmpty ? fileStem(fileName) : wt.name
        return [thirdWaveTable(wt, name: name, fileName: fileName,
                               source: .thirdWaveWavetable(isP: wt.kind == .p))]
    }

    /// One table for each wavetable a `.pgdata` embeds; sources listed without data, multisamples,
    /// and analog waves are skipped.
    static func readUnifiedProgram(_ bytes: [UInt8], fileName: String) throws -> [FoundTable] {
        let u: UnifiedProgram
        do { u = try UnifiedProgram(data: Data(bytes)) } catch {
            throw WavetableError("\"\(fileName)\" is a 3rd Wave unified program (.pgdata) that could not be read: \(error)")
        }
        var out: [FoundTable] = []
        for src in u.sources {
            guard case let .wavetable(nameField, data) = src.payload else { continue }
            let isP = src.ref.isP
            let wt = WavetableFile(kind: isP ? .p : .u, name: nameField.text, dataBytes: data)
            guard wt.values.count == wt.kind.valueCount else {
                throw WavetableError("The \(src.ref.label) table in \(fileName) has \(wt.values.count) values; a \(wt.kind.letter) table needs \(wt.kind.valueCount).")
            }
            let label = src.ref.label
            out.append(thirdWaveTable(wt, name: wt.name.isEmpty ? label : wt.name, fileName: fileName,
                                      source: .unifiedProgram(slot: label, isP: isP)))
        }
        return out
    }

    /// A found table for a 3rd Wave P or U table: the P table's samples without their
    /// differences, or the U table's first 65,536 values (without its mipmap chain).
    static func thirdWaveTable(_ wt: WavetableFile, name: String, fileName: String, source: SourceFormat) -> FoundTable {
        let isP = wt.kind == .p
        let samples = wt.frames.flatMap { $0 }
        return FoundTable(name: name, fileName: fileName, source: source, samples: samples,
                          frameSize: isP ? 128 : 1024,
                          frameSizeBasis: isP ? "3rd Wave P table" : "3rd Wave U table",
                          thirdWaveFingerprint: wt.fingerprint,
                          notes: peakNote(wt.peak).map { [$0] } ?? [])
    }
}
