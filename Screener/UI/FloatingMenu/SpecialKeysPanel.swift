import SwiftUI

/// Esc, Tab, Delete/forward Delete, arrows, Home/End/PgUp/PgDn and (behind
/// the fn-row toggle) F1–F12. Keys go down on touch and up on release, and
/// repeat while held (ControlMenuModel → KeyRepeater). With fn active the
/// labels show the fn layer (← = Home, ⌫ = ⌦, …).
struct SpecialKeysPanel: View {
    let menu: ControlMenuModel
    @AppStorage("menu.showFunctionRow") private var showFunctionRow = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                RepeatKey(key: .escape, menu: menu)
                RepeatKey(key: .tab, menu: menu)
                RepeatKey(key: .backspace, menu: menu)
                RepeatKey(key: .forwardDelete, menu: menu)
                Button {
                    showFunctionRow.toggle()
                } label: {
                    Text("F1–F12")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(showFunctionRow ? Color.white : Color.primary)
                        .background(showFunctionRow ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Function keys")
                .accessibilityValue(showFunctionRow ? "Shown" : "Hidden")
            }
            if showFunctionRow {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { ForEach(1...6, id: \.self) { RepeatKey(key: .function($0), menu: menu) } }
                    GridRow { ForEach(7...12, id: \.self) { RepeatKey(key: .function($0), menu: menu) } }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        RepeatKey(key: .home, menu: menu)
                        RepeatKey(key: .pageUp, menu: menu)
                    }
                    GridRow {
                        RepeatKey(key: .end, menu: menu)
                        RepeatKey(key: .pageDown, menu: menu)
                    }
                }
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        RepeatKey(key: .up, menu: menu)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    GridRow {
                        RepeatKey(key: .left, menu: menu)
                        RepeatKey(key: .down, menu: menu)
                        RepeatKey(key: .right, menu: menu)
                    }
                }
            }
        }
    }
}

/// A key that goes down on touch-down and up on touch-up (hold to repeat).
struct RepeatKey: View {
    let key: SpecialKey
    let menu: ControlMenuModel
    @State private var pressed = false

    private var shown: SpecialKey { menu.modifiers.state.fnActive ? key.withFn : key }

    var body: some View {
        Text(shown.label)
            .font(.system(size: shown.label.count > 2 ? 13 : 17, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .background(pressed ? Color.accentColor : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        menu.specialKeyDown(key)
                    }
                    .onEnded { _ in
                        pressed = false
                        menu.specialKeyUp()
                    }
            )
            .onDisappear {
                if pressed {
                    pressed = false
                    menu.specialKeyUp()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(shown.accessibilityName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                menu.specialKeyDown(key)
                menu.specialKeyUp()
            }
    }
}
