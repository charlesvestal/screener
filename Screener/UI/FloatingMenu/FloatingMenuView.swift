// The floating control menu: a draggable pill that expands into a panel of
// sticky modifiers, special keys, Mac shortcuts and session controls.
//
// Pill: drag it anywhere; on release it springs to the nearest screen edge.
// Its place (edge + position along it) is remembered per orientation
// (@AppStorage). It fades to 30% after 3 s without interaction, steps aside
// while the remote pointer is over it, and shows latched/locked modifier
// badges. ⌘⌥M on a hardware keyboard toggles the panel (RemoteInputView).
import SwiftUI

/// Where the collapsed pill rests: an edge and a 0…1 position along it.
struct PillPlacement: Equatable {
    enum Edge: String { case leading, trailing, top, bottom }

    var edge: Edge
    var fraction: Double

    static let `default` = PillPlacement(edge: .trailing, fraction: 0.12)
    static let margin: CGFloat = 12

    init(edge: Edge, fraction: Double) {
        self.edge = edge
        self.fraction = min(1, max(0, fraction))
    }

    /// "edge:fraction" (the @AppStorage form); nil if malformed.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let e = Edge(rawValue: String(parts[0])), let f = Double(parts[1]) else { return nil }
        self.init(edge: e, fraction: f)
    }

    var rawValue: String { "\(edge.rawValue):\(fraction)" }

    /// The edge nearest to `center` in a container of `size`, keeping the
    /// position along it.
    static func snapped(center: CGPoint, in size: CGSize) -> PillPlacement {
        guard size.width > 0, size.height > 0 else { return .default }
        let distances: [(Edge, CGFloat)] = [
            (.leading, center.x), (.trailing, size.width - center.x),
            (.top, center.y), (.bottom, size.height - center.y),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        switch edge {
        case .leading, .trailing: return PillPlacement(edge: edge, fraction: center.y / size.height)
        case .top, .bottom: return PillPlacement(edge: edge, fraction: center.x / size.width)
        }
    }

    /// The pill's center for a pill of `pill` size, kept fully inside `size`.
    func center(pill: CGSize, in size: CGSize) -> CGPoint {
        let m = Self.margin
        let minX = m + pill.width / 2, maxX = max(minX, size.width - m - pill.width / 2)
        let minY = m + pill.height / 2, maxY = max(minY, size.height - m - pill.height / 2)
        func clampX(_ x: CGFloat) -> CGFloat { min(maxX, max(minX, x)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(maxY, max(minY, y)) }
        switch edge {
        case .leading: return CGPoint(x: minX, y: clampY(fraction * size.height))
        case .trailing: return CGPoint(x: maxX, y: clampY(fraction * size.height))
        case .top: return CGPoint(x: clampX(fraction * size.width), y: minY)
        case .bottom: return CGPoint(x: clampX(fraction * size.width), y: maxY)
        }
    }

    /// Where the pill steps to while the pointer is over it: along its edge,
    /// toward the middle of the screen, by its own length plus a gap.
    func asideOffset(pill: CGSize, in size: CGSize) -> CGSize {
        switch edge {
        case .leading, .trailing:
            let dy = pill.height + 32
            return CGSize(width: 0, height: fraction < 0.5 ? dy : -dy)
        case .top, .bottom:
            let dx = pill.width + 32
            return CGSize(width: fraction < 0.5 ? dx : -dx, height: 0)
        }
    }
}

/// What the session offers the menu beyond keys.
struct SessionControls {
    var inputAvailable: Bool
    var disconnect: () -> Void
    /// "Get Clipboard": fetch the Mac's clipboard onto the iPad (nil: unavailable).
    var getClipboard: (() -> Void)? = nil
    /// "Send Clipboard": send the iPad's text to the Mac; false if there was none.
    var sendClipboard: (() -> Bool)? = nil
    /// "?": reopens the gesture coach (GestureCoach).
    var openCoach: (() -> Void)? = nil
    /// "Switch Mac": the saved Macs to switch to (nil: no tile).
    var switchMac: MacSwitcher? = nil
    /// "Picture in Picture": starts / stops PiP (nil: unsupported, no tile).
    var togglePictureInPicture: (() -> Void)? = nil
    var pictureInPicturePossible = false
    var pictureInPictureActive = false
}

struct FloatingMenuView: View {
    let menu: ControlMenuModel
    @Binding var expanded: Bool
    @Binding var keyboardVisible: Bool
    let controls: SessionControls

    @AppStorage("menu.pill.landscape") private var landscapeRaw = PillPlacement.default.rawValue
    @AppStorage("menu.pill.portrait") private var portraitRaw = PillPlacement.default.rawValue
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var pillSize = CGSize(width: 56, height: 44)
    @State private var panelSize = CGSize(width: 380, height: 600)
    @State private var idle = false
    @State private var idleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let landscape = size.width > size.height
            let placement = PillPlacement(rawValue: landscape ? landscapeRaw : portraitRaw) ?? .default
            let rest = placement.center(pill: pillSize, in: size)
            let aside = menu.pointerOverPill && !dragging ? placement.asideOffset(pill: pillSize, in: size) : .zero
            ZStack(alignment: .topLeading) {
                if expanded {
                    ControlPanel(menu: menu, expanded: $expanded, keyboardVisible: $keyboardVisible,
                                 controls: controls)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                        .position(panelCenter(placement: placement, pillCenter: rest, in: size))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    pill
                        .gesture(dragGesture(rest: rest, size: size, landscape: landscape))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { pillSize = $0 }
                        .position(x: rest.x + drag.width + aside.width, y: rest.y + drag.height + aside.height)
                        .transition(.opacity)
                }
            }
            // The resting frame (no drag / aside offset) in window coordinates, for pointer avoidance.
            .onChange(of: restingFrame(rest, origin: geo.frame(in: .global).origin), initial: true) { _, f in
                menu.pillRestingFrame = f
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: aside)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: expanded)
        .onChange(of: expanded) { _, isExpanded in
            if !isExpanded { menu.menuDidCollapse() }
            poke()
        }
        .onChange(of: menu.modifiers.state) { _, _ in poke() }
        .onAppear { poke() }
        .onDisappear {
            idleTask?.cancel()
            menu.menuDidCollapse()
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 17, weight: .semibold))
            ModifierBadges(state: menu.modifiers.state)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(Capsule())
        .menuGlass(Capsule())
        .opacity(idle && !dragging ? 0.3 : 1)
        .animation(.easeInOut(duration: 0.4), value: idle)
        .onTapGesture { expanded = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Control Menu")
        .accessibilityValue(ModifierBadges.accessibilityText(menu.modifiers.state))
        .accessibilityHint("Opens modifier keys, special keys, Mac shortcuts and session controls.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { expanded = true }
    }

    private func dragGesture(rest: CGPoint, size: CGSize, landscape: Bool) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                dragging = true
                drag = v.translation
                poke()
            }
            .onEnded { v in
                let end = CGPoint(x: rest.x + v.translation.width, y: rest.y + v.translation.height)
                let snapped = PillPlacement.snapped(center: end, in: size)
                // Spring from where the finger left it to the new resting place.
                let target = snapped.center(pill: pillSize, in: size)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if landscape { landscapeRaw = snapped.rawValue } else { portraitRaw = snapped.rawValue }
                    drag = CGSize(width: end.x - target.x, height: end.y - target.y)
                }
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.72)) {
                    drag = .zero
                }
                dragging = false
                poke()
            }
    }

    private func restingFrame(_ center: CGPoint, origin: CGPoint) -> CGRect {
        CGRect(x: origin.x + center.x - pillSize.width / 2, y: origin.y + center.y - pillSize.height / 2,
               width: pillSize.width, height: pillSize.height)
    }

    /// The panel opens beside the pill's edge, clamped on screen.
    private func panelCenter(placement: PillPlacement, pillCenter: CGPoint, in size: CGSize) -> CGPoint {
        let m = PillPlacement.margin
        let w = min(panelSize.width, size.width - 2 * m), h = min(panelSize.height, size.height - 2 * m)
        func clampX(_ x: CGFloat) -> CGFloat { min(size.width - m - w / 2, max(m + w / 2, x)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(size.height - m - h / 2, max(m + h / 2, y)) }
        switch placement.edge {
        case .leading: return CGPoint(x: m + w / 2, y: clampY(pillCenter.y))
        case .trailing: return CGPoint(x: size.width - m - w / 2, y: clampY(pillCenter.y))
        case .top: return CGPoint(x: clampX(pillCenter.x), y: m + h / 2)
        case .bottom: return CGPoint(x: clampX(pillCenter.x), y: size.height - m - h / 2)
        }
    }

    /// Interaction: full opacity now, fade again after 3 s idle.
    private func poke() {
        idle = false
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            idle = true
        }
    }
}

