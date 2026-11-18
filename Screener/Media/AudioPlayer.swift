// Ported in part from iShareScreen src/isharescreen/proxy/media/aac_eld.py
// (_AudioToolboxBackend: _make_converter, _set_magic_cookie, _fill_callback)
// and src/isharescreen/frontend/desktop/audio_sink.py (jitter buffer) (AGPL-3.0)
//
// Remote audio (Milestone 6). The Mac sends one raw AAC-ELD-SBR access unit
// per RTP packet (PT 101, on UDP port P), 48 kHz stereo, 480 frames per
// packet; silence is a 4-byte all-zero AU.
//
//   MediaTransport.audio ─▶ AudioPlayer.handle (the consumer's thread)
//     mute? drop (no decode) │ older than 200 ms? drop
//     AACELDDecoder (AudioConverter → interleaved Float32)
//     → a pooled AVAudioPCMBuffer (deinterleaved) → AudioJitterBuffer decides:
//       hold (prefilling ~60 ms) / release (schedule everything held) /
//       play (schedule now) / drop (more than 200 ms queued: drain to target)
//     → AVAudioPlayerNode → mainMixer → output.
//
// An empty queue is an underrun: the player node outputs silence (it never
// stalls) and the buffer prefills again, its target 20 ms longer (up to
// 120 ms); 10 s without an underrun steps it back toward 60 ms.
//
// Threading: `handle` runs on the single audio consumer (off the main
// thread); decoding is confined to it. `control` serializes it with mute,
// interruptions, engine configuration changes and `stop`. `state` guards
// what the player node's completion handlers (an AVFoundation thread) touch:
// the jitter accounting and the buffer free list. Lock order: control → state;
// the player node is never stopped while `state` is held.
//
// AVAudioSession: .playback + .mixWithOthers, activated on the first
// scheduled PCM and deactivated on mute / stop. No background audio mode: the
// session (and so the audio) ends when the app goes to the background.
import AudioToolbox
import AVFoundation
import Foundation

// MARK: - AAC-ELD decoder

/// AudioToolbox AAC-ELD-SBR → interleaved Float32 stereo, one RTP payload
/// per `decode` (aac_eld.py `_AudioToolboxBackend`). Not thread-safe: use
/// from one thread at a time.
final class AACELDDecoder {
    static let sampleRate: Double = 48_000
    static let channels: UInt32 = 2
    static let framesPerPacket: UInt32 = 480
    /// The 43-byte MPEG-4 ES_Descriptor screensharingd emits (wraps the
    /// AudioSpecificConfig f8e65132e000: AOT 39, 48 kHz, stereo, 480-frame,
    /// SBR). aac_eld.py MAGIC_COOKIE.
    static let magicCookie: [UInt8] = [
        0x03, 0x80, 0x80, 0x80, 0x26, 0x00, 0x00, 0x00, 0x04, 0x80, 0x80, 0x80, 0x18, 0x40, 0x14, 0x00,
        0x18, 0x00, 0x00, 0x01, 0x38, 0x80, 0x00, 0x00, 0x00, 0x00, 0x05, 0x80, 0x80, 0x80, 0x06, 0xF8,
        0xE6, 0x51, 0x32, 0xE0, 0x00, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
    ]
    /// The input proc's "nothing queued" status (aac_eld.py _CB_STATUS_QUEUE_EMPTY).
    static let queueEmpty: OSStatus = 1
    /// Largest payload accepted (a 10 ms AU at ~21 kbps is ~30 bytes).
    static let maxPayload = 4096

    struct SetupError: Error, Equatable {
        let stage: String
        let status: OSStatus
    }

    private var converter: AudioConverterRef?
    private let input = UnsafeMutableRawPointer.allocate(byteCount: maxPayload, alignment: 16)
    private var inputLength = 0
    private var hasInput = false
    private let packetDesc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    /// Interleaved L/R output of the last successful `decode`.
    let output = UnsafeMutablePointer<Float>.allocate(capacity: Int(framesPerPacket * channels))

