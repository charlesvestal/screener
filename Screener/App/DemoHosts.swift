#if DEBUG
import SwiftData
import UIKit

/// DEBUG launch argument `-demoHosts YES`: synthetic saved and discovered
/// Macs with drawn thumbnails, for screenshots of the host list (no real
/// Bonjour browsing, no connections). `-demoHosts empty` shows the empty state.
@MainActor
enum DemoHosts {
    static var mode: String? { UserDefaults.standard.string(forKey: "demoHosts") }

    static func seed(context: ModelContext, thumbnails: HostThumbnails, browser: BonjourBrowser) async {
        guard let mode else { return }
        for h in (try? context.fetch(FetchDescriptor<SavedHost>())) ?? [] { context.delete(h) }
        guard mode != "empty" else {
            browser.showDemo([])
            try? context.save()
            return
        }
        let now = Date.now
        let hosts: [(String, String, String?, Date?, Bool, UIColor?)] = [
            ("Studio", "192.168.1.20", "Mac13,1", now.addingTimeInterval(-600), true, .systemIndigo),
            ("Alex’s MacBook Pro", "192.168.1.31", "MacBookPro18,3", now.addingTimeInterval(-86_400 * 2), false, .systemOrange),
            ("Living Room mini", "192.168.1.44", "Macmini9,1", now.addingTimeInterval(-86_400 * 9), true, nil),
            ("Office iMac", "office-imac.local", "iMac21,1", nil, false, nil),
        ]
        var online: [String] = []
        for (i, (name, address, model, last, isOnline, color)) in hosts.enumerated() {
            let h = SavedHost(name: name, host: address, username: "alex", lastConnected: last, sortOrder: i,
                              bonjourName: name)
            h.macModel = model
            context.insert(h)
            if isOnline { online.append(name) }
            if let color { await thumbnails.save(desktop(tint: color), for: h.id) }
        }
        try? context.save()
        browser.showDemo(online + ["Mac Pro"])
    }

    /// A drawn "desktop": wallpaper, menu bar, two windows and a dock.
    private static func desktop(tint: UIColor) -> UIImage {
        let size = CGSize(width: 1280, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [tint.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.25).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 28))
            for (rect, alpha) in [(CGRect(x: 120, y: 110, width: 620, height: 420), 0.92),
                                  (CGRect(x: 560, y: 250, width: 560, height: 380), 0.97)] {
                UIColor.white.withAlphaComponent(alpha).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 18).fill()
                UIColor.systemGray4.setFill()
                UIBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44),
                             byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 18, height: 18)).fill()
                for (j, c) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    c.setFill()
                    UIBezierPath(ovalIn: CGRect(x: rect.minX + 18 + CGFloat(j) * 22, y: rect.minY + 15, width: 14, height: 14)).fill()
                }
                UIColor.systemGray5.setFill()
                for row in 0..<5 {
                    cg.fill(CGRect(x: rect.minX + 30, y: rect.minY + 74 + CGFloat(row) * 44,
                                   width: rect.width * (row.isMultiple(of: 2) ? 0.7 : 0.5), height: 18))
                }
            }
            UIColor.white.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: CGRect(x: 340, y: 712, width: 600, height: 70), cornerRadius: 22).fill()
        }
    }
}
#endif
