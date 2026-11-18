// Ported from iShareScreen src/isharescreen/proxy/input.py (InputController:
// set_server_dims, pointer_event, scroll_event, key_event, _send) and
// frontend/desktop/app.py (to_canvas, on_cursor_pos, on_mouse_button,
// on_scroll wheel curve) (AGPL-3.0)
//
// Sends user input to the host over the control channel.
//
// Wire behaviour (input.py):
// - Pointer: every pointer event is a msg 0x10 HandleEncryptedEventMessage
//   (18 bytes; AES-128-ECB of [10×00, ff, buttons, u16 x, u16 y] under the
//   record layer's content key = the reference's `cipher.cbc_key`), because
//   "Apple's stock HP client wraps every pointer event in msg 0x10" and the
//   0x05 path bypasses the daemon's cursor-tracker side effects. Plain 0x05
//   is only used without a cipher (never in an HP session). Both go through
//   the record layer like every other message (encrypt_and_send).
// - Coordinates are host CANVAS pixels — the backing size from the 0x1c
//   answer, updated from each 0x451's backing size (set_server_dims) — and
//   are clamped to 0…w-1 / 0…h-1 before sending.
// - Buttons: Apple's mask, bit0 = left, bit1 = right, bit2 = middle.
// - Scroll: `abs(dy)` press/release pairs of bit3 (up, dy < 0) or bit4
//   (down) at the pointer; each pair scrolls the host by exactly 1 pixel.
//   Horizontal scroll is not supported by the reference (dx is ignored).
// - Keys: plain 0x04 KeyEvent (down/up, X11 keysym); keysym 0 is dropped.
// - Send errors are swallowed (a stale socket must not reach the UI).
//
// View → host mapping (app.py to_canvas): the fraction across the presented
// canvas, clamped to [0, 1], times the canvas size, truncated and clamped.
// Here the canvas is aspect-fitted (CompositeLayout.aspectFit), so the
// fraction is taken across the fitted rect and letterbox points clamp to the
// nearest edge. Zoomed (Viewport), the view point is first mapped back
// through the viewport's inverse to the unzoomed one.
//
// Pacing: the reference sends one pointer event per OS motion event, unpaced.
// Here sends are serialised on one task; a pure move queued behind an
// in-flight send is replaced by the next move (latest wins), so a slow
// channel never builds a backlog of stale positions. Button changes, scroll
// ticks and keys are never dropped or reordered.
import CoreGraphics
import Foundation

@MainActor
final class InputController {
    typealias Send = @Sendable (Data) async throws -> Void

    enum Button {
        static let left = Int(ClientMessage.Button.left)
        static let right = Int(ClientMessage.Button.right)
        static let middle = Int(ClientMessage.Button.middle)
        static let scrollUp = Int(ClientMessage.Button.scrollUp)
        static let scrollDown = Int(ClientMessage.Button.scrollDown)
    }

    private(set) var serverWidth: Int
    private(set) var serverHeight: Int
    /// Backing pixels per logical point on the host (0x451 backing / scaled).
    var pointScale: CGFloat = 2
    /// Messages handed to the control channel (input.py tx_pkts).
    private(set) var sentCount = 0

    private let contentKey: Data?
    private let send: Send
    private var queue: [(message: Data, coalescable: Bool)] = []
    private var drainTask: Task<Void, Never>?
    private var closed = false

    init(contentKey: Data?, serverWidth: Int, serverHeight: Int, send: @escaping Send) {
        self.contentKey = contentKey
        self.serverWidth = serverWidth
        self.serverHeight = serverHeight
        self.send = send
    }

    func close() {
        closed = true
        queue.removeAll()
    }

    /// input.py set_server_dims: ignored unless both are positive.
    func setServerDims(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        serverWidth = width
        serverHeight = height
    }

    // MARK: events

    /// input.py pointer_event. `coalescable`: a pure move that a later move
    /// may replace while it waits to be sent.
    func pointer(buttons: Int, x: Int, y: Int, coalescable: Bool = false) {
        let cx = max(0, min(serverWidth - 1, x))
        let cy = max(0, min(serverHeight - 1, y))
        let message: Data
        if let contentKey {
            guard let m = try? ClientMessage.encryptedPointerEvent(key: contentKey, buttons: buttons, x: cx, y: cy)
            else { return }
            message = m
        } else {
            message = ClientMessage.pointerEvent(buttons: buttons, x: cx, y: cy)
        }
        enqueue(message, coalescable: coalescable)
    }

    /// input.py scroll_event: `abs(dy)` press/release pairs (dy < 0 = up).
    func scroll(x: Int, y: Int, dy: Int) {
        guard dy != 0 else { return }
        let bit = dy < 0 ? Button.scrollUp : Button.scrollDown
        for _ in 0..<abs(dy) {
            pointer(buttons: bit, x: x, y: y)
            pointer(buttons: 0, x: x, y: y)
        }
    }

    /// input.py key_event.
    func key(down: Bool, keysym: UInt32) {
        guard keysym != 0 else { return }
        enqueue(ClientMessage.keyEvent(down: down, keysym: keysym), coalescable: false)
    }

    /// Waits until everything queued so far has been handed to the channel.
    func flush() async {
        while let task = drainTask { await task.value }
    }

    // MARK: mapping