    init() throws(SetupError) {
        packetDesc.initialize(to: AudioStreamPacketDescription())
        output.initialize(repeating: 0, count: Int(Self.framesPerPacket * Self.channels))
        // _make_converter
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD_SBR, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 0, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: Self.channels * 4, mFramesPerPacket: 1, mBytesPerFrame: Self.channels * 4,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inFormat, &outFormat, &conv)
        guard status == noErr, let conv else { throw SetupError(stage: "AudioConverterNew", status: status) }
        converter = conv   // disposed by deinit, which also runs when init throws below
        // _set_magic_cookie
        let cookieStatus = Self.magicCookie.withUnsafeBytes {
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }
        guard cookieStatus == noErr else { throw SetupError(stage: "MagicCookie", status: cookieStatus) }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        input.deallocate()
        packetDesc.deallocate()
        output.deallocate()
    }

    /// Forgets decoder state (after a gap, e.g. while muted).
    func reset() {
        if let converter { AudioConverterReset(converter) }
        hasInput = false
    }

    /// Decodes one RTP payload into `output`; returns the frame count, or nil
    /// when the payload is empty / unusable or the decoder is still priming.
    func decode(_ payload: Data) -> Int? {
        guard let converter, !payload.isEmpty, payload.count <= Self.maxPayload else { return nil }
        payload.withUnsafeBytes { input.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        inputLength = payload.count
        hasInput = true
        let capacity = Self.framesPerPacket * Self.channels * 4
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: Self.channels, mDataByteSize: capacity,
                                                        mData: UnsafeMutableRawPointer(output)))
        var packets = Self.framesPerPacket
        let status = AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDesc, user in
            // _fill_callback: hand the queued AU over as one packet.
            let d = Unmanaged<AACELDDecoder>.fromOpaque(user!).takeUnretainedValue()
            guard d.hasInput else {
                ioPackets.pointee = 0
                return AACELDDecoder.queueEmpty
            }
            d.hasInput = false
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = d.input
            ioData.pointee.mBuffers.mDataByteSize = UInt32(d.inputLength)
            ioData.pointee.mBuffers.mNumberChannels = AACELDDecoder.channels
            d.packetDesc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                mDataByteSize: UInt32(d.inputLength))
            outDesc?.pointee = d.packetDesc
            ioPackets.pointee = 1
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &packets, &abl, nil)
        hasInput = false
        guard status == noErr || status == Self.queueEmpty else {
            AudioConverterReset(converter)
            return nil
        }
        let frames = Int(abl.mBuffers.mDataByteSize) / Int(Self.channels * 4)
        guard packets > 0, frames > 0 else { return nil }
        return frames
    }
}

// MARK: - Jitter buffer (pure)

/// Frame accounting for the player node's queue (audio_sink.py's
/// fixed-target buffer, made adaptive). Frames are 48 kHz frames.
struct AudioJitterBuffer: Sendable {
    struct Config: Sendable {
        /// Prefill before playing: 60 ms.
        var baseTargetFrames = 2_880
        /// Upper bound for the adaptive target: 120 ms.
        var maxTargetFrames = 5_760
        /// Target growth per underrun / shrink per quiet period: 20 ms.
        var targetStepFrames = 960
        /// Never queue more than this (latency bound): 200 ms.
        var maxQueuedFrames = 9_600
        /// Frames played without an underrun before the target shrinks: 10 s.
        var relaxAfterFrames = 480_000
    }

    enum State: Sendable { case buffering, playing, draining }
    enum Decision: Sendable, Equatable {
        /// Keep it; still prefilling.
        case hold
        /// Prefill reached: schedule everything held (including this one).
        case release
        /// Schedule it now.
        case play
        /// Discard it (too much queued).
        case drop
    }

    let config: Config
    private(set) var state = State.buffering
    private(set) var targetFrames: Int
    /// Held while prefilling, not yet scheduled.
    private(set) var heldFrames = 0
    /// Scheduled on the player node and not yet consumed.
    private(set) var queuedFrames = 0
    private(set) var underruns = 0
    private(set) var drops = 0
    private var framesSinceUnderrun = 0

