// The row above the on-screen keyboard: ⌘ ⌥ ⌃ ⇧ esc ⇥ ← ↑ ↓ →, as in
// Screens / terminal apps. The iPad keyboard has no arrows, Escape or
// modifiers, and the floating menu's panel is a reach away while typing.
//
// It is the soft-keyboard proxy's inputAccessoryView and drives the same
// ControlMenuModel as the floating menu: the modifier toggles are the shared
// sticky modifiers (tap = latch, double-tap = lock, tap again = off; the
// menu and the pill badges show the same state), and the keys are the
// special keys (down on touch-down, up on release, hold to repeat with the
// modifiers held; the fn layer applies: fn+← = Home, …). Like the menu
// (ModifierGlow), a latched modifier is tinted with a soft glow and a locked
// one is filled, underlined, with a tighter glow.
import Observation
import UIKit

@MainActor
final class KeyboardAccessoryBar: UIInputView {
    enum Item: Hashable, Sendable {
        case modifier(StickyModifier)
        case key(SpecialKey)
    }

    static let items: [Item] = [
        .modifier(.command), .modifier(.option), .modifier(.control), .modifier(.shift),
        .key(.escape), .key(.tab),
        .key(.left), .key(.up), .key(.down), .key(.right),
    ]

    static let height: CGFloat = 52

    weak var menu: ControlMenuModel? {
        didSet {
            guard menu !== oldValue else { return }
            observe()
        }
    }

    private var buttons: [Item: UIButton] = [:]
    /// The key whose button is down (its up is sent on release or cancel).
    private var pressedKey: SpecialKey?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        allowsSelfSizing = true
        setUp()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    /// The button for `item` (tests drive it with sendActions).
    func button(for item: Item) -> UIButton? { buttons[item] }

    private func setUp() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in Self.items {
            let b = UIButton(configuration: .gray())
            b.configuration?.cornerStyle = .medium
            b.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            b.configuration?.titleLineBreakMode = .byClipping
            switch item {
            case .modifier(let m):
                b.addAction(UIAction { [weak self] _ in self?.menu?.tapModifier(m) }, for: .touchUpInside)
                b.accessibilityLabel = m.name
                b.accessibilityHint = "Tap to apply to the next key. Double-tap quickly to lock."
            case .key(let k):
                b.addAction(UIAction { [weak self] _ in self?.keyDown(k) }, for: .touchDown)
                for e: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                    b.addAction(UIAction { [weak self] _ in self?.keyUp() }, for: e)
                }
            }
            buttons[item] = b
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        let wide = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -16)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            wide,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func keyDown(_ key: SpecialKey) {
        pressedKey = key
        menu?.specialKeyDown(key)
    }

    private func keyUp() {
        guard pressedKey != nil else { return }
        pressedKey = nil
        menu?.specialKeyUp()
    }

    /// Leaving the screen with a key held (keyboard dismissed mid-press):
    /// release it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { keyUp() }
    }

    /// Re-renders whenever the shared modifier state changes (from here, the
    /// floating menu, or a key consuming a latched modifier).
    private func observe() {
        guard let menu else {
            refresh()
            return
        }
        withObservationTracking {
            refresh(state: menu.modifiers.state)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func refresh(state: ModifierState = ModifierState()) {
        for (item, b) in buttons {
            switch item {
            case .modifier(let m):
                let level = state[m]
                var c: UIButton.Configuration = switch level {
                case .off: .gray()
                case .latched: .tinted()
                case .locked: .filled()
                }
                c.cornerStyle = .medium
                c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
                var attributes = Self.titleAttributes(size: 19)
                if level == .locked { attributes[AttributeScopes.UIKitAttributes.UnderlineStyleAttribute.self] = .single }
                c.attributedTitle = AttributedString(m.symbol, attributes: attributes)
                b.configuration = c
                Self.applyGlow(to: b, level: level)
                b.accessibilityValue = ModifierGlow.accessibilityValue(level)
                b.accessibilityTraits = level == .off ? .button : [.button, .selected]
            case .key(let k):
                let shown = state.fnActive ? k.withFn : k
                b.configuration?.attributedTitle = AttributedString(
                    shown.label, attributes: Self.titleAttributes(size: shown.label.count > 2 ? 14 : 18))
                b.accessibilityLabel = shown.accessibilityName
            }
        }
    }

    /// The glow is a layer shadow in the tint color (shadowPath-less, so it
    /// follows the button's rounded background).
    private static func applyGlow(to b: UIButton, level: StickyLevel) {
        b.layer.shadowColor = b.tintColor.cgColor
        b.layer.shadowOffset = .zero
        b.layer.shadowRadius = ModifierGlow.radius(level)
        b.layer.shadowOpacity = Float(ModifierGlow.opacity(level))
        b.layer.masksToBounds = false
    }

    private static func titleAttributes(size: CGFloat) -> AttributeContainer {
        var a = AttributeContainer()
        a.font = UIFont.systemFont(ofSize: size, weight: .semibold)
        return a
    }

    // Test hooks.
    func title(for item: Item) -> String? {
        buttons[item]?.configuration?.attributedTitle.map { String($0.characters) }
    }
}