    /// The host pixel under `point` of a view of `viewSize` showing the
    /// aspect-fitted canvas through `viewport` (its inverse maps the drawn
    /// point back to the unzoomed one); letterbox points clamp to the
    /// nearest edge.
    func hostPoint(forViewPoint point: CGPoint, viewSize: CGSize,
                   viewport: Viewport = .identity) -> (x: Int, y: Int)? {
        let w = serverWidth, h = serverHeight
        let fit = CompositeLayout.aspectFit(CGSize(width: w, height: h), in: viewSize)
        guard fit.width > 0, fit.height > 0 else { return nil }
        let base = viewport.toBase(point, viewSize: viewSize)
        let u = min(1, max(0, (base.x - fit.minX) / fit.width))
        let v = min(1, max(0, (base.y - fit.minY) / fit.height))
        let x = min(w - 1, Int(u * CGFloat(w)))
        let y = min(h - 1, Int(v * CGFloat(h)))
        return (max(0, x), max(0, y))
    }

    /// Where the aspect-fitted canvas lands in a view of `viewSize` (view
    /// coordinates); `.zero` before the view or the canvas has an extent.
    /// The system pointer is hidden only inside this rect (RemoteInputView);
    /// outside it (the letterbox) is not part of the video.
    func fittedRect(in viewSize: CGSize) -> CGRect {
        CompositeLayout.aspectFit(CGSize(width: serverWidth, height: serverHeight), in: viewSize)
    }

    /// The UNZOOMED view point at the centre of host pixel (x, y) — the
    /// inverse of hostPoint without the viewport (Viewport.toScreen gives
    /// where it is drawn).
    func baseViewPoint(forHostX x: CGFloat, y: CGFloat, viewSize: CGSize) -> CGPoint? {
        let fit = fittedRect(in: viewSize)
        guard fit.width > 0, fit.height > 0 else { return nil }
        return CGPoint(x: fit.minX + (x + 0.5) / CGFloat(serverWidth) * fit.width,
                       y: fit.minY + (y + 0.5) / CGFloat(serverHeight) * fit.height)
    }

    /// Host canvas pixels per view point of finger travel at `zoom`.
    func hostPixelsPerPoint(viewSize: CGSize, zoom: CGFloat = 1) -> CGFloat {
        let fit = fittedRect(in: viewSize)
        guard fit.width > 0 else { return 1 }
        return CGFloat(serverWidth) / fit.width / max(zoom, 1)
    }

    /// Host scroll pixels (logical points: one press scrolls 1 px) per view
    /// point, so content under the fingers moves 1:1 (at any zoom).
    func scrollTicksPerPoint(viewSize: CGSize, zoom: CGFloat = 1) -> CGFloat {
        let fit = CompositeLayout.aspectFit(CGSize(width: serverWidth, height: serverHeight), in: viewSize)
        guard fit.width > 0 else { return 1 }
        return CGFloat(serverWidth) / max(pointScale, 1) / fit.width / max(zoom, 1)
    }

    // MARK: sending

    private func enqueue(_ message: Data, coalescable: Bool) {
        guard !closed else { return }
        if coalescable, let last = queue.last, last.coalescable {
            queue[queue.count - 1] = (message, true)
        } else {
            queue.append((message, coalescable))
        }
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
            self?.drainTask = nil
        }
    }

    private func drain() async {
        while !closed, !queue.isEmpty {
            let next = queue.removeFirst()
            do {
                try await send(next.message)
                sentCount += 1
            } catch {
                Log.input.debug("input send dropped: \(error)")
            }
        }
        if closed { queue.removeAll() }
    }
}

/// app.py on_scroll: the reference's wheel curve. Each wheel delta (GLFW
/// ticks; > 0 = wheel away / content down) is amplified by 12 (one press =
/// 1 px, ~12 px per notch) times a speed factor from the gap since the last
/// event, accumulated (fractions carry), the pending total capped at ±200
/// and at most 50 ticks emitted per event. Returns `scroll_event`'s dy
/// (< 0 = up), 0 while the motion is sub-tick.
struct WheelScroll {
    static let multiplier = 12.0      // _WHEEL_MULT
    private var accumulated = 0.0
    private var lastMilliseconds: Double

    init(lastMilliseconds: Double = 0) { self.lastMilliseconds = lastMilliseconds }

    mutating func ticks(wheelDelta dy: Double, atMilliseconds now: Double) -> Int {
        guard dy != 0 else { return 0 }
        let dt = now - lastMilliseconds
        lastMilliseconds = now
        let accel: Double = switch dt {
        case ..<25: 10
        case ..<50: 6
        case ..<100: 3.5
        case ..<200: 2
        case ..<350: 1.4
        default: 1
        }
        accumulated += -dy * Self.multiplier * accel
        return emit(&accumulated)
    }
}

/// Continuous (trackpad / two-finger touch) scrolling. Deviation from the
/// reference, whose only scroll source is GLFW's wheel callback: a trackpad
/// already delivers pixel-precise motion at display rate, and the wheel
/// curve's speed factor would multiply it ×10 at 120 Hz. Instead each view
/// point of finger travel becomes `ticksPerPoint` host pixels (content
/// follows the fingers), with the reference's carry, ±200 cap and 50-tick
/// per-event limit. `points` > 0 = fingers moved down = scroll up.
struct PixelScroll {
    private var accumulated = 0.0

    mutating func ticks(points: Double, ticksPerPoint: Double) -> Int {
        accumulated += -points * ticksPerPoint
        return emit(&accumulated)
    }
}

/// app.py on_scroll tail: cap the pending total, emit whole ticks (≤ 50),
/// carry the rest.
private func emit(_ accumulated: inout Double) -> Int {
    accumulated = max(-200, min(200, accumulated))
    let ticks = Int(accumulated)          // toward zero
    guard ticks != 0 else { return 0 }
    let out = max(-50, min(50, ticks))
    accumulated -= Double(out)
    return out
}