    init(config: Config = Config()) {
        self.config = config
        targetFrames = config.baseTargetFrames
    }

    mutating func enqueue(_ frames: Int) -> Decision {
        if state == .buffering {
            heldFrames += frames
            guard heldFrames >= targetFrames else { return .hold }
            queuedFrames += heldFrames
            heldFrames = 0
            state = .playing
            return .release
        }
        if state == .draining {
            guard queuedFrames <= targetFrames else { drops += 1; return .drop }
            state = .playing
        }
        if queuedFrames + frames > config.maxQueuedFrames {
            // Bounded latency: drop until the queue is back at the target.
            state = .draining
            drops += 1
            return .drop
        }
        queuedFrames += frames
        return .play
    }

    /// The player node consumed `frames`. Returns true on an underrun (the
    /// queue ran dry while playing): prefill again, with a longer target.
    @discardableResult
    mutating func consumed(_ frames: Int) -> Bool {
        queuedFrames = max(0, queuedFrames - frames)
        framesSinceUnderrun += frames
        if framesSinceUnderrun >= config.relaxAfterFrames {
            framesSinceUnderrun = 0
            targetFrames = max(config.baseTargetFrames, targetFrames - config.targetStepFrames)
        }
        guard queuedFrames == 0, state != .buffering else { return false }
        underruns += 1
        state = .buffering
        targetFrames = min(config.maxTargetFrames, targetFrames + config.targetStepFrames)
        framesSinceUnderrun = 0
        return true
    }

    /// Flush (mute, interruption, stop): nothing held or queued; prefill again.
    mutating func reset() {
        state = .buffering
        heldFrames = 0
        queuedFrames = 0
        framesSinceUnderrun = 0
        targetFrames = config.baseTargetFrames
    }
}

// MARK: - Player

final class AudioPlayer: @unchecked Sendable {
    /// UserDefaults / @AppStorage key of the floating menu's Mute toggle.
    static let mutedDefaultsKey = "audio.muted"
    /// Packets that waited longer than this (consumer lag) are dropped.
    static let maxLateness: Duration = .milliseconds(200)
    static let poolSize = 48

    enum Outcome: Equatable {
        case muted, stopped, stale, undecodable, unavailable, held, scheduled, dropped
    }

    struct Counters: Equatable {
        var packets = 0, decoded = 0, mutedDrops = 0, staleDrops = 0, undecodable = 0, poolDrops = 0
    }

    // control-protected (and the decoder: used only inside `handle`)
    private let control = NSLock()
    private let decoder: AACELDDecoder?
    private var muted: Bool
    private var stopped = false
    private var held: [Int] = []
    private var counters = Counters()
    private var loggedFirstPCM = false
    private var sessionActive = false
    /// Created on the first PCM to play (a session that never gets audio,
    /// or stays muted, never touches the audio hardware).
    private var output: (engine: AVAudioEngine, node: AVAudioPlayerNode)?
    private var retryAt: ContinuousClock.Instant?
    private var startFailureLogged = false
    private var lastStats = (underruns: 0, drops: 0, stale: 0, undecodable: 0)
    private var observers: [any NSObjectProtocol] = []

    // state-protected (shared with the player node's completion handlers)
    private let state = NSLock()
    /// System notifications (interruption, engine configuration change, media
    /// services reset) are handled here, never inline: one posted from inside
    /// an engine / session call made under `control` must not re-enter it.
    private let notifications = DispatchQueue(label: "screener.audio.notifications")
    private var jitter: AudioJitterBuffer
    private var free: [Int]
    private var epoch = 0

