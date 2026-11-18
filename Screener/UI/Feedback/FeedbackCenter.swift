// The session's touch-feedback hub: a FeedbackSink that turns FeedbackEvents
// into
//   - GPU effect state (RippleField, CursorEffects) the MetalRenderer samples
//     every frame (`gpuState(at:)`), asking for frames while anything moves
//     (`needsFrames(at:)`) and through `onChange` when an event arrives;
//   - observable overlay state for FeedbackOverlayView: the direct-mode
//     long-press ring, the zoom pill, the scroll pill and the minimap.
// Settings and Reduce Motion: FeedbackEvent.swift header. Both are read when
// an event arrives (no per-frame defaults reads).
import CoreGraphics
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class FeedbackCenter: FeedbackSink {
    /// The zoom pill stays this long after the last zoom change.
    static let zoomPillLinger: TimeInterval = 1
    /// The scroll pill fades this long after the last scroll step.
    static let scrollPillLinger: TimeInterval = 0.6
    /// The long-press ring lingers this long after firing (completion flash).
    static let longPressFlash: TimeInterval = 0.25

    struct LongPress: Equatable {
        var id: Int
        /// SCREEN point.
        var point: CGPoint
        var duration: TimeInterval
        var fired = false
    }

    struct Minimap: Equatable {
        /// The picture's width / height.
        var aspect: CGFloat
        /// The visible region in unit content coordinates.
        var viewport: CGRect
    }

    /// What the renderer draws on top of / into the picture at an instant.
    struct GPUState {
        var ripples: [RippleSample] = []
        /// The cursor sprite's scale: the halo or a locate (CursorEffects.cursorScale).
        var haloScale: CGFloat = 1
        /// 0…1 strength of the soft glow under the cursor.
        var haloGlow: CGFloat = 0
        var ghosts: [(point: CGPoint, alpha: Float)] = []

        var isEmpty: Bool { ripples.isEmpty && haloGlow <= 0 && haloScale == 1 && ghosts.isEmpty }
    }

    // MARK: overlay state (observed)

    private(set) var longPress: LongPress?
    /// The zoom pill's scale (nil: hidden).
    private(set) var zoomPill: CGFloat?
    /// The scroll pill's thumb position 0…1 (nil: hidden).
    private(set) var scrollPill: CGFloat?
    /// Shown while zoomed (set by the renderer).
    private(set) var minimap: Minimap?
    /// A downscaled picture for the minimap (renderer, ≤ 4 Hz).
    private(set) var thumbnail: CGImage?

    // MARK: GPU state (not observed)

    @ObservationIgnored private(set) var ripples = RippleField()
    @ObservationIgnored private(set) var cursorFX = CursorEffects()
    /// Bumped on every effect change (the renderer redraws when it moves).
    @ObservationIgnored private(set) var revision = 0
    /// The renderer's redraw request.
    @ObservationIgnored var onChange: (() -> Void)?
    /// A tap / drag on the minimap: jump the viewport to this unit content point.
    @ObservationIgnored var onMinimapJump: ((CGPoint) -> Void)?

    // MARK: injected (tests)

    @ObservationIgnored var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    @ObservationIgnored var visualEnabled: () -> Bool = { FeedbackSettings.visualEnabled() }
    @ObservationIgnored private let schedule: KeyRepeater.Schedule

    @ObservationIgnored private var longPressIDs = 0
    @ObservationIgnored private var scrollTravel: CGFloat = 0
    @ObservationIgnored private var lastZoomAt: Double = 0
    @ObservationIgnored private var lastScrollAt: Double = 0
    @ObservationIgnored private var zoomTimer: (() -> Void)?
    @ObservationIgnored private var scrollTimer: (() -> Void)?
    @ObservationIgnored private var longPressTimer: (() -> Void)?

    init(schedule: @escaping KeyRepeater.Schedule = KeyRepeater.runLoopTimer) {
        self.schedule = schedule
    }

    // MARK: FeedbackSink

    func feedback(_ event: FeedbackEvent) {
        let t = now()
        let visual = visualEnabled(), reduced = reduceMotion()
        if !visual, !ripples.isEmpty || cursorFX.hasDecorations {
            ripples.removeAll()
            cursorFX.removeDecorations()
            changed()
        }
        switch event {
        case .click(let p): spawn(.click, p, t, visual, reduced)
        case .doubleClick(let p): spawn(.doubleClick, p, t, visual, reduced)
        case .rightClick(let p): spawn(.rightClick, p, t, visual, reduced)
        case .dragBegan(let p):
            guard visual else { return }
            ripples.setPulse(at: p, now: t, reduceMotion: reduced)
            changed()
        case .dragEnded:
            guard ripples.pulse != nil else { return }
            ripples.setPulse(at: nil, now: t, reduceMotion: reduced)
            changed()
        case .dragLock(let active, let p):
            guard visual || !active else { return }
            ripples.setPulse(at: active ? p : nil, now: t, reduceMotion: reduced)
            changed()
        case .fingerDown:
            guard visual else { return }
            cursorFX.halo(now: t, reduceMotion: reduced)
            changed()
        case .cursorMoved(let p):
            guard visual else { return }
            let ghosts = cursorFX.ghosts
            cursorFX.moved(to: p, now: t, reduceMotion: reduced)
            // Redraw only for the trail / pulse (a cursor move redraws anyway).
            if ripples.pulse != nil { ripples.movePulse(to: p) } else if cursorFX.ghosts == ghosts { return }
            changed()
        case .longPressBegan(let p, let duration):
            longPressTimer?()
            longPressIDs += 1
            longPress = LongPress(id: longPressIDs, point: p, duration: duration)
        case .longPressEnded(let fired):
            longPressTimer?()
            longPressTimer = nil
            guard fired, longPress != nil else { longPress = nil; return }
            longPress?.fired = true
            longPressTimer = schedule(Self.longPressFlash) { [weak self] in
                self?.longPress = nil
                self?.longPressTimer = nil
            }
        case .zoomChanged(let scale):
            zoomPill = scale
            lastZoomAt = t
            if zoomTimer == nil { armZoomTimer(Self.zoomPillLinger) }
        case .scrolled(let dy):
            guard visual else { return }
            if scrollPill == nil { scrollTravel = 0 }
            scrollTravel -= dy
            scrollPill = 0.5 + 0.45 * tanh(scrollTravel / 600)
            lastScrollAt = t
            if scrollTimer == nil { armScrollTimer(Self.scrollPillLinger) }
        case .scrollEnded:
            break               // the pill fades scrollPillLinger after the last step
        case .locateCursor(let hold):
            cursorFX.locate(now: t, hold: hold, reduceMotion: reduced)    // functional: not gated on `visual`
            changed()
        }
    }

    private func spawn(_ v: RippleVariant, _ p: CGPoint, _ t: Double, _ visual: Bool, _ reduced: Bool) {
        guard visual else { return }
        ripples.prune(at: t)
        ripples.spawn(v, at: p, now: t, reduceMotion: reduced)
        changed()
    }

    private func changed() {
        revision += 1
        onChange?()
    }

    /// Hides the zoom pill `zoomPillLinger` after the last change.
    private func armZoomTimer(_ delay: TimeInterval) {
        zoomTimer = schedule(delay) { [weak self] in
            guard let self else { return }
            self.zoomTimer = nil
            let left = Self.zoomPillLinger - (self.now() - self.lastZoomAt)
            if left > 0.01 { self.armZoomTimer(left) } else { self.zoomPill = nil }
        }
    }

    private func armScrollTimer(_ delay: TimeInterval) {
        scrollTimer = schedule(delay) { [weak self] in
            guard let self else { return }
            self.scrollTimer = nil
            let left = Self.scrollPillLinger - (self.now() - self.lastScrollAt)
            if left > 0.01 { self.armScrollTimer(left) } else { self.scrollPill = nil }
        }
    }

    // MARK: renderer

    /// The effects at `now` (finished ones are dropped).
    func gpuState(at now: Double) -> GPUState {
        ripples.prune(at: now)
        cursorFX.prune(at: now)
        guard !ripples.isEmpty || cursorFX != CursorEffects() else { return GPUState() }
        let env = cursorFX.haloEnvelope(at: now)
        return GPUState(ripples: ripples.samples(at: now), haloScale: cursorFX.cursorScale(at: now),
                        haloGlow: env, ghosts: cursorFX.visibleGhosts(at: now))
    }

    /// Whether frames must keep coming at `now` (something animates).
    func needsFrames(at now: Double) -> Bool {
        ripples.isAnimating(at: now) || cursorFX.isAnimating(at: now)
    }

    /// Minimap state from the renderer (nil: not zoomed). Assigned only on
    /// a change, so SwiftUI isn't invalidated every frame.
    func setMinimap(_ m: Minimap?) {
        if m != minimap { minimap = m }
        if m == nil, thumbnail != nil { thumbnail = nil }
    }

    func setThumbnail(_ image: CGImage?) {
        guard minimap != nil else { return }
        thumbnail = image
    }
}
