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
//
// Narrow widths (iPhone portrait, a slim window): the keys keep a 44 pt
// minimum and the row scrolls sideways (`rowLayout`); wide ones center it at
// up to 720 pt with the keys sharing the width equally.
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
    static let minimumKeyWidth: CGFloat = 44
    static let spacing: CGFloat = 6
    static let maximumRowWidth: CGFloat = 720
    static let sideMargin: CGFloat = 8

    /// The row's width for a bar `width` wide, its leading inset (centred
    /// when it fits), and whether it has to scroll.
    static func rowLayout(width: CGFloat, itemCount: Int = items.count)
        -> (rowWidth: CGFloat, inset: CGFloat, scrolls: Bool) {
        let available = max(0, width - 2 * sideMargin)
        let n = CGFloat(itemCount)
        let minimum = n * minimumKeyWidth + max(0, n - 1) * spacing
        let row = max(minimum, min(available, maximumRowWidth))
        let scrolls = row > available
        return (row, scrolls ? sideMargin : (width - row) / 2, scrolls)
    }

    weak var menu: ControlMenuModel? {
        didSet {
            guard menu !== oldValue else { return }
            observe()
        }
    }

    private var buttons: [Item: UIButton] = [:]
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowWidth: NSLayoutConstraint?
    /// Test hook: the row scrolls at the current width.
    private(set) var rowScrolls = false
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
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = Self.spacing
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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        addSubview(scroll)
        scroll.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: Self.maximumRowWidth)
        rowWidth = width
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
            width,
        ])
    }

    override func layoutSubviews() {
        // Landscape iPhone: keep clear of the sensor housing / corners.
        let safe = safeAreaInsets
        let layout = Self.rowLayout(width: bounds.width - safe.left - safe.right)
        if rowWidth?.constant != layout.rowWidth { rowWidth?.constant = layout.rowWidth }
        let insets = UIEdgeInsets(top: 0, left: safe.left + layout.inset, bottom: 0,
                                  right: safe.right + (layout.scrolls ? Self.sideMargin : 0))
        if scroll.contentInset != insets {
            scroll.contentInset = insets
            scroll.contentOffset = CGPoint(x: -insets.left, y: 0)
        }
        scroll.isScrollEnabled = layout.scrolls
        rowScrolls = layout.scrolls
        super.layoutSubviews()
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
