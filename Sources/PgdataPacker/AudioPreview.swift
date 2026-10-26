import Foundation
import AVFoundation
import CoreAudio
import Combine
#if canImport(WavetableFormats)
import WavetableFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// Plays one cycle of a wavetable at a chosen pitch, for the Wavetables page's Listen control:
/// the cycle at the Frame slider, replaced as the slider moves, through the audio output device
/// chosen in the toolbar. One engine for the app (`shared`); everything here runs on the main
/// thread except `Voice.render`, which the audio thread calls.
///
/// The cycle is band-limited before it is played (`Resampling.bandLimitedCycle`): at the pitch
/// chosen, every harmonic above half the sample rate would alias, so those are removed, as a
/// wavetable oscillator does. The level is held down (−12 dB, and a table whose values go past
/// ±1 is scaled to fit), and starting, stopping, and each change of cycle are faded over a few
/// milliseconds, so nothing clicks.
///
/// Default pitch: A3, 220 Hz (`PianoKey.defaultPitch`). WaveEdit, the open-source editor for
/// Synthesis Technology's wavetable oscillators, previews at 220 Hz by default; an octave below
/// concert A, it is low enough to carry a table's character (at 48 kHz, 108 harmonics fit below
/// half the sample rate) and high enough for a laptop's speakers, which lose most of what lies
/// an octave lower. Middle C (261.6 Hz) is the other common choice; both are in the pop-up.
final class AudioPreview: ObservableObject {
    static let shared = AudioPreview()

