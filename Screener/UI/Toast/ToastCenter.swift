// Session toasts: small Liquid Glass capsules that slide in from the top
// ("Copied to Mac ↗", "Muted", "Display: Sharper", "Reconnected", …).
//
// One toast is on screen at a time for `displayDuration` (1.6 s); then, after
// `gap` (the exit animation), the next queued one. Toasts share a `key` per
// subject (audio, display, clipboard-out, …) and coalesce on it:
//   - the toast on screen with the same key is updated in place and its
//     timer restarts (tapping Mute three times shows one toast, ending on
//     the final state);
//   - a queued toast with the same key is replaced where it stands;
//   - otherwise it queues, at most `maxQueued` deep (the oldest queued one
//     is dropped first: stale news).
// Every toast shown or updated is announced to VoiceOver.
//
// The timer is injected (KeyRepeater.Schedule) so tests drive it by hand.
import Observation
import SwiftUI
import UIKit

struct Toast: Identifiable, Equatable, Sendable {
    /// Changes on every show, so the view re-animates a replaced toast.
    var id: Int
    var key: String
    var text: String
    var systemImage: String?
}

@MainActor @Observable
final class ToastCenter {
    static let displayDuration: TimeInterval = 1.6
    static let gap: TimeInterval = 0.3
    static let maxQueued = 3

    private(set) var current: Toast?
    private(set) var queued: [Toast] = []

    @ObservationIgnored var announce: @MainActor (String) -> Void = ToastCenter.voiceOverAnnounce
    @ObservationIgnored private let schedule: KeyRepeater.Schedule
    @ObservationIgnored private var cancelTimer: (() -> Void)?
    @ObservationIgnored private var nextID = 0
    /// Between a dismissal and the next toast (the exit animation).
    @ObservationIgnored private var inGap = false

    init(schedule: @escaping KeyRepeater.Schedule = KeyRepeater.runLoopTimer) {
        self.schedule = schedule
    }

    func show(_ text: String, systemImage: String? = nil, key: String? = nil) {
        let key = key ?? text
        nextID += 1
        let toast = Toast(id: nextID, key: key, text: text, systemImage: systemImage)
        if current?.key == key {
            current = toast
            announce(text)
            startTimer()
        } else if let i = queued.firstIndex(where: { $0.key == key }) {
            queued[i] = toast
        } else if current == nil && !inGap {
            present(toast)
        } else {
            queued.append(toast)
            if queued.count > Self.maxQueued { queued.removeFirst(queued.count - Self.maxQueued) }
        }
    }

    /// Dismisses the toast on screen now (a tap on it); the queue goes on.
    func dismissCurrent() {
        guard current != nil else { return }
        cancelTimer?()
        cancelTimer = nil
        current = nil
        inGap = true
        cancelTimer = schedule(Self.gap) { [weak self] in self?.advance() }
    }

    /// Drops everything (the session view went away).
    func clear() {
        cancelTimer?()
        cancelTimer = nil
        current = nil
        queued = []
        inGap = false
    }

    private func present(_ toast: Toast) {
        current = toast
        announce(toast.text)
        startTimer()
    }

    private func startTimer() {
        cancelTimer?()
        cancelTimer = schedule(Self.displayDuration) { [weak self] in self?.dismissCurrent() }
    }

    private func advance() {
        cancelTimer = nil
        inGap = false
        guard !queued.isEmpty else { return }
        present(queued.removeFirst())
    }

    static func voiceOverAnnounce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// The toast on screen, at the top center, over the session.
struct ToastOverlay: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = center.current {
                ToastCapsule(toast: toast)
                    .id(toast.key)
                    .onTapGesture { center.dismissCurrent() }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 14)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.82),
                   value: center.current?.key)
    }
}

private struct ToastCapsule: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            if let image = toast.systemImage {
                Image(systemName: image).font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(toast.text).font(.subheadline.weight(.semibold))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .menuGlass(Capsule())
        .fixedSize()
        .animation(.easeInOut(duration: 0.15), value: toast.text)
        // Announced by ToastCenter; the capsule itself stays out of the way.
        .accessibilityHidden(true)
    }
}
