import SwiftUI

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

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 1) {
                Text(modifier.symbol)
                    .font(.system(size: modifier == .fn ? 15 : 19, weight: .semibold, design: .rounded))
                Image(systemName: level == .locked ? "lock.fill" : "circle.fill")
                    .font(.system(size: 7))
                    .opacity(level == .off ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(level == .off ? Color.primary : Color.white)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(modifier.name)
        .accessibilityValue(levelText)
        .accessibilityHint("Tap to apply to the next key or click. Double-tap quickly to lock.")
        .accessibilityAddTraits(level == .off ? [] : .isSelected)
    }

    private var background: Color {
        switch level {
        case .off: Color.primary.opacity(0.08)
        case .latched: Color.accentColor.opacity(0.75)
        case .locked: Color.accentColor
        }
    }

    private var levelText: String {
        switch level {
        case .off: "Off"
        case .latched: "Latched for the next key"
        case .locked: "Locked"
        }
    }
}

/// Latched/locked modifier badges for the collapsed pill.
struct ModifierBadges: View {
    let state: ModifierState

    var body: some View {
        HStack(spacing: 3) {
            ForEach(StickyModifier.displayOrder.filter { state[$0] != .off }, id: \.self) { m in
                Text(m.symbol)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(state[m] == .locked ? Color.white : Color.accentColor)
                    .background(state[m] == .locked ? Color.accentColor : Color.accentColor.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
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
