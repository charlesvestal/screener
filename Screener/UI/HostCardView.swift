import SwiftUI
import UIKit

/// One Mac in the host grid: the last picture of its screen (or a
/// placeholder), its model icon, name and address, a reachability dot, and
/// the connection stages while connecting to it.
struct HostCard: View {
    let name: String
    let address: String
    let detail: String
    var symbol: String = MacModelSymbol.generic
    var family: String?
    let reachability: HostReachability
    var thumbnail: UIImage?
    /// Set while this card's Mac is connecting.
    var stage: ConnectionStage?

    static let cornerRadius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .overlay(alignment: .topTrailing) { OnlineDot(reachability: reachability).padding(10) }
                .overlay {
                    if let stage {
                        ConnectionStageIndicator(stage: stage, compact: true)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .animation(.smooth(duration: 0.3), value: stage)
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .accessibilityLabel(family ?? "Mac")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(stage?.title ?? reachability.accessibilityLabel)
    }

    @ViewBuilder private var preview: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .accessibilityHidden(true)
                } else {
                    HostPlaceholder(symbol: symbol)
                }
            }
            .clipped()
    }
}

/// The card preview of a Mac with no thumbnail yet.
struct HostPlaceholder: View {
    let symbol: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(.tint.opacity(0.75))
        }
        .accessibilityHidden(true)
    }
}

/// Green and gently pulsing while the Mac is advertised on Bonjour, grey otherwise.
struct OnlineDot: View {
    let reachability: HostReachability
    @AppStorage("feedback.visual") private var visualFeedback = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reachability.isOnline && visualFeedback && !reduceMotion {
                Circle()
                    .fill(.green)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 2.4 : 1).opacity(expanded ? 0 : 0.6)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.8) : nil
                    }
            }
            Circle().fill(reachability.isOnline ? Color.green : Color.gray)
        }
        .frame(width: 9, height: 9)
        .padding(6)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel(reachability.accessibilityLabel)
    }
}

/// "Signing in…" / "Securing…" / "Starting video…" over three step bars.
struct ConnectionStageIndicator: View {
    let stage: ConnectionStage
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            Text(stage.title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .contentTransition(.opacity)
            HStack(spacing: 6) {
                ForEach(ConnectionStage.steps, id: \.self) { step in
                    bar(step)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.title)
        .accessibilityValue(stage.stepIndex.map { "Step \($0 + 1) of \(ConnectionStage.steps.count)" } ?? "")
    }

    @ViewBuilder private func bar(_ step: ConnectionStage) -> some View {
        let shape = Capsule()
        let size = CGSize(width: compact ? 20 : 30, height: compact ? 4 : 5)
        if step < stage {
            shape.fill(.tint).frame(width: size.width, height: size.height)
        } else if step == stage && !reduceMotion {
            shape.fill(.tint)
                .frame(width: size.width, height: size.height)
                .phaseAnimator([1.0, 0.35]) { bar, o in bar.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
        } else if step == stage {
            shape.fill(.tint).frame(width: size.width, height: size.height)
        } else {
            shape.fill(.secondary.opacity(0.35)).frame(width: size.width, height: size.height)
        }
    }
}

/// The host list with no Macs saved or found yet.
struct HostsEmptyState: View {
    var onAdd: () -> Void
    @AppStorage("feedback.visual") private var visualFeedback = true
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 28) {
            illustration
            VStack(spacing: 8) {
                Text("Connect to Your Mac").font(.title2.bold())
                Text("Macs with Screen Sharing turned on appear here automatically.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 18) {
                step(1, "On your Mac, open **System Settings › General › Sharing** and turn on **Screen Sharing**.")
                step(2, "Keep this iPad on the same network as the Mac. It shows up here on its own.")
                step(3, "Tap the Mac and sign in with your **Mac user name and password**.")
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Button(action: onAdd) {
                Label("Add a Mac by Address", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            Button("Need Help?") { showHelp = true }
                .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showHelp) { HelpView() }
    }

    private var illustration: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.10)).frame(width: 200, height: 200)
            Circle().fill(Color.accentColor.opacity(0.08)).frame(width: 140, height: 140)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 78, weight: .thin))
                .foregroundStyle(.tint)
                .offset(x: -22, y: -10)
            Image(systemName: "ipad.landscape")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(Circle().fill(.background))
                .offset(x: 52, y: 42)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: visualFeedback)
                .offset(x: 34, y: -46)
        }
        .frame(height: 210)
        .accessibilityHidden(true)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(n)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
