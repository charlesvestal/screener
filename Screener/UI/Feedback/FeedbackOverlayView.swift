// SwiftUI touch-feedback overlay over the remote screen (FeedbackCenter):
//   - direct-mode long press: a ring filling toward the right-click threshold
//     at the finger (appears after a short delay so plain taps don't flash
//     it; gone at once on a move; a brief completion pop when it fires)
//   - zoom pill: "2.4×" at the top while pinching, fading 1 s after
//   - minimap (top-right, glass) while zoomed: the whole picture with the
//     visible region outlined; tap or drag on it to move the view there
//   - scroll pill: a slim thumb at the right edge during touch scroll and
//     momentum, fading after
// Must share the coordinate space of RemoteScreenView (same frame, safe area
// ignored). Only the minimap takes touches. Reduce Motion: fades only.
import SwiftUI

struct FeedbackOverlayView: View {
    let center: FeedbackCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let lp = center.longPress {
                    LongPressRing(state: lp, reduceMotion: reduceMotion)
                        .id(lp.id)
                        .position(lp.point)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let scale = center.zoomPill {
                    ZoomPill(scale: scale)
                        .position(x: geo.size.width / 2, y: 44)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
                if let pos = center.scrollPill {
                    ScrollPill(position: pos, trackHeight: geo.size.height * 0.3)
                        .position(x: geo.size.width - 8, y: geo.size.height / 2)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let map = center.minimap {
                    let size = MinimapGeometry.size(aspect: map.aspect)
                    MinimapView(map: map, thumbnail: center.thumbnail, size: size) { center.onMinimapJump?($0) }
                        .position(x: geo.size.width - size.width / 2 - 6 - 20, y: size.height / 2 + 6 + 28)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.2), value: center.zoomPill == nil)
        .animation(.easeOut(duration: 0.3), value: center.scrollPill == nil)
        .animation(.easeOut(duration: 0.25), value: center.minimap == nil)
        .animation(.easeOut(duration: 0.12), value: center.longPress?.id)
    }
}

/// A ring filling over the long-press duration.
private struct LongPressRing: View {
    let state: FeedbackCenter.LongPress
    let reduceMotion: Bool
    /// Plain taps end before this: the ring stays invisible for them.
    static let showDelay: TimeInterval = 0.12
    @State private var progress: CGFloat = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: state.fired ? 1 : progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 64, height: 64)
        .shadow(color: .black.opacity(0.35), radius: 3)
        .scaleEffect(state.fired && !reduceMotion ? 1.25 : 1)
        .opacity(state.fired ? 0 : (visible ? 1 : 0))
        .animation(.easeOut(duration: FeedbackCenter.longPressFlash), value: state.fired)
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
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Zoomed region on the remote screen")
    }
}
