import SwiftUI
import XCTest
@testable import Screener

/// The SwiftUI safe-area behaviour the session overlays rely on, checked in a
/// real window (on an iPhone simulator: the Dynamic Island's 62 pt top inset):
///   - the toast row (SessionPolish: an overlay on the session's ZStack) sits
///     inside the safe area, below the island / notch;
///   - inside the video layer (`.ignoresSafeArea()`), a proxy reports no safe
///     area, so FeedbackOverlayView can't measure it there; SessionView reads
///     it on its ZStack and passes it in.
@MainActor
final class OverlaySafeAreaTests: XCTestCase {
    final class Probe {
        var root = EdgeInsets()
        var insideVideoLayer = EdgeInsets(top: -1, leading: -1, bottom: -1, trailing: -1)
        var toast = CGRect.null
    }

    private struct Session: View {
        let probe: Probe
        let toasts: ToastCenter

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                Color.clear
                    .overlay {
                        Color.clear.onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                            probe.insideVideoLayer = $0
                        }
                    }
                    .ignoresSafeArea()
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { probe.root = $0 }
            .overlay(alignment: .top) {
                ToastOverlay(center: toasts)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.toast = $0 }
            }
        }
    }

    func testToastsSitInsideTheSafeAreaAndTheVideoLayerSeesNone() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let probe = Probe()
        let toasts = ToastCenter(schedule: { _, _ in {} })
        toasts.show("Resizing…")
        window.rootViewController = UIHostingController(rootView: Session(probe: probe, toasts: toasts))
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(3)
        while probe.toast.isNull, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        let safe = window.safeAreaInsets
        XCTAssertEqual(probe.root.top, safe.top)
        XCTAssertEqual(probe.root.leading, safe.left)
        XCTAssertEqual(probe.root.trailing, safe.right)
        XCTAssertEqual(probe.insideVideoLayer, EdgeInsets())
        XCTAssertFalse(probe.toast.isNull)
        XCTAssertGreaterThanOrEqual(probe.toast.minY, safe.top)
        XCTAssertGreaterThanOrEqual(probe.toast.minX, safe.left)
        if UIDevice.current.userInterfaceIdiom == .phone, window.bounds.height > window.bounds.width {
            XCTAssertGreaterThan(safe.top, 20, "a notch / Dynamic Island iPhone simulator")
        }
    }
}