    // immutable after init
    private let defaults: UserDefaults
    private let format: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]

    init(defaults: UserDefaults = .standard, jitter: AudioJitterBuffer.Config = .init()) {
        self.defaults = defaults
        muted = defaults.bool(forKey: Self.mutedDefaultsKey)
        self.jitter = AudioJitterBuffer(config: jitter)
        let format = AVAudioFormat(standardFormatWithSampleRate: AACELDDecoder.sampleRate,
                                   channels: AVAudioChannelCount(AACELDDecoder.channels))!
        self.format = format
        buffers = (0..<Self.poolSize).map { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AACELDDecoder.framesPerPacket)!
        }
        free = Array((0..<Self.poolSize).reversed())
        held.reserveCapacity(Self.poolSize)
        do {
            decoder = try AACELDDecoder()
        } catch {
            decoder = nil
            Log.audio.error("AAC-ELD decoder unavailable (\(error.stage) \(error.status)); audio off")
        }
        observe()
        Log.audio.info("audio player ready\(muted ? " (muted)" : "")")
    }

    var isMuted: Bool { control.withLock { muted } }
    var counterSnapshot: Counters { control.withLock { counters } }
    var jitterSnapshot: AudioJitterBuffer { state.withLock { jitter } }

    /// One RTP packet from `MediaTransport.audio`. Called by the single audio
    /// consumer only.
    @discardableResult
    func handle(_ packet: MediaPacket, now: ContinuousClock.Instant = .now) -> Outcome {
        control.lock()
        defer { control.unlock() }
        if stopped { return .stopped }
        counters.packets += 1
        if counters.packets % 1000 == 0 { logStatsIfChanged() }
        if muted { counters.mutedDrops += 1; return .muted }
        if now - packet.arrival > Self.maxLateness { counters.staleDrops += 1; return .stale }
        guard let decoder else { return .unavailable }
        guard let frames = decoder.decode(packet.payload) else { counters.undecodable += 1; return .undecodable }
        counters.decoded += 1
        if !loggedFirstPCM {
            loggedFirstPCM = true
            Log.audio.info("M6 audio first pcm frames=\(frames)")
        }
        let (slot, decision, tag): (Int?, AudioJitterBuffer.Decision, Int) = state.withLock {
            guard let slot = free.popLast() else { return (nil, .drop, epoch) }
            return (slot, jitter.enqueue(frames), epoch)
        }
        guard let slot else { counters.poolDrops += 1; return .dropped }
        let buffer = buffers[slot]
        Self.deinterleave(decoder.output, frames: frames, into: buffer)

        switch decision {
        case .hold:
            held.append(slot)
            return .held
        case .drop:
            recycle(slot)
            return .dropped
        case .release, .play:
            if decision == .release { held.append(slot) }
            guard ensureRunning(now) else {
                resetPlayback(stopNode: false)   // nothing is playing: just release what is held
                if decision == .play { recycle(slot) }
                return .unavailable
            }
            if decision == .release {
                for s in held { schedule(s, epoch: tag) }
                held.removeAll(keepingCapacity: true)
            } else {
                schedule(slot, epoch: tag)
            }
            return .scheduled
        }
    }

    /// Ends playback for good (disconnect / background): flush, stop the
    /// engine, release the audio session.
    func stop() {
        control.lock()
        defer { control.unlock() }
        guard !stopped else { return }
        stopped = true
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        resetPlayback()
        output?.engine.stop()
        deactivateSession()
        let j = jitterSnapshot
        Log.audio.info("audio stopped: packets=\(counters.packets) decoded=\(counters.decoded) "
                       + "underruns=\(j.underruns) drops=\(j.drops + counters.poolDrops) stale=\(counters.staleDrops) "
                       + "undecodable=\(counters.undecodable) muted=\(counters.mutedDrops)")
    }

    func setMuted(_ value: Bool) {
        control.lock()
        defer { control.unlock() }
        guard value != muted, !stopped else { return }
        muted = value
        Log.audio.info(value ? "audio muted" : "audio unmuted")
        guard value else { decoder?.reset(); return }
        // Muted: no decoding, no engine, no session until unmuted.
        resetPlayback()
        output?.engine.stop()
        deactivateSession()
    }

    // MARK: control-locked helpers

    private func schedule(_ slot: Int, epoch tag: Int) {
        let frames = Int(buffers[slot].frameLength)
        output?.node.scheduleBuffer(buffers[slot], completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.consumed(slot: slot, frames: frames, epoch: tag)
        }
    }

    /// Completion handler (AVFoundation thread): `state` only.
    private func consumed(slot: Int, frames: Int, epoch tag: Int) {
        state.withLock {
            free.append(slot)
            if tag == epoch { jitter.consumed(frames) }
        }
    }

    private func recycle(_ slot: Int) {
        state.withLock { free.append(slot) }
    }

    /// Drops everything held or queued and prefills again. Completions of
    /// buffers flushed here belong to the old epoch: they only recycle.
    private func resetPlayback(stopNode: Bool = true) {
        state.withLock {
            epoch += 1
            jitter.reset()
            free.append(contentsOf: held)
        }
        held.removeAll(keepingCapacity: true)
        if stopNode { output?.node.stop() }
    }

    private func ensureRunning(_ now: ContinuousClock.Instant) -> Bool {
        if let output, output.engine.isRunning, output.node.isPlaying { return true }
        if let retryAt, now < retryAt { return false }
        do {
            if !sessionActive {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                sessionActive = true
            }
            let (engine, node) = output ?? makeOutput()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !node.isPlaying { node.play() }
            retryAt = nil
            startFailureLogged = false
            return true
        } catch {
            // Once per failure streak (e.g. an interruption that never reports its end).
            if !startFailureLogged { Log.audio.error("audio engine start failed: \(error); retrying every 1 s") }
            startFailureLogged = true
            retryAt = now + .seconds(1)
            return false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("audio session deactivate failed: \(error)")
        }
    }

    private func logStatsIfChanged() {
        let j = jitterSnapshot
        let now = (j.underruns, j.drops + counters.poolDrops, counters.staleDrops, counters.undecodable)
        guard now != lastStats else { return }
        lastStats = now
        Log.audio.info("M6 audio stats: underruns=\(now.0) drops=\(now.1) stale=\(now.2) undecodable=\(now.3) "
                       + "target=\(j.targetFrames / 48)ms queued=\(j.queuedFrames / 48)ms")
    }

    // MARK: notifications

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                            queue: nil) { [weak self] _ in
            guard let self else { return }
            self.setMuted(self.defaults.bool(forKey: Self.mutedDefaultsKey))
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            self?.later { $0.interrupted(type) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Log.audio.info("audio route change (reason \(raw))")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.later { $0.restartAfter("media services reset", sessionLost: true, rebuild: true) }
        })
    }

    private func later(_ work: @escaping @Sendable (AudioPlayer) -> Void) {
        notifications.async { [weak self] in if let self { work(self) } }
    }

    private func makeOutput() -> (AVAudioEngine, AVAudioPlayerNode) {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.later { $0.restartAfter("engine configuration change") }
        })
        output = (engine, node)
        return (engine, node)
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            restartAfter("interruption began", sessionLost: true)
        case .ended:
            // Resume: the next packet restarts the engine (no retry wait).
            control.withLock { retryAt = nil }
            Log.audio.info("audio interruption ended; resuming")
        default:
            break
        }
    }

    /// The engine stopped under us: flush; the next packet restarts it.
    /// `rebuild`: the engine is unusable (media services reset); make a new one.
    private func restartAfter(_ why: String, sessionLost: Bool = false, rebuild: Bool = false) {
        control.lock()
        defer { control.unlock() }
        guard !stopped else { return }
        Log.audio.info("audio \(why); restarting on the next packet")
        resetPlayback()
        output?.engine.stop()
        if rebuild { output = nil }
        if sessionLost { sessionActive = false }
        retryAt = nil
    }

    // MARK: PCM

    static func deinterleave(_ src: UnsafePointer<Float>, frames: Int, into buffer: AVAudioPCMBuffer) {
        let n = min(frames, Int(buffer.frameCapacity))
        guard let ch = buffer.floatChannelData else { return }
        let left = ch[0], right = ch[1]
        for i in 0..<n {
            left[i] = src[2 * i]
            right[i] = src[2 * i + 1]
        }
        buffer.frameLength = AVAudioFrameCount(n)
    }
}
