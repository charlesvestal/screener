// Pure resize-feedback state machine (Task 21 UX): when the "Resizing…"
// toast + held-frame blur should be up, driven by SessionCoordinator from the
// 0x1d send (DisplayResizer.fire → requestDisplay) and the frame store's
// `isHoldingForNewStream` (VideoFrameStore: held until the new stream's first
// picture, or `resizeHoldLimit`). No SwiftUI/Metal dependency, so the
// transitions are covered without a session (ResizeFeedbackTests).
//
// Coalescing: a view can fire several view-size changes in a row (a Stage
// Manager drag, a rotation animation's intermediate frames) before the
// debounced 0x1d actually goes out, and the server may even answer a second
// 0x1d before the first's new stream arrives. Each `begin()` while already
// active just extends the session (the caller resets its timeout) instead of
// restarting it, so the toast fires once and the blur never flickers off and
// back on mid-burst.
import Foundation

struct ResizeFeedback: Equatable {
    private(set) var isActive = false

    /// A resize was requested (0x1d sent / the view-size debounce fired).
    /// Returns whether this is the start of a new burst (the caller should
    /// show the toast and start blurring) — false while one is already in
    /// flight, so the caller knows to only refresh its timeout.
    @discardableResult
    mutating func begin() -> Bool {
        defer { isActive = true }
        return !isActive
    }

    /// The held frame's new picture showed, or the timeout fired. A no-op if
    /// nothing was active (e.g. a second `end()` from both the observer and
    /// a race with the timeout).
    mutating func end() {
        isActive = false
    }
}
