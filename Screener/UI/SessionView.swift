import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen remote desktop: the composited video with the input layer on
/// top (RemoteInputView), the floating control menu (FloatingMenuView:
/// sticky modifiers, special keys, Mac shortcuts, Keyboard, Type Password,
/// Share Log, Disconnect, …) and SessionStatusOverlay: the connection stage
/// until the first picture decodes, which then fades in from a blur
/// ("Reconnecting…" over the last picture while a suspended session is resumed).
struct SessionView: View {
    let model: SessionCoordinator
    @State private var keyboardVisible = false
    @State private var menu = ControlMenuModel()
    @State private var menuExpanded = false
    /// Touch feedback: GPU ripples / cursor halo (renderer) and the HUD overlay.
    @State private var feedback = FeedbackCenter()
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteScreenView(model: model, store: model.frames, cursor: model.cursor, input: model.input,
                             menu: menu, keyboardVisible: $keyboardVisible, menuExpanded: $menuExpanded,
                             touchMode: TouchInputMode(rawValue: touchModeRaw) ?? .default, feedback: feedback)
                .overlay { FeedbackOverlayView(center: feedback) }
                .ignoresSafeArea()
            // Stages / first-picture reveal / "Reconnecting…" (SessionOverlays.swift).
            SessionStatusOverlay(model: model)
            FloatingMenuView(menu: menu, expanded: $menuExpanded, keyboardVisible: $keyboardVisible,
                             controls: SessionControls(inputAvailable: model.input != nil,
                                                       disconnect: { Task { await model.disconnect() } },
                                                       getClipboard: { model.clipboard.fetchFromMac() },
                                                       sendClipboard: { model.clipboard.sendToMac() }))
            // App-switcher privacy (L5): the snapshot iPadOS takes when the
            // scene leaves the foreground must not show the Mac's screen.
            if scenePhase != .active {
                PrivacyCover().transition(.identity)
            }
        }
        .onAppear {
            // Read on demand from the in-memory connect request (cleared on
            // a user disconnect); never copied or logged.
            let coordinator = model
            menu.password = { [weak coordinator] in coordinator?.lastRequest?.password }
        }
        .onChange(of: displayModeRaw, initial: true) { _, raw in
            model.setDisplayMode(DisplayMode(rawValue: raw) ?? .default)
        }
        // Toasts, the stats overlay, Keep Screen Awake (UI/Toast/SessionPolish.swift).
        .sessionPolish(model)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

/// Covers the remote screen while the scene isn't active (app switcher snapshot).
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            Rectangle().fill(.ultraThinMaterial)
            Image(systemName: "lock.display")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Shares a redacted copy of the app log (for remote TestFlight testing):
/// addresses and names are masked or hashed (LogExport), and the copy is a
/// temporary file made when the share sheet asks for it.
struct RedactedLog: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try LogExport.makeRedactedCopy())
        }
        .suggestedFileName("screener.log")
    }
}

struct ShareLogButton: View {
    var body: some View {
        ShareLink(item: RedactedLog(), preview: SharePreview("screener.log")) {
            Label("Share Log", systemImage: "doc.text.magnifyingglass")
        }
    }
}

/// The video (MTKView drawn on demand by MetalRenderer, with the host
/// cursor) under a transparent RemoteInputView of the same size.
struct RemoteScreenView: UIViewRepresentable {
    let model: SessionCoordinator
    let store: VideoFrameStore
    let cursor: RemoteCursor
    let input: InputController?
    let menu: ControlMenuModel
    @Binding var keyboardVisible: Bool
    @Binding var menuExpanded: Bool
    let touchMode: TouchInputMode
    let feedback: FeedbackCenter

    final class Coordinator {
        var renderer: MetalRenderer?
    }

    final class Container: UIView {
        let video = MTKView(frame: .zero)
        let remoteInput = RemoteInputView(frame: .zero)
        /// Zoom/pan: changed by the input view, drawn by the renderer.
        let viewport = ViewportModel()
        /// The video's size changed (rotation, Stage Manager): points, screen scale.
        var onSizeChange: ((CGSize, CGFloat) -> Void)?
        private var reportedSize: CGSize?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != reportedSize, bounds.width > 0, bounds.height > 0, let window else { return }
            reportedSize = bounds.size
            onSizeChange?(bounds.size, window.screen.nativeScale)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportedSize = nil
            setNeedsLayout()
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            video.backgroundColor = .black
            for v in [video, remoteInput] as [UIView] {
                v.frame = bounds
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(v)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Container {
        let view = Container(frame: .zero)
        view.remoteInput.viewport = view.viewport
        if let renderer = MetalRenderer(store: store, cursor: cursor) {
            renderer.viewport = view.viewport
            renderer.feedback = feedback
            renderer.attach(to: view.video)
            context.coordinator.renderer = renderer
        }
        view.remoteInput.cursor = cursor
        view.remoteInput.feedback = feedback
        feedback.onMinimapJump = { [weak view] in view?.remoteInput.jumpViewport(toContentUnit: $0) }
        // Rotation / Stage Manager resize → in-band dynamic resolution (DisplayResizer).
        view.onSizeChange = { [weak model] size, scale in model?.viewSizeChanged(points: size, scale: scale) }
        // Before any teardown (disconnect, background, failure) the
        // coordinator must release every held key/button on the Mac; this is
        // the one seam between the UI's RemoteInputView and the coordinator,
        // held weakly so a torn-down view simply makes it a no-op.
        model.releaseInput = { [weak view] in view?.remoteInput.releaseAll() }
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        view.remoteInput.input = input
        view.remoteInput.touchMode = touchMode
        view.remoteInput.menuOpen = menuExpanded
        let binding = $keyboardVisible
        view.remoteInput.onSoftwareKeyboardDismissed = { binding.wrappedValue = false }
        view.remoteInput.softwareKeyboardVisible = keyboardVisible && input != nil
        // The floating menu: shared sticky modifiers, its key sink, ⌘⌥M, and
        // the pointer position for keeping the pill out of the cursor's way.
        view.remoteInput.modifiers = menu.modifiers
        menu.sink = view.remoteInput
        view.remoteInput.controlMenu = menu
        let expanded = $menuExpanded
        view.remoteInput.onToggleMenu = { expanded.wrappedValue.toggle() }
        view.remoteInput.onInputReleased = { [weak menu] in menu?.inputWasReleased() }
        view.remoteInput.onPointerMoved = { [weak menu] in menu?.pointerMoved(to: $0) }
    }

    static func dismantleUIView(_ view: Container, coordinator: Coordinator) {
        view.video.isPaused = true
        view.video.delegate = nil
        view.remoteInput.input = nil
        view.remoteInput.cursor = nil
        view.remoteInput.feedback = nil
        view.remoteInput.modifiers = nil
        view.remoteInput.controlMenu = nil
        view.remoteInput.onPointerMoved = nil
        view.onSizeChange = nil
        coordinator.renderer?.detach()
        coordinator.renderer = nil
    }
}
