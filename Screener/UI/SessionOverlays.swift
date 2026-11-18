import SwiftUI

/// What sits between the video and the floating menu while the picture
/// isn't live (never hit-testable; the menu's Disconnect stays reachable):
///   * before the first picture: black, with the connection stage
///     ("Starting video…" once the session view is up);
///   * the first picture fades in from a blur (a dark material veil over the
///     live video, fading out over 0.4 s);
///   * reconnecting: the previous session's last picture, desaturated and
///     blurred, behind a Liquid Glass "Reconnecting…" pill; when the resumed
///     session's first picture arrives it snaps back to colour and fades away.
/// With reduced motion or `feedback.visual` off these become plain cross-fades.
struct SessionStatusOverlay: View {
    let model: SessionCoordinator
    @AppStorage("feedback.visual") private var visualFeedback = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var veil = 1.0
    @State private var backdrop: UIImage?
    @State private var backdropInColor = false

    private var animated: Bool { visualFeedback && !reduceMotion }

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.hasFirstFrame ? 0 : 1)
                .animation(animated ? nil : .easeOut(duration: 0.25), value: model.hasFirstFrame)
            if animated {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(veil)
            }
            if let backdrop {
                Color.black.overlay {
                    Image(uiImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .saturation(backdropInColor ? 1 : 0)
                        .blur(radius: backdropInColor ? 0 : 20)
                        .opacity(backdropInColor ? 1 : 0.7)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .overlay {
            Group {
                if model.isReconnecting {
                    reconnectingPill
                } else if !model.hasFirstFrame {
                    ConnectionStageIndicator(stage: model.stage == .idle ? .startingVideo : model.stage)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 28).padding(.vertical, 18)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: model.isReconnecting)
            .animation(.easeInOut(duration: 0.25), value: model.hasFirstFrame)
        }
        .allowsHitTesting(false)
        .onChange(of: model.hasFirstFrame, initial: true) { _, has in
            if has {
                withAnimation(.easeOut(duration: 0.4)) { veil = 0 }
            } else {
                veil = 1
            }
        }
        .onChange(of: model.isReconnecting, initial: true) { _, reconnecting in
            if reconnecting {
                backdropInColor = false
                backdrop = model.lastPicture?.image
            } else if backdrop != nil {
                if animated {
                    withAnimation(.easeOut(duration: 0.35)) { backdropInColor = true } completion: {
                        withAnimation(.easeOut(duration: 0.25)) { backdrop = nil }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { backdrop = nil }
                }
            }
        }
        // The picture of the session that was just closed is rendered off
        // the main thread, so it may land after "Reconnecting…" went up.
        .onChange(of: model.lastPicture?.serial) { _, _ in
            if model.isReconnecting, let image = model.lastPicture?.image {
                withAnimation(.easeIn(duration: 0.2)) { backdrop = image }
            }
        }
    }

    private var reconnectingPill: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconnecting…").font(.headline)
                if model.stage != .idle, model.stage != .live {
                    Text(model.stage.title).font(.caption).foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: model.stage)
    }
}
