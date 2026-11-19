// SwiftUI touch-feedback overlay over the remote screen (FeedbackCenter):
//   - touch-and-hold: a ring filling toward the hold-drag threshold at the
//     fingers (Touch mode) or the cursor (Trackpad mode), tinted by the
//     drag's button — blue left, red right, green middle (DragIndicatorTint).
//     It appears after a short delay so plain taps don't flash it, is gone
//     at once on a move, and pops briefly when it fires (no pop under
//     Reduce Motion); the drag pulse then marks the armed drag.
//   - zoom pill: "2.4×" at the top while pinching, fading 1 s after
//   - minimap (top-right, glass) while zoomed: the whole picture with the
//     visible region outlined; tap or drag on it to move the view there. It
//     fades out `FeedbackCenter.minimapLinger` after the view last moved,
//     even while still zoomed; the next zoom / pan brings it back
//   - scroll pill: a slim thumb at the right edge during touch scroll and
//     momentum, fading after
// Must share the coordinate space of RemoteScreenView (same frame, safe area
// ignored), so the proxy here reports no safe area: SessionView measures it
// and passes `safeArea` in, and the HUD keeps clear of it on iPhone (Dynamic
// Island / notch / rounded corners / home indicator: FeedbackHUDLayout).
// Only the minimap takes touches. Reduce Motion: fades only.
import SwiftUI

/// Where the HUD pieces sit in the full-screen overlay (pure; AdaptiveLayoutTests).
/// `insets` are what to keep clear of (`hudInsets`): the safe area on iPhone,
/// none on iPad / Mac, where the layout is unchanged.
enum FeedbackHUDLayout {
    /// The zoom pill's centre from the top on iPad (and the floor on iPhone).
    static let zoomPillY: CGFloat = 44
    /// The minimap's distance from the top / trailing edges on iPad (floors on iPhone).
    static let minimapTop: CGFloat = 28
    static let minimapTrailing: CGFloat = 20
    /// The glass rim around the minimap's picture.
    static let minimapRim: CGFloat = 6
    /// The scroll pill's centre from the trailing edge on iPad (floor on iPhone).
    static let scrollPillTrailing: CGFloat = 8
    /// Gap kept beyond the safe-area edge on iPhone.
    static let gap: CGFloat = 8

    /// What the HUD keeps clear of on `platform` given the window's safe area.
    static func hudInsets(platform: AdaptiveLayout.Platform, safeArea: EdgeInsets) -> EdgeInsets {
        platform == .phone ? safeArea : EdgeInsets()
    }

    /// Top centre, below the Dynamic Island / notch in portrait; centred
    /// between the side insets in landscape.
    static func zoomPillCenter(in size: CGSize, insets: EdgeInsets) -> CGPoint {
        let x = insets.leading + (size.width - insets.leading - insets.trailing) / 2
        let y = max(zoomPillY, insets.top + 26)
        return CGPoint(x: x, y: y)
    }

    /// Top trailing corner, clear of the island (portrait: below it;
    /// landscape: inside the side inset) and the rounded corner.
    static func minimapCenter(size map: CGSize, in size: CGSize, insets: EdgeInsets) -> CGPoint {
        let top = max(minimapTop, insets.top + gap)
        let trailing = max(minimapTrailing, insets.trailing + gap)
        return CGPoint(x: size.width - trailing - minimapRim - map.width / 2,
                       y: top + minimapRim + map.height / 2)
    }

    /// The trailing edge, vertically centred: in landscape that is where the
    /// Dynamic Island sits, so it moves inside the side inset.
    static func scrollPillCenter(in size: CGSize, insets: EdgeInsets) -> CGPoint {
        let trailing = max(scrollPillTrailing, insets.trailing + gap)
        let midY = insets.top + (size.height - insets.top - insets.bottom) / 2
        return CGPoint(x: size.width - trailing, y: midY)
    }
}

