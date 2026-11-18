// Picture in Picture for the session (iPadOS 15+ sample-buffer content source).
//
// An AVSampleBufferDisplayLayer, hosted in the session view right behind the
// Metal video (PiPLayerHostView: it must be in a window for PiP to be
// possible, and its frame is where the PiP animation starts), is fed
// composited pictures by PiPFrameFeeder. AVPictureInPictureController shows
// that layer's content in the floating window.
//
// The content is live: the playback time range is infinite (no scrubber,
// "Live"), skip buttons are hidden (`requiresLinearPlayback`), and the
// play/pause button freezes / resumes the PiP picture (the session itself
// keeps running). The app's audio session stays `.playback` while a session
// is up (AudioSessionArbiter) — PiP needs it, and the Mac's audio keeps
// playing in the background with it (UIBackgroundModes: audio).
//
// The session policy lives in SessionCoordinator / LifecyclePolicy: this
// class only reports `willStart` / `didStop(restoring:)`. SessionView wires
// them and decides `autoStart` (Settings → "Picture in Picture when leaving
// the app", and a connected session with a picture).
import AVFoundation
import AVKit
import Observation
import UIKit

@MainActor @Observable
final class PiPController: NSObject {
    /// The layer PiP shows (PiPLayerHostView hosts it).
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    /// PiP is starting or showing.
    private(set) var isActive = false
    /// The system can start PiP now (a layer in a window with a picture).
    private(set) var isPossible = false
    /// PiP exists on this device at all.
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// PiP is about to show (the session must survive the background).
    @ObservationIgnored var onWillStart: (() -> Void)?
    /// PiP went away; `restoring`: the user tapped "return to app".
    @ObservationIgnored var onDidStop: ((_ restoring: Bool) -> Void)?

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var feeder: PiPFrameFeeder?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var autoStart = false
    @ObservationIgnored private var feeding = false
    @ObservationIgnored private var audioClaimed = false
    /// Read by the (nonisolated) playback delegate.
    @ObservationIgnored private let paused = LockedValue(false)

    init(store: VideoFrameStore) {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        let renderer = RendererBox(displayLayer.sampleBufferRenderer)
        feeder = PiPFrameFeeder(store: store) { sample in renderer.enqueue(sample) }
    }

    /// The host view is in a window: PiP can be set up (idempotent).
    func layerDidMoveToWindow() {
        guard controller == nil, isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = autoStart
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] p, _ in
            let possible = p.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        controller = pip
        Log.app.info("pip: controller ready")
    }

    /// A session is up (feed the layer) or not.
    func setFeeding(_ on: Bool) {
        guard on != feeding else { return }
        feeding = on
        claimAudio(on)
        updateRate()
    }

    /// Start PiP automatically when the app leaves the foreground.
    func setAutoStart(_ on: Bool) {
        autoStart = on
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    func start() {
        guard let controller, !controller.isPictureInPictureActive else { return }
        feeder?.refresh()
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func toggle() { isActive ? stop() : start() }

    /// The session view is going away: stop PiP and feeding, release audio.
    func shutdown() {
        stop()
        setAutoStart(false)
        setFeeding(false)
        feeder?.stop()
        possibleObservation = nil
    }

    private func updateRate() {
        let rate: PiPFrameFeeder.Rate = !feeding ? .off : !isActive ? .inline : paused.value ? .frozen : .live
        feeder?.setRate(rate)
    }

    private func claimAudio(_ on: Bool) {
        guard on != audioClaimed else { return }
        audioClaimed = on
        if on {
            AudioSessionArbiter.shared.acquire(.pictureInPicture)
        } else {
            AudioSessionArbiter.shared.release(.pictureInPicture)
        }
    }

    // MARK: delegate hops (AVKit calls these on the main thread)

    fileprivate func willStart() {
        Log.app.info("pip: starting")
        isActive = true
        paused.value = false
        updateRate()
        onWillStart?()
    }

    fileprivate func didStop() {
        let restored = restoring
        restoring = false
        Log.app.info("pip: stopped (\(restored ? "restoring the app" : "closed"))")
        isActive = false
        paused.value = false
        updateRate()
        onDidStop?(restored)
    }

    fileprivate func failedToStart(_ error: Error) {
        Log.app.error("pip: failed to start: \(error.localizedDescription)")
        isActive = false
        updateRate()
        onDidStop?(false)
    }

    fileprivate func restore() { restoring = true }

    fileprivate func setPlaying(_ playing: Bool) {
        paused.value = !playing
        updateRate()
        controller?.invalidatePlaybackState()
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { willStart() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { didStop() }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { failedToStart(error) }
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The session view is still up underneath: nothing to rebuild.
        MainActor.assumeIsolated { restore() }
        completionHandler(true)
    }
}

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { setPlaying(playing) }
    }

    /// Live content: no scrubber, no time.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        paused.value
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// The Mac's audio keeps playing while PiP shows.
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ c: AVPictureInPictureController) -> Bool { false }
}

/// The display layer's renderer, used from the feeder's queue
/// (AVQueuedSampleBufferRendering is safe to call from any thread).
private final class RendererBox: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    init(_ r: AVSampleBufferVideoRenderer) { renderer = r }

    func enqueue(_ sample: CMSampleBuffer) {
        // A failed renderer (e.g. media services reset) shows nothing until flushed.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

/// Hosts the PiP display layer, filling the session view behind the video.
final class PiPLayerHostView: UIView {
    var controller: PiPController? {
        didSet {
            oldValue?.displayLayer.removeFromSuperlayer()
            if let controller {
                layer.addSublayer(controller.displayLayer)
                setNeedsLayout()
                if window != nil { controller.layerDidMoveToWindow() }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller?.displayLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.layerDidMoveToWindow() }
    }
}
