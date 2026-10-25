import XCTest
@testable import WavetableFormats

final class WavetableTypeTests: XCTestCase {
    func testFramesFromFoundTable() {
        let f = FoundTable(name: "T", fileName: "t.wav", source: .wav, samples: Array(repeating: 0, count: 8),
                           frameSize: 4, frameSizeBasis: "test")
        XCTAssertEqual(f.wavetable()?.frameCount, 2)
        XCTAssertNil(f.wavetable(frameSize: 3))
    }
}