struct FeedbackOverlayView: View {
    let center: FeedbackCenter
    /// The window's safe area (this overlay ignores it; SessionView measures it).
    var safeArea = EdgeInsets()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var insets: EdgeInsets { FeedbackHUDLayout.hudInsets(platform: .current, safeArea: safeArea) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let lp = center.hold {
                    HoldRing(state: lp, reduceMotion: reduceMotion)
                        .id(lp.id)
                        .position(lp.point)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let scale = center.zoomPill {
                    ZoomPill(scale: scale)
                        .position(FeedbackHUDLayout.zoomPillCenter(in: geo.size, insets: insets))
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
                if let pos = center.scrollPill {
                    ScrollPill(position: pos, trackHeight: geo.size.height * 0.3)
                        .position(FeedbackHUDLayout.scrollPillCenter(in: geo.size, insets: insets))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let map = center.minimap {
                    let size = MinimapGeometry.size(aspect: map.aspect)
                    MinimapView(map: map, thumbnail: center.thumbnail, size: size) {
                        center.wakeMinimap()
                        center.onMinimapJump?($0)
                    }
                    .position(FeedbackHUDLayout.minimapCenter(size: size, in: geo.size, insets: insets))
                    .opacity(center.minimapShown ? 1 : 0)
                    .allowsHitTesting(center.minimapShown)
                    .accessibilityHidden(!center.minimapShown)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.2), value: center.zoomPill == nil)
        .animation(.easeOut(duration: 0.3), value: center.scrollPill == nil)
        .animation(.easeOut(duration: 0.25), value: center.minimap == nil)
        .animation(.easeInOut(duration: 0.4), value: center.minimapShown)
        .animation(.easeOut(duration: 0.12), value: center.hold?.id)
    }
}

/// A ring filling over the hold duration, tinted by the drag's button.
private struct HoldRing: View {
    let state: FeedbackCenter.Hold
    let reduceMotion: Bool
    /// Plain taps end before this: the ring stays invisible for them.
    static let showDelay: TimeInterval = 0.12
    @State private var progress: CGFloat = 0
    @State private var visible = false

    private var tint: Color {
        let c = DragIndicatorTint.rgb(for: state.button)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: 4)
            Circle()
                .trim(from: 0, to: state.fired ? 1 : progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 64, height: 64)
        .shadow(color: .black.opacity(0.35), radius: 3)
        .scaleEffect(state.fired && !reduceMotion ? 1.25 : 1)
        .opacity(state.fired ? 0 : (visible ? 1 : 0))
        .animation(.easeOut(duration: FeedbackCenter.holdFlash), value: state.fired)
        .onAppear {
            let delay = Self.showDelay
            withAnimation(.easeIn(duration: 0.08).delay(delay)) { visible = true }
            withAnimation(.linear(duration: max(0.05, state.duration - delay)).delay(delay)) { progress = 1 }
        }
    }
}

private struct ZoomPill: View {
    let scale: CGFloat

    var body: some View {
        Text(String(format: "%.1f×", scale))
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .accessibilityLabel(String(format: "Zoom %.1f times", scale))
    }
}

private struct ScrollPill: View {
    let position: CGFloat
    let trackHeight: CGFloat
    static let thumb: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.75))
            .frame(width: 5, height: Self.thumb)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .offset(y: (position - 0.5) * max(0, trackHeight - Self.thumb))
            .frame(width: 5, height: trackHeight)
    }
}

private struct MinimapView: View {
    let map: FeedbackCenter.Minimap
    let thumbnail: CGImage?
    let size: CGSize
    let jump: (CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().interpolation(.medium)
                } else {
                    Color.black.opacity(0.4)
                }
            }
            .frame(width: size.width, height: size.height)
            let r = map.viewport
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.12))
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: max(6, r.width * size.width), height: max(6, r.height * size.height))
                .offset(x: r.minX * size.width, y: r.minY * size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            jump(MinimapGeometry.contentPoint(v.location, minimapSize: size))
        })
        .padding(FeedbackHUDLayout.minimapRim)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Zoomed region on the remote screen")
    }
}
