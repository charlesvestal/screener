// The gesture coach's glass overlay: a swipeable deck of CoachCard, one
// "Got it" to dismiss. Shown over the live session (SessionView) or, from
// the Help screen, on its own.
import SwiftUI

/// Full-screen dismissible overlay with the gesture cards for the touch mode
/// currently selected. Tap "Got it", or anywhere outside a card, to dismiss.
struct GestureCoachOverlay: View {
    var onDismiss: () -> Void
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var touchMode: TouchInputMode { TouchInputMode(rawValue: touchModeRaw) ?? .default }
    private var cards: [CoachCard] { GestureCoach.cards(for: touchMode) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 20) {
                Text("Gestures — \(touchMode.title) Mode")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 28)
                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        CoachCardView(card: card, reduceMotion: reduceMotion)
                            .tag(index)
                            .padding(.horizontal, 36)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: 320)
                Button("Got it") { onDismiss() }
                    .buttonStyle(.glassProminent)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: 520)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }
}

/// One gesture card: an animated icon over its title and instruction.
private struct CoachCardView: View {
    let card: CoachCard
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 18) {
            CoachIconView(kind: card.kind, systemImage: card.systemImage, reduceMotion: reduceMotion)
                .frame(height: 96)
            Text(card.title).font(.title3.bold())
            Text(card.subtitle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .menuGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The animated glyph for a CoachAnimationKind. Each loops gently while
/// visible; under Reduce Motion every case renders a single static frame.
private struct CoachIconView: View {
    let kind: CoachAnimationKind
    let systemImage: String
    let reduceMotion: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            switch kind {
            case .moveTrackpad, .moveDirect:
                base
                    .offset(x: animated ? (phase ? 14 : -14) : 0)
            case .tap, .twoFingerTap:
                ZStack {
                    pulseRing
                    base
                }
            case .drag:
                ZStack {
                    pulseRing
                    base.offset(x: animated ? (phase ? 18 : -18) : 0)
                }
            case .longPress:
                ZStack {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 70, height: 70)
                        .opacity(animated ? (phase ? 1 : 0.25) : 0.6)
                    base
                }
            case .scroll:
                base.offset(y: animated ? (phase ? 16 : -16) : 0)
            case .pinch:
                HStack(spacing: animated ? (phase ? 44 : 20) : 32) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 28))
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 28)).scaleEffect(x: -1, y: 1)
                }
                .foregroundStyle(.tint)
            case .shake:
                base.rotationEffect(.degrees(animated ? (phase ? 10 : -10) : 0))
            case .menu:
                base
            }
        }
        .font(.system(size: 48, weight: .semibold))
        .foregroundStyle(.tint)
        .onAppear { startIfNeeded() }
    }

    private var base: some View {
        Image(systemName: systemImage)
    }

    private var pulseRing: some View {
        Circle()
            .stroke(Color.accentColor, lineWidth: 3)
            .frame(width: animated ? (phase ? 76 : 44) : 60, height: animated ? (phase ? 76 : 44) : 60)
            .opacity(animated ? (phase ? 0 : 0.8) : 0.5)
    }

    private var animated: Bool { !reduceMotion }

    private func startIfNeeded() {
        guard animated else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            phase = true
        }
    }
}

#if DEBUG
#Preview("Trackpad") {
    GestureCoachOverlay(onDismiss: {})
}
#endif
