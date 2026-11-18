// How far the remote cursor moves for relative input (pure; RemoteInputView
// applies it).
//
// Hardware mouse / trackpad under pointer lock (GCMouse deltas, raw counts):
// macOS at its default tracking speed moves the pointer about one POINT per
// count, with gentle acceleration. So a count moves the cursor
//   pointScale (host backing px per Mac point, 2 on Retina) × gain × speed
// host backing pixels — the same Mac points per count as on the Mac itself —
// divided by the zoom (zoomed in, the cursor keeps its on-screen pace, as a
// finger's does). `viewDelta` turns that into the view points
// RemoteInputView.moveCursor(by:) takes (it multiplies by host px per view
// point at the current zoom). On a 1366-pt-wide iPad showing a 1440-pt Mac
// a count is ≈ 0.95 iPad points: the iPad's own pointer pace.
// Gain: 1 up to `slowSpeed` counts/s, easing (smoothstep) to `maxGain` (1.6×)
// at `fastSpeed` — gentler than the touch curve (TrackpadAcceleration, up to
// 2.5×), which made a hardware pointer feel twitchy.
//
// Speeds (Settings → Input, 0.25×–3×, default 1×): "Pointer Speed" scales the
// hardware path, "Touch Pointer Speed" scales trackpad-mode finger moves
// (after TrackpadAcceleration). Without pointer lock the iPad's own pointer
// (and its Settings → Trackpad / Mouse speed) positions the cursor directly.
import CoreGraphics
import Foundation

enum PointerScaling {
    static let speedRange: ClosedRange<Double> = 0.25...3.0
    static let defaultSpeed = 1.0
    static let pointerSpeedKey = "input.pointerSpeed"
    static let touchPointerSpeedKey = "input.touchPointerSpeed"

    /// Mac points per GCMouse count at 1× (macOS default tracking).
    static let macPointsPerCount: CGFloat = 1
    static let slowSpeed: CGFloat = 300       // counts/s
    static let fastSpeed: CGFloat = 3000
    static let maxGain: CGFloat = 1.6

    /// Hardware acceleration at `speed` counts/s (1 … maxGain).
    static func hardwareGain(speed: CGFloat) -> CGFloat {
        guard speed.isFinite, speed > slowSpeed else { return 1 }
        let t = min(1, (speed - slowSpeed) / (fastSpeed - slowSpeed))
        return 1 + (maxGain - 1) * t * t * (3 - 2 * t)
    }

    /// Host backing pixels a GCMouse delta of `counts` over `dt` seconds
    /// moves the cursor (before the zoom).
    static func hardwareHostPixels(_ counts: CGPoint, dt: TimeInterval, speed: Double,
                                   hostPointScale: CGFloat) -> CGPoint {
        let v = dt > 0 ? hypot(counts.x, counts.y) / CGFloat(dt) : 0
        let k = macPointsPerCount * max(hostPointScale, 1) * hardwareGain(speed: v) * CGFloat(clamp(speed))
        return CGPoint(x: counts.x * k, y: counts.y * k)
    }

    /// The view-point delta for moveCursor(by:) that moves the cursor
    /// `hardwareHostPixels / zoom`: `hostPixelsPerViewPoint` is the
    /// unzoomed InputController.hostPixelsPerPoint (moveCursor divides by
    /// the zoom itself).
    static func viewDelta(counts: CGPoint, dt: TimeInterval, speed: Double, hostPointScale: CGFloat,
                          hostPixelsPerViewPoint: CGFloat) -> CGPoint {
        let px = hardwareHostPixels(counts, dt: dt, speed: speed, hostPointScale: hostPointScale)
        let k = hostPixelsPerViewPoint > 0 ? hostPixelsPerViewPoint : 1
        return CGPoint(x: px.x / k, y: px.y / k)
    }

    /// A trackpad-mode finger move (already TrackpadAcceleration'd) at `speed`.
    static func touchDelta(_ d: CGPoint, speed: Double) -> CGPoint {
        let s = CGFloat(clamp(speed))
        return CGPoint(x: d.x * s, y: d.y * s)
    }

    static func clamp(_ speed: Double) -> Double {
        speed.isFinite ? min(speedRange.upperBound, max(speedRange.lowerBound, speed)) : defaultSpeed
    }
}
