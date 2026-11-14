import MetalKit
import SwiftUI

/// Full-screen remote desktop: the composited video, a small floating toolbar
/// (Disconnect, Share Log) and a "Connecting…" overlay until the first
/// picture decodes.
struct SessionView: View {
    let model: SessionCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoView(store: model.frames)
                .ignoresSafeArea()
            if !model.hasFirstFrame {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Connecting…").font(.headline).foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay(alignment: .topTrailing) { toolbar }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ShareLogButton()
            Button(role: .destructive) {
                Task { await model.disconnect() }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(12)
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

/// MTKView drawn on demand by MetalRenderer (redrawn when a picture arrives).
struct VideoView: UIViewRepresentable {
    let store: VideoFrameStore

    final class Coordinator {
        var renderer: MetalRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.backgroundColor = .black
        if let renderer = MetalRenderer(store: store) {
            renderer.attach(to: view)
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer?.detach()
        coordinator.renderer = nil
    }
}
