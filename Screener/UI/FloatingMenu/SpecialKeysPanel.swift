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

/// A special key's press → key events (pure; SpecialKeysTests). The key is
/// a plain Button so a drag that starts on it scrolls the menu (a
/// `DragGesture(minimumDistance: 0)` claimed every touch, and the menu's
/// ScrollView never got to scroll): it goes down when the button shows
/// pressed (a ScrollView delays that briefly, and cancels it when the touch
/// turns into a scroll) and up when it stops; held, it repeats. A tap too
/// quick to ever show pressed still sends one key from the button's action.
struct RepeatKeyPress {
    enum Event: Equatable { case down, up }

    private(set) var isDown = false
    /// A down was sent during the current press (cleared once the action had its chance).
    private(set) var sentThisPress = false

    mutating func pressedChanged(_ pressed: Bool) -> [Event] {
        if pressed, !isDown {
            isDown = true
            sentThisPress = true
            return [.down]
        }
        if !pressed, isDown {
            isDown = false
            return [.up]
        }
        return []
    }

    /// The button's action (a tap that ended inside it).
    mutating func tapped() -> [Event] {
        defer { sentThisPress = false }
        return sentThisPress || isDown ? [] : [.down, .up]
    }

    /// After a press ended and its action (if any) ran.
    mutating func pressFinished() { if !isDown { sentThisPress = false } }
}

/// A key that goes down on press and up on release (hold to repeat).
struct RepeatKey: View {
    let key: SpecialKey
    let menu: ControlMenuModel
    @State private var press = RepeatKeyPress()

    private var shown: SpecialKey { menu.modifiers.state.fnActive ? key.withFn : key }

    var body: some View {
        Button {
            send(press.tapped())
        } label: {
            EmptyView()
        }
        .buttonStyle(RepeatKeyStyle(label: shown.label) { pressed in
            send(press.pressedChanged(pressed))
            if !pressed {
                // The action (if the touch ended inside) runs right after; then forget this press.
                DispatchQueue.main.async { press.pressFinished() }
            }
        })
        .onDisappear { send(press.pressedChanged(false)) }
        .accessibilityElement()
        .accessibilityLabel(shown.accessibilityName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            menu.specialKeyDown(key)
            menu.specialKeyUp()
        }
    }

    private func send(_ events: [RepeatKeyPress.Event]) {
        for e in events {
            switch e {
            case .down: menu.specialKeyDown(key)
            case .up: menu.specialKeyUp()
            }
        }
    }
}

/// The key cap; reports press changes (RepeatKey turns them into key events).
private struct RepeatKeyStyle: ButtonStyle {
    let label: String
    let pressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        Text(label)
            .font(.system(size: label.count > 2 ? 13 : 17, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(configuration.isPressed ? Color.white : Color.primary)
            .background(configuration.isPressed ? Color.accentColor : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in pressChanged(pressed) }
    }
}
