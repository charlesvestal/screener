// Ported in part from iShareScreen src/isharescreen/proxy/session.py
// (clipboard enable/prime at step 9b, the 0x14 cmd=2 → 0x0b fetch and 0x1f
// handling in _handle_tcp_msg, _handle_clipboard_send,
// _spawn_outbound_clipboard_poller) and proxy/input.py (send_clipboard_enable,
// send_clipboard_fetch, cut_text) (AGPL-3.0).
//
// Two-way text clipboard for one session at a time (SessionCoordinator calls
// start / handle / stop / appBecameActive).
//
//   start:   0x15 AutoPasteboard (always — the daemon answers 0x0b only after
//            it), then, in Automatic mode, either a prime 0x0b fetch (as the
//            reference does) or, if the iPad pasteboard changed while we were
//            away (changeCount moved), the iPad's text instead.
//   Mac→iPad: 0x14 cmd=2 → 0x0b fetch → complete 0x1f → inflate + parse off
//            the main actor → UIPasteboard.general.string, unless the iPad
//            already holds exactly that text (echo guard).
//   iPad→Mac: on UIPasteboard.changedNotification while connected and when
//            the scene becomes active, if `changeCount` moved and the
//            pasteboard `hasStrings`, read the text and send it as 0x1f
//            (cut_text → build_clipboard_send, never 0x06), unless the Mac
//            already has exactly that text.
//
// The iOS paste prompt: reading another app's pasteboard text
// programmatically shows "Allow Paste" (iOS 16+); `changeCount` and
// `hasStrings` never do, and writing never does. So a read happens at most
// once per new copy, and only for text. Choosing "Allow" in Settings › Screener
// › Paste from Other Apps silences it. Manual mode (the menu's Clipboard
// toggle) never reads or writes on its own: "Send Clipboard" (a user tap, so
// the prompt is expected) and "Get Clipboard" do it on demand.
//
// Privacy: clipboard contents are never logged — only sizes.
import Foundation
import UIKit

/// The pasteboard calls the bridge makes (a fake in tests).
@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    /// Reading may show iOS's paste prompt; nil if refused or no text.
    var string: String? { get set }
}

@MainActor
final class SystemPasteboard: PasteboardAccess {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }
    var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }
}

/// A completed clipboard transfer (for the session's toasts).
enum ClipboardActivity: Equatable, Sendable {
    /// iPad text went out to the Mac.
    case sentToMac
    /// The Mac's text was written to the iPad clipboard.
    case receivedFromMac
}

@MainActor
final class ClipboardBridge {
    typealias Send = @Sendable (Data) async throws -> Void

    /// Called on the main actor after each completed transfer (never with contents).
    var onActivity: ((ClipboardActivity) -> Void)?

    /// Read on every decision so the menu toggle applies at once.
    var mode: () -> ClipboardSyncMode = { ClipboardSyncMode.current }
    /// A session is attached.
    var isActive: Bool { send != nil }
    /// Messages handed to the session (tests).
    private(set) var sentCount = 0

