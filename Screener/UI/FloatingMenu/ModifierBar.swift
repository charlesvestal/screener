import SwiftUI

/// How a sticky modifier glows, everywhere it is shown (the menu's
/// ModifierBar, the pill's badges; KeyboardAccessoryBar mirrors it in UIKit):
/// latched = tinted with a soft glow, locked = solid with an underline and a
/// tighter glow.
enum ModifierGlow {
    static func radius(_ level: StickyLevel) -> CGFloat {
        switch level {
        case .off: 0
        case .latched: 7
        case .locked: 4
        }
    }

    static func opacity(_ level: StickyLevel) -> Double {
        switch level {
        case .off: 0
        case .latched: 0.75
        case .locked: 0.55
        }
    }

    static func accessibilityValue(_ level: StickyLevel) -> String {
        switch level {
        case .off: "Off"
        case .latched: "Latched for the next key"
        case .locked: "Locked"
        }
    }
}

/// ⌘ ⌥ ⌃ ⇧ fn sticky toggles. Tap: latch for one key or click; double-tap:
/// lock; tap again: off.
struct ModifierBar: View {
    let menu: ControlMenuModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(StickyModifier.displayOrder, id: \.self) { m in
                ModifierKey(modifier: m, level: menu.modifiers.state[m]) { menu.tapModifier(m) }
            }
        }
    }
}

private struct ModifierKey: View {
    let modifier: StickyModifier
    let level: StickyLevel
    let tap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Text(modifier.symbol)
                    .font(.system(size: modifier == .fn ? 15 : 19, weight: .semibold, design: .rounded))
                // Latched: a dot; locked: an underline bar.
                Capsule()
                    .frame(width: level == .locked ? 18 : 5, height: level == .locked ? 2.5 : 5)
                    .opacity(level == .off ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(level == .off ? Color.primary : Color.white)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.accentColor.opacity(ModifierGlow.opacity(level)), radius: ModifierGlow.radius(level))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: level)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(modifier.name)
        .accessibilityValue(ModifierGlow.accessibilityValue(level))
        .accessibilityHint("Tap to apply to the next key or click. Double-tap quickly to lock.")
        .accessibilityAddTraits(level == .off ? [] : .isSelected)
    }

    private var background: Color {
        switch level {
        case .off: Color.primary.opacity(0.08)
        case .latched: Color.accentColor.opacity(0.7)
        case .locked: Color.accentColor
        }
    }
}

/// Latched/locked modifier badges for the collapsed pill, glowing like the
/// keys they stand for.
struct ModifierBadges: View {
    let state: ModifierState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StickyModifier.displayOrder.filter { state[$0] != .off }, id: \.self) { m in
                badge(m, level: state[m])
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: state)
    }

    private func badge(_ m: StickyModifier, level: StickyLevel) -> some View {
        let locked = level == .locked
        return Text(m.symbol)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.top, 2)
            .padding(.bottom, locked ? 1 : 2)
            .overlay(alignment: .bottom) {
                if locked {
                    Capsule().fill(Color.white).frame(height: 1.5).padding(.horizontal, 4).padding(.bottom, 1)
                }
            }
            .foregroundStyle(locked ? Color.white : Color.accentColor)
            .background(locked ? Color.accentColor : Color.accentColor.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: Color.accentColor.opacity(ModifierGlow.opacity(level)), radius: ModifierGlow.radius(level) * 0.8)
    }

    static func accessibilityText(_ state: ModifierState) -> String {
        let parts = StickyModifier.displayOrder.compactMap { m -> String? in
            switch state[m] {
            case .off: nil
            case .latched: "\(m.name) latched"
            case .locked: "\(m.name) locked"
            }
        }
        return parts.joined(separator: ", ")
    }
}
