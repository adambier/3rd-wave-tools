import Foundation

/// Changes a wavetable's frame size and frame count.
public enum Resampling {
    /// Resizes one periodic cycle to `size` samples, band-limited (exact for a periodic cycle).
    public static func resizeCycle(_ cycle: [Float], to size: Int) -> [Float] {
        fatalError("Not implemented yet")
    }

    /// Brings a table to `count` frames by the given policy; unchanged when it already has them.
    public static func changeFrameCount(_ frames: [[Float]], to count: Int, policy: FrameCountPolicy) -> [[Float]] {
        fatalError("Not implemented yet")
    }

    /// The 3rd Wave U table mipmap chain for 64 frames of 1,024 samples: the same frames at 512,
    /// 256, 128, 64, and 64 samples, band-limited (65,536 values). See FORMATS.md section 5.1.
    public static func thirdWaveMipmapChain(_ frames: [[Float]]) -> [Float] {
        fatalError("Not implemented yet")
    }
}