    private let pasteboard: PasteboardAccess
    private var state = ClipboardSyncState()
    private var reassembler = ClipboardReassembler()
    private var send: Send?
    /// Bumped per session: late decodes / sends of an old session are dropped.
    private var epoch = 0
    /// Manual mode applies an inbound 0x1f only after "Get Clipboard".
    private var fetchRequested = false
    /// Our own write is in progress (its changedNotification is ours).
    private var writing = false
    /// Every send goes through this chain, so wire order = call order.
    private var chain: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(pasteboard: PasteboardAccess = SystemPasteboard(), observeChanges: Bool = true) {
        self.pasteboard = pasteboard
        guard observeChanges else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pasteboardChanged() }
        }
    }

    // MARK: session

    /// The session's stream started: enable auto-pasteboard and sync once.
    func start(send: @escaping Send) {
        epoch += 1
        self.send = send
        reassembler.reset()
        fetchRequested = false
        let first = state.sessionStarted(changeCount: pasteboard.changeCount)
        transmit(Clipboard.autoPasteboard())
        guard mode() == .automatic else {
            Log.app.info("clipboard: auto-pasteboard enabled (manual sync)")
            return
        }
        switch first {
        case .fetchMac:
            Log.app.info("clipboard: auto-pasteboard enabled, priming from the Mac")
            transmit(Clipboard.request())
        case .pushLocal:
            Log.app.info("clipboard: auto-pasteboard enabled, iPad clipboard changed while away")
            checkLocal()
        }
    }

    /// The session ended: nothing more goes out for it.
    func stop() {
        epoch += 1
        send = nil
        reassembler.reset()
        fetchRequested = false
        chain = nil
    }

    /// The control channel's clipboard events (0x14 MiscStatus, 0x1f).
    func handle(_ event: ServerEvent) {
        guard isActive else { return }
        switch event {
        case .miscStatus(cmd: 2):
            guard mode() == .automatic else { return }
            Log.app.info("clipboard: Mac clipboard changed; fetching")
            transmit(Clipboard.request())
        case .clipboard(let header, let chunk):
            switch reassembler.feed(header: header, chunk: chunk) {
            case nil:
                break
            case .oversized(let n):
                Log.app.error("clipboard recv: \(n) compressed bytes, over the \(Clipboard.maxCompressedBytes) limit; dropped")
            case .complete(let h, let payload):
                decode(h, payload)
            }
        default:
            break
        }
    }

    /// The scene became active again.
    func appBecameActive() {
        guard isActive, mode() == .automatic else { return }
        checkLocal()
    }

    // MARK: menu actions

    /// "Get Clipboard": fetch the Mac's clipboard now (any mode).
    func fetchFromMac() {
        guard isActive else { return }
        fetchRequested = true
        Log.app.info("clipboard: fetch requested")
        transmit(Clipboard.request())
    }

    /// "Send Clipboard": send the iPad's text now (any mode). False if there
    /// is no text (or the user refused the paste prompt).
    @discardableResult
    func sendToMac() -> Bool {
        guard isActive else { return false }
        let c = pasteboard.changeCount
        let text = pasteboard.hasStrings ? pasteboard.string : nil
        guard let out = state.localRead(text, changeCount: c, force: true) else {
            Log.app.info("clipboard send: no text on the iPad clipboard")
            return false
        }
        transmit(text: out)
        return true
    }

    // MARK: internals

    private func pasteboardChanged() {
        guard !writing, isActive, mode() == .automatic else { return }
        checkLocal()
    }

    /// Reads and sends the iPad text only if `changeCount` moved (see header).
    private func checkLocal() {
        let c = pasteboard.changeCount
        guard state.localChanged(changeCount: c) else { return }
        guard pasteboard.hasStrings else {
            state.noteLocal(changeCount: c)
            return
        }
        if let out = state.localRead(pasteboard.string, changeCount: c) {
            transmit(text: out)
        }
    }

    private func decode(_ header: ClipboardSendHeader, _ payload: Data) {
        let e = epoch
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try Clipboard.decodeText(header: header, payload: payload) }
            await self?.received(result, epoch: e)
        }
    }

    private func received(_ result: Result<String?, Error>, epoch e: Int) {
        guard e == epoch, isActive else { return }
        // A Get Clipboard request is answered by this message, whatever it holds.
        let requested = fetchRequested
        fetchRequested = false
        let text: String
        switch result {
        case .failure(ClipboardError.tooLarge(let n)):
            Log.app.error("clipboard recv: \(n) bytes, over the limit; not copied to the iPad")
            return
        case .failure(let error):
            Log.app.error("clipboard recv: undecodable payload (\(error))")
            return
        case .success(nil):
            return
        case .success(let t?):
            text = t
        }
        guard mode() == .automatic || requested else { return }
        guard state.remoteText(text, changeCount: pasteboard.changeCount) else {
            Log.app.info("clipboard recv: \(text.count) chars, already on the iPad")
            return
        }
        writing = true
        pasteboard.string = text
        writing = false
        state.didWriteLocal(text, changeCount: pasteboard.changeCount)
        Log.app.info("clipboard recv: \(text.count) chars → iPad clipboard")
        onActivity?(.receivedFromMac)
    }

    /// Builds the 0x1f (deflate off the main actor) and queues it.
    private func transmit(text: String) {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
        let chars = lf.count
        enqueue { try await Task.detached(priority: .userInitiated) { try Clipboard.send(text: lf) }.value } done: { [weak self] in
            Log.app.info("clipboard send: \(chars) chars")
            self?.onActivity?(.sentToMac)
        }
    }

    private func transmit(_ message: Data) {
        enqueue { message } done: {}
    }

    private func enqueue(_ build: @escaping @Sendable () async throws -> Data,
                         done: @escaping @MainActor () -> Void) {
        guard let send else { return }
        let previous = chain
        let e = epoch
        chain = Task { [weak self] in
            await previous?.value
            guard let self, e == self.epoch else { return }
            do {
                let message = try await build()
                guard e == self.epoch else { return }
                try await send(message)
                self.sentCount += 1
                done()
            } catch ClipboardError.tooLarge(let n) {
                Log.app.error("clipboard send skipped: \(n) bytes is over the limit")
            } catch {
                Log.app.debug("clipboard send failed: \(error)")
            }
        }
    }

    /// Waits for queued sends (tests).
    func flush() async {
        while let c = chain {
            await c.value
            if chain == c { break }
        }
    }
}