    /// Whether a cycle is sounding (or fading out).
    @Published private(set) var isPlaying = false
    /// The pitch the cycle plays at; kept between sessions.
    @Published var pitch: PianoKey {
        didSet {
            UserDefaults.standard.set(pitch.number, forKey: Self.pitchKey)
            if isPlaying { retune() }
        }
    }
    /// The output devices with the system's current list of devices that can play.
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    /// The chosen output device's UID, nil for the system's default output; kept between
    /// sessions. A device that is not connected right now keeps its place here (the default is
    /// used meanwhile) and is used again when it returns.
    @Published var outputDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(outputDeviceUID, forKey: Self.outputKey)
            applyOutputDevice()
        }
    }
    /// Why playing failed, when it did (shown beside the Listen control).
    @Published private(set) var problem: String?

    /// The keys the pitch pop-up offers: C2 (65.4 Hz) to C6 (1,046.5 Hz).
    static let pitches = PianoKey.keys(16...64)

    private static let pitchKey = "ListenPitch"
    private static let outputKey = "ListenOutputDeviceUID"
    /// The band-limited cycle's length: long enough that reading it with linear interpolation
    /// adds little of its own. Every cycle handed to the voice has exactly this length.
    static let tableSize = 4096
    private static let gain: Float = 0.25   // −12 dB

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    /// The sample rate the source node renders at (the mixer converts to the device's).
    private var renderRate: Double = 48_000
    private let voice = Voice(tableSize: AudioPreview.tableSize)
    /// The cycle as given, full length, so a change of pitch can band-limit it again.
    private var cycle: [Float] = []
    private var stopWork: DispatchWorkItem?
    private var deviceListener: AudioOutputDevices.Listener?
    private var configurationObserver: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.pitchKey)
        let savedKey = PianoKey(saved > 0 ? saved : PianoKey.defaultPitch.number)
        // A saved pitch outside the pop-up's range (edited defaults) would leave it blank.
        pitch = Self.pitches.contains(savedKey) ? savedKey : PianoKey.defaultPitch
        outputDeviceUID = UserDefaults.standard.string(forKey: Self.outputKey)
        outputDevices = AudioOutputDevices.all()
        deviceListener = AudioOutputDevices.listen { [weak self] in
            guard let self else { return }
            self.outputDevices = AudioOutputDevices.all()
            self.applyOutputDevice()
        }
        // The engine stops itself when its output device goes away or changes its format (the
        // default output switching to headphones, say); it must then be started again.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartIfPlaying()
        }
    }

    /// The output device in use: the chosen one when it is connected, else the system default.
    var effectiveOutputDevice: AudioOutputDevice? {
        guard let uid = outputDeviceUID else { return nil }
        return outputDevices.first { $0.uid == uid }
    }

    // MARK: Playing

    /// Starts playing `cycle` (the values of one frame, or a blend of two), or replaces the cycle
    /// playing. Values beyond ±1 are allowed; the level is scaled to fit. An empty cycle plays
    /// silence.
    func play(_ cycle: [Float]) {
        stopWork?.cancel(); stopWork = nil
        self.cycle = cycle
        problem = nil
        if !engine.isRunning {
            do {
                try start()
            } catch {
                problem = "Can’t play: \(error.localizedDescription)"
                isPlaying = false
                return
            }
        }
        isPlaying = true
        retune()
        voice.setGain(Self.gain)
    }

    /// Replaces the cycle playing; nothing when not playing.
    func update(_ cycle: [Float]) {
        guard isPlaying else { return }
        self.cycle = cycle
        retune()
    }

    /// Fades out and stops the engine.
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        voice.setGain(0)
        // Long enough for the gain ramp at any buffer size the engine uses (the ramp is 10 ms;
        // a 4,096-frame buffer at 44.1 kHz is 93 ms).
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.pause()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Band-limits the cycle for the pitch and hands it to the voice.
    private func retune() {
        guard source != nil else { return }
        let rate = renderRate
        let f = pitch.frequency
        guard !cycle.isEmpty else { voice.set(table: [], increment: f / rate); return }
        // Keep the harmonics that stay below half the sample rate, with a little margin.
        let maxHarmonic = max(1, Int(rate / (2 * f)) - 1)
        var table = Resampling.bandLimitedCycle(cycle, to: Self.tableSize, maxHarmonic: maxHarmonic)
        let peak = table.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1 { table = table.map { $0 / peak } }
        voice.set(table: table, increment: f / rate)
    }

    private func start() throws {
        if source == nil {
            // The device first, so the render rate is the chosen device's, not the default's.
            applyOutputDevice()
            let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            renderRate = deviceRate > 0 ? deviceRate : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: renderRate, channels: 1) else {
                throw NSError(domain: "AudioPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "no mono format at \(Int(renderRate)) Hz"])
            }
            let voice = self.voice
            let node = AVAudioSourceNode(format: format) { (_: UnsafeMutablePointer<ObjCBool>, _: UnsafePointer<AudioTimeStamp>, frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let data = buffers[0].mData else { return noErr }
                voice.render(into: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        try engine.start()
    }

    /// Points the engine at the chosen device (or the system default). The engine is stopped for
    /// the change, since the device's format can differ; if it was playing, it starts again.
    private func applyOutputDevice() {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        let id = effectiveOutputDevice?.id ?? AudioOutputDevices.systemDefaultID()
        if let id, id != engine.outputNode.auAudioUnit.deviceID {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(id)
            } catch {
                problem = "Can’t use that output: \(error.localizedDescription)"
            }
        }
        if wasRunning { restartIfPlaying() }
    }

    /// Starts the engine again after it stopped on its own or for a device change, when a cycle
    /// should be sounding; says so when it can't.
    private func restartIfPlaying() {
        guard isPlaying, !engine.isRunning else { return }
        do {
            try engine.start()
            retune()
        } catch {
            problem = "Can’t play: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    // MARK: - The audio thread's side

    /// The oscillator the render block runs: one band-limited cycle read with linear
    /// interpolation at a phase increment, a gain that ramps to its target over about 10 ms, and
    /// a crossfade from the cycle before whenever the cycle is replaced.
    ///
    /// Nothing is allocated or freed on the audio thread: the voice owns three buffers of the
    /// one table size, and a new cycle goes into the staging buffer under a lock the main thread
    /// holds only for the copy; at the start of a buffer the render thread, under the same lock,
    /// rotates the three pointers (current becomes previous, staging becomes current, the old
    /// previous becomes staging). A new cycle waits while a crossfade is still running, so the
    /// output never jumps; the main thread may overwrite the staging buffer meanwhile, and the
    /// latest cycle is the one taken.
    final class Voice {
        private let lock: UnsafeMutablePointer<os_unfair_lock>
        private let size: Int
        private var current: UnsafeMutablePointer<Float>
        private var previous: UnsafeMutablePointer<Float>
        private var staging: UnsafeMutablePointer<Float>
        // Written by the main thread under the lock, read by the render thread under the lock.
        private var pending = false
        private var pendingIncrement: Double?
        private var pendingGain: Float?
        // The render thread's own.
        private var hasTable = false
        private var fade = 0
        private var increment: Double = 0
        private var phase: Double = 0
        private var gain: Float = 0
        private var targetGain: Float = 0
        /// Samples of crossfade when the cycle changes, and of gain ramp (at 48 kHz, 10 ms).
        private let fadeLength = 480

        init(tableSize: Int) {
            size = tableSize
            lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
            lock.initialize(to: os_unfair_lock())
            current = UnsafeMutablePointer<Float>.allocate(capacity: tableSize); current.initialize(repeating: 0, count: tableSize)
            previous = UnsafeMutablePointer<Float>.allocate(capacity: tableSize); previous.initialize(repeating: 0, count: tableSize)
            staging = UnsafeMutablePointer<Float>.allocate(capacity: tableSize); staging.initialize(repeating: 0, count: tableSize)
        }

        deinit {
            lock.deinitialize(count: 1); lock.deallocate()
            current.deallocate(); previous.deallocate(); staging.deallocate()
        }

        /// Leaves a cycle for the render thread: `table` is copied into the staging buffer (an
        /// empty table means silence; a shorter one is zero-padded, a longer one cut).
        func set(table: [Float], increment: Double) {
            os_unfair_lock_lock(lock)
            let n = min(table.count, size)
            table.withUnsafeBufferPointer { src in
                if n > 0, let base = src.baseAddress { staging.update(from: base, count: n) }
            }
            if n < size { (staging + n).update(repeating: 0, count: size - n) }
            pending = true
            pendingIncrement = increment
            os_unfair_lock_unlock(lock)
        }

        func setGain(_ g: Float) {
            os_unfair_lock_lock(lock)
            pendingGain = g
            os_unfair_lock_unlock(lock)
        }

        func render(into out: UnsafeMutablePointer<Float>, count: Int) {
            os_unfair_lock_lock(lock)
            if pending, fade == 0 {
                let old = previous
                previous = current
                current = staging
                staging = old
                if hasTable { fade = fadeLength }
                hasTable = true
                pending = false
            }
            if let newIncrement = pendingIncrement { increment = newIncrement; pendingIncrement = nil }
            if let newGain = pendingGain { targetGain = newGain; pendingGain = nil }
            os_unfair_lock_unlock(lock)
            guard hasTable else {
                out.update(repeating: 0, count: count)
                return
            }
            let step = 1 / Float(fadeLength)
            for i in 0..<count {
                var v = read(current, at: phase)
                if fade > 0 {
                    let w = Float(fade) / Float(fadeLength)
                    v = v * (1 - w) + read(previous, at: phase) * w
                    fade -= 1
                }
                if gain < targetGain { gain = min(targetGain, gain + step * 0.25) }
                else if gain > targetGain { gain = max(targetGain, gain - step * 0.25) }
                out[i] = v * gain
                phase += increment
                if phase >= 1 { phase -= 1 }
            }
        }

        /// The buffer's value at a phase of 0…1, linearly interpolated.
        private func read(_ table: UnsafeMutablePointer<Float>, at phase: Double) -> Float {
            let x = phase * Double(size)
            var i = Int(x)
            if i >= size { i -= size }
            let frac = Float(x - Double(i))
            let a = table[i], b = table[i + 1 == size ? 0 : i + 1]
            return a + (b - a) * frac
        }
    }
}

// MARK: - Output devices

/// An audio device that can play: its CoreAudio id for the engine, its UID (stable across
/// sessions, kept in the preferences), and its name for the pop-up.
struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// The system's output devices, from CoreAudio, and a listener for changes to the list.
enum AudioOutputDevices {
    /// Keeps the listener registered while it lives.
    final class Listener {
        fileprivate var addresses: [AudioObjectPropertyAddress]
        fileprivate let block: AudioObjectPropertyListenerBlock
        fileprivate init(addresses: [AudioObjectPropertyAddress], block: @escaping AudioObjectPropertyListenerBlock) {
            self.addresses = addresses; self.block = block
        }
        deinit {
            for i in addresses.indices {
                _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], DispatchQueue.main, block)
            }
        }
    }

    /// Every device with an output stream, in the system's order.
    static func all() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputStreamCount(id) > 0, let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The system's default output device, if CoreAudio names one.
    static func systemDefaultID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Calls `changed` on the main queue whenever devices come or go, or the default output
    /// changes, for as long as the returned listener lives.
    static func listen(_ changed: @escaping () -> Void) -> Listener {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        var defaultAddress = address
        defaultAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, block)
        return Listener(addresses: [address, defaultAddress], block: block)
    }

    private static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
