// Pointer lock with a hardware mouse / trackpad (Task 22).
//
// iPadOS asks the window's root view controller — or the full-screen
// controller presented over it (the session is a SwiftUI fullScreenCover) —
// for `prefersPointerLocked`; those are SwiftUI hosting controllers, which
// offer no such hook. So each of their classes gets a `prefersPointerLocked`
// getter (added once per class with the runtime) that answers true for the
// controller whose view holds the RemoteInputView wanting the lock, and
// falls back to the original answer otherwise. The system only grants the lock to a
// full-screen scene (not Split View / Slide Over / a Stage Manager window);
// UIPointerLockState.didChangeNotification reports the outcome.
//
// While locked the system pointer is gone and stops producing hover and
// pointer touches, so GCMouse supplies relative motion, buttons and scroll
// (RemoteInputView's pointer-lock section).
import GameController
import ObjectiveC
import UIKit

@MainActor
enum PointerLock {
    /// The input view that wants the lock, by window.
    private static var requests: [ObjectIdentifier: WeakInputView] = [:]
    private static var patched: Set<ObjectIdentifier> = []

    private struct WeakInputView { weak var view: RemoteInputView? }

    /// Pointer lock is offered on this platform (not on a Mac: there the
    /// Mac's own pointer drives the session through hover and clicks).
    static let isAvailable = AdaptiveLayout.supportsPointerLock(platform: .current)

    /// Is a mouse or trackpad connected (GameController's view)?
    static var mouseConnected: Bool { !GCMouse.mice().isEmpty }

    /// `view` wants (or no longer wants) the pointer locked in its window.
    static func setWanted(_ wanted: Bool, by view: RemoteInputView) {
        guard let window = view.window else { return }
        let key = ObjectIdentifier(window)
        let before = requests[key]?.view === view
        if wanted {
            for vc in controllers(of: window) { patch(type(of: vc)) }
            requests[key] = WeakInputView(view: view)
        } else if before {
            requests[key] = nil
        }
        if wanted != before { update(window) }
    }

    /// The view left its window: drop its request there.
    static func withdraw(_ view: RemoteInputView, from window: UIWindow?) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        guard requests[key]?.view === view || requests[key]?.view == nil else { return }
        requests[key] = nil
        update(window)
    }

    /// The window's root controller and every controller presented over it.
    private static func controllers(of window: UIWindow) -> [UIViewController] {
        var out: [UIViewController] = []
        var vc = window.rootViewController
        while let c = vc {
            out.append(c)
            vc = c.presentedViewController
        }
        return out
    }

    private static func update(_ window: UIWindow) {
        for vc in controllers(of: window) { vc.setNeedsUpdateOfPrefersPointerLocked() }
    }

    fileprivate static func wanted(by controller: UIViewController) -> Bool {
        guard let window = controller.viewIfLoaded?.window,
              let view = requests[ObjectIdentifier(window)]?.view, view.window === window,
              controller === window.rootViewController || controller.presentingViewController != nil
        else { return false }
        return view.isDescendant(of: controller.view)
    }

    /// Gives `cls` its own prefersPointerLocked getter consulting `wanted(by:)`.
    private static func patch(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard !patched.contains(id) else { return }
        patched.insert(id)
        let sel = #selector(getter: UIViewController.prefersPointerLocked)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> Bool = { obj in
            let wanted = MainActor.assumeIsolated { () -> Bool in
                guard let vc = obj as? UIViewController else { return false }
                return PointerLock.wanted(by: vc)
            }
            return wanted || original(obj, sel)
        }
        let imp = imp_implementationWithBlock(block)
        // Added on the class itself (its superclass's getter stays as is);
        // replaced if the class already defines one.
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }
}