/// The expanded panel.
private struct ControlPanel: View {
    let menu: ControlMenuModel
    @Binding var expanded: Bool
    @Binding var keyboardVisible: Bool
    let controls: SessionControls
    @State private var passwordArmed = false
    @State private var disarmTask: Task<Void, Never>?
    @AppStorage(PacingConfig.defaultsKey) private var smoothPlayback = false
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    private var touchMode: TouchInputMode { TouchInputMode(rawValue: touchModeRaw) ?? .default }
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    private var displayMode: DisplayMode { DisplayMode(rawValue: displayModeRaw) ?? .default }
    @AppStorage(ClipboardSyncMode.defaultsKey) private var clipboardModeRaw = ClipboardSyncMode.default.rawValue
    private var clipboardAuto: Bool { (ClipboardSyncMode(rawValue: clipboardModeRaw) ?? .default) == .automatic }
    /// Brief confirmation on a clipboard tile ("Sent", "No Text", …).
    @State private var clipboardFlash: (tile: Int, text: String)?
    @State private var clipboardFlashTask: Task<Void, Never>?
    @AppStorage(ScreenerSettings.statsOverlayKey) private var showStats = ScreenerSettings.statsOverlayDefault
    /// The session's live stats (SessionView's environment); nil outside a session.
    @Environment(LiveStatsModel.self) private var liveStats: LiveStatsModel?

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 372)
        .menuGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onDisappear { disarmTask?.cancel(); clipboardFlashTask?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Controls").font(.headline)
                Spacer()
                Text("⌥⌘M").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    expanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Control Menu")
            }
            if let liveStats { QualityBadge(stats: liveStats) }
            section("Modifiers") { ModifierBar(menu: menu) }
            section("Keys") { SpecialKeysPanel(menu: menu) }
            section("Mac Shortcuts") { shortcuts }
            section("Session") { sessionControls }
        }
        .padding(16)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            c()
        }
    }

    private var shortcuts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(ShortcutAction.allCases) { action in
                Button {
                    menu.perform(action)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: action.systemImage).font(.system(size: 16))
                        Text(action.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(action.shortcutText).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(highlight(action) ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!controls.inputAvailable)
                .accessibilityLabel(action.title)
                .accessibilityHint(action == .appSwitcher
                                   ? "Holds Command. Tap again to move to the next app."
                                   : "Sends \(action.shortcutText) to the Mac.")
            }
        }
    }

    private func highlight(_ action: ShortcutAction) -> Bool {
        action == .appSwitcher && menu.appSwitcherActive
    }

    private var sessionControls: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            tile(keyboardVisible ? "Hide Keyboard" : "Keyboard",
                 keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                 selected: keyboardVisible) { keyboardVisible.toggle() }
                .disabled(!controls.inputAvailable)
            tile(passwordArmed ? "Tap to Type" : "Type Password",
                 passwordArmed ? "key.fill" : "key", selected: passwordArmed,
                 hint: menu.canTypePassword
                    ? "Types the saved password for this Mac, then Return. Asks for a second tap."
                    : "No password is stored for this session.") {
                typePasswordTapped()
            }
            .disabled(!controls.inputAvailable || !menu.canTypePassword)
            tile(clipboardFlash?.tile == 0 ? clipboardFlash!.text : "Get Clipboard", "doc.on.clipboard",
                 hint: "Copies the Mac's clipboard text to this iPad.") {
                controls.getClipboard?()
                flashClipboard(0, "Requested")
            }
            .disabled(controls.getClipboard == nil || !controls.inputAvailable)
            tile(clipboardFlash?.tile == 1 ? clipboardFlash!.text : "Send Clipboard", "clipboard",
                 hint: "Sends this iPad's clipboard text to the Mac.") {
                flashClipboard(1, controls.sendClipboard?() == true ? "Sent" : "No Text")
            }
            .disabled(controls.sendClipboard == nil || !controls.inputAvailable)
            tile("Auto Clipboard", clipboardAuto ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle",
                 selected: clipboardAuto,
                 hint: "On: text copied on either side is copied to the other automatically; iPadOS may ask "
                    + "to allow pasting. Off: use Get Clipboard and Send Clipboard.") {
                clipboardModeRaw = (clipboardAuto ? ClipboardSyncMode.manual : .automatic).rawValue
            }
            .accessibilityValue(clipboardAuto ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            tile("Mute", audioMuted ? "speaker.slash.fill" : "speaker.wave.2", selected: audioMuted,
                 hint: "Silences the Mac's sound on this iPad.") { audioMuted.toggle() }
                .accessibilityValue(audioMuted ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
            displayMenu
            tile(touchMode.title, touchMode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left",
                 hint: "Input mode for your fingers. Trackpad: drag to move the pointer, tap to click. "
                    + "Touch: the pointer goes where you touch. Tap to switch.") {
                touchModeRaw = (touchMode == .trackpad ? TouchInputMode.direct : .trackpad).rawValue
            }
            tile("Find Cursor", "scope",
                 hint: "Closes the menu, centres the view on the Mac's pointer and enlarges it briefly. "
                    + "Shaking the pointer does the same.") {
                expanded = false
                menu.findCursor()
            }
            .disabled(!controls.inputAvailable)
            tile("Stats", showStats ? "chart.bar.fill" : "chart.bar", selected: showStats,
                 hint: "Shows frame rate, bitrate, decode time and loss over the session.") { showStats.toggle() }
                .accessibilityValue(showStats ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
            tile("Smooth Playback", smoothPlayback ? "waveform.path" : "waveform.path.ecg",
                 selected: smoothPlayback,
                 hint: "Presents frames on the Mac's timeline: smoother motion, a little more delay. "
                    + "Takes effect on the next connection.") { smoothPlayback.toggle() }
                .accessibilityValue(smoothPlayback ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
            ShareLink(item: RedactedLog(), preview: SharePreview("screener.log")) {
                tileLabel("Share Log", "doc.text.magnifyingglass", selected: false, destructive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share Log")
            tile("Gesture Help", "questionmark.circle", hint: "Shows the gesture coach again.") {
                controls.openCoach?()
            }
            .disabled(controls.openCoach == nil)
            if let togglePiP = controls.togglePictureInPicture {
                tile("Picture in Picture", controls.pictureInPictureActive ? "pip.exit" : "pip.enter",
                     selected: controls.pictureInPictureActive,
                     hint: "Keeps the Mac in a floating window while you use other apps.") {
                    expanded = false
                    togglePiP()
                }
                .disabled(!controls.pictureInPictureActive && !controls.pictureInPicturePossible)
                .accessibilityValue(controls.pictureInPictureActive ? "On" : "Off")
            }
            if let switcher = controls.switchMac {
                SwitchMacTile(switcher: switcher) { expanded = false }
            }
            tile("Disconnect", "xmark.circle.fill", destructive: true) { controls.disconnect() }
        }
    }

    private func flashClipboard(_ tile: Int, _ text: String) {
        clipboardFlashTask?.cancel()
        clipboardFlash = (tile, text)
        clipboardFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            clipboardFlash = nil
        }
    }

    /// Display mode picker (DisplayMode; SessionView applies the change).
    private var displayMenu: some View {
        Menu {
            Picker("Display", selection: $displayModeRaw) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Section { Text(displayMode.detail) }
        } label: {
            tileLabel(displayMode.title, "display", selected: false, destructive: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Display")
        .accessibilityValue(displayMode.title)
        .accessibilityHint("How large the Mac's desktop is. Fit matches this window; More Space shows more; "
                           + "Sharper uses fewer, crisper pixels; Match Mac uses the Mac's own resolution.")
    }

    private func typePasswordTapped() {
        disarmTask?.cancel()
        if passwordArmed {
            passwordArmed = false
            menu.typePassword()
        } else {
            passwordArmed = true
            disarmTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                passwordArmed = false
            }
        }
    }

    private func tile(_ title: String, _ image: String, selected: Bool = false, destructive: Bool = false,
                      hint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileLabel(title, image, selected: selected, destructive: destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }

    private func tileLabel(_ title: String, _ image: String, selected: Bool, destructive: Bool) -> some View {
        TileLabel(title: title, image: image, selected: selected, destructive: destructive)
    }
}

struct TileLabel: View {
    let title: String
    let image: String
    let selected: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: image).font(.system(size: 17))
            Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(destructive ? Color.red : (selected ? Color.white : Color.primary))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(selected ? Color.accentColor : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
    }
}

extension View {
    /// Liquid Glass (iPadOS 26); a solid material when Reduce Transparency is on.
    func menuGlass<S: Shape>(_ shape: S) -> some View {
        modifier(MenuGlass(shape: shape))
    }
}

private struct MenuGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

#if DEBUG
/// DEBUG-only: the menu over a stand-in desktop, no Mac (launch with
/// `-previewControlMenu YES`, optionally `-previewMenuExpanded YES`).
///
/// `-previewSettings YES` shows Settings instead; `-previewStats YES` adds
/// synthetic live stats (badge + overlay) and a toast.
struct FloatingMenuPreview: View {
    @State private var menu = ControlMenuModel()
    @State private var expanded = UserDefaults.standard.bool(forKey: "previewMenuExpanded")
    @State private var keyboard = false
    @State private var stats = LiveStatsModel()
    /// Never auto-dismissed (screenshots).
    @State private var toasts = ToastCenter(schedule: { _, _ in {} })
    private let withStats = UserDefaults.standard.bool(forKey: "previewStats")

    var body: some View {
        if UserDefaults.standard.bool(forKey: "previewSettings") {
            SettingsView()
        } else {
            ZStack {
                LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                if withStats {
                    StatsOverlay(stats: stats)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                FloatingMenuView(menu: menu, expanded: $expanded, keyboardVisible: $keyboard,
                                 controls: SessionControls(inputAvailable: true, disconnect: {}))
            }
            .overlay(alignment: .top) { ToastOverlay(center: toasts) }
            .environment(withStats ? stats : nil)
            .onAppear {
                menu.password = { "preview" }
                menu.tapModifier(.command)
                menu.tapModifier(.shift)
                menu.tapModifier(.shift)
                if withStats {
                    stats.loadPreview()
                    toasts.show(SessionToasts.sentToMac, systemImage: "doc.on.clipboard")
                }
            }
        }
    }
}
#endif
