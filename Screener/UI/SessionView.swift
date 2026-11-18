import MetalKit
import SwiftUI

/// Full-screen remote desktop: the composited video with the input layer on
/// top (RemoteInputView), the floating control menu (FloatingMenuView:
/// sticky modifiers, special keys, Mac shortcuts, Keyboard, Type Password,
/// Share Log, Disconnect, …) and a "Connecting…" overlay until the first
/// picture decodes ("Reconnecting…" over the last picture while a session
/// suspended by backgrounding is resumed).
struct SessionView: View {
    let model: SessionCoordinator
    @State private var keyboardVisible = false
    @State private var menu = ControlMenuModel()
    @State private var menuExpanded = false
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteScreenView(model: model, store: model.frames, cursor: model.cursor, input: model.input,
                             menu: menu, keyboardVisible: $keyboardVisible, menuExpanded: $menuExpanded,
                             touchMode: TouchInputMode(rawValue: touchModeRaw) ?? .default)
                .ignoresSafeArea()
            if model.isReconnecting || !model.hasFirstFrame {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(model.isReconnecting ? "Reconnecting…" : "Connecting…")
                        .font(.headline).foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            FloatingMenuView(menu: menu, expanded: $menuExpanded, keyboardVisible: $keyboardVisible,
                             controls: SessionControls(inputAvailable: model.input != nil,
                                                       disconnect: { Task { await model.disconnect() } }))
        }
        .onAppear {
            // Read on demand from the in-memory connect request (cleared on
            // a user disconnect); never copied or logged.
            let coordinator = model
            menu.password = { [weak coordinator] in coordinator?.lastRequest?.password }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

/// Shares Documents/screener.log (for remote TestFlight testing).
struct ShareLogButton: View {
    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("screener.log")
    }

    var body: some View {
        ShareLink(item: Self.logURL, preview: SharePreview("screener.log")) {
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

    final class Coordinator {
        var renderer: MetalRenderer?
    }

    final class Container: UIView {
        let video = MTKView(frame: .zero)
        let remoteInput = RemoteInputView(frame: .zero)
        /// Zoom/pan: changed by the input view, drawn by the renderer.
        let viewport = ViewportModel()

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
            renderer.attach(to: view.video)
            context.coordinator.renderer = renderer
        }
        view.remoteInput.cursor = cursor
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
        view.remoteInput.modifiers = nil
        view.remoteInput.controlMenu = nil
        view.remoteInput.onPointerMoved = nil
        coordinator.renderer?.detach()
        coordinator.renderer = nil
    }
}
