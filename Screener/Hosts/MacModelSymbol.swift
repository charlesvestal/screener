// The SF Symbol for a Mac model identifier (sysctl hw.model, sent by the
// server in DeviceInfo 0x456, e.g. "Macmini9,1"). Older Macs carry the
// family in the identifier; Apple silicon Macs since 2022 are "MacNN,M", so
// those are looked up in a table (unknown ones get the generic symbol).
import Foundation

enum MacModelSymbol {
    static let generic = "desktopcomputer"
    static let laptop = "macbook"
    static let mini = "macmini"
    static let studio = "macstudio"
    static let pro = "macpro.gen3"
    static let proCylinder = "macpro.gen2"
    static let iMac = "desktopcomputer"

    /// "MacNN,M" identifiers (Apple silicon, 2022 →).
    static let appleSilicon: [String: String] = [
        // Mac Studio
        "Mac13,1": studio, "Mac13,2": studio, "Mac14,13": studio, "Mac14,14": studio,
        "Mac15,14": studio, "Mac16,9": studio,
        // Mac mini
        "Mac14,3": mini, "Mac14,12": mini, "Mac16,10": mini, "Mac16,11": mini,
        // Mac Pro
        "Mac14,8": pro,
        // iMac
        "Mac15,4": iMac, "Mac15,5": iMac, "Mac16,2": iMac, "Mac16,3": iMac,
        // MacBook Air / Pro
        "Mac14,2": laptop, "Mac14,15": laptop, "Mac15,12": laptop, "Mac15,13": laptop,
        "Mac16,12": laptop, "Mac16,13": laptop,
        "Mac14,5": laptop, "Mac14,6": laptop, "Mac14,7": laptop, "Mac14,9": laptop, "Mac14,10": laptop,
        "Mac15,3": laptop, "Mac15,6": laptop, "Mac15,7": laptop, "Mac15,8": laptop, "Mac15,9": laptop,
        "Mac15,10": laptop, "Mac15,11": laptop,
        "Mac16,1": laptop, "Mac16,5": laptop, "Mac16,6": laptop, "Mac16,7": laptop, "Mac16,8": laptop,
        "Mac17,2": laptop,
    ]

    static func symbol(for model: String?) -> String {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return generic }
        if let s = appleSilicon[raw] { return s }
        let m = raw.lowercased()
        if m.hasPrefix("macmini") { return mini }
        if m.hasPrefix("macbook") { return laptop }            // MacBook, MacBookAir, MacBookPro
        if m.hasPrefix("imac") { return iMac }                 // iMac, iMacPro
        if m.hasPrefix("macpro") {
            // MacPro6,1 is the cylinder; 7,1 the tower (as is Mac14,8 above).
            return m.hasPrefix("macpro6,") ? proCylinder : pro
        }
        return generic
    }

    /// A readable family name for accessibility ("Mac mini"), nil if unknown.
    static func family(for model: String?) -> String? {
        guard model?.isEmpty == false else { return nil }
        switch symbol(for: model) {
        case mini: return "Mac mini"
        case studio: return "Mac Studio"
        case pro, proCylinder: return "Mac Pro"
        case laptop: return "MacBook"
        default:
            return model!.lowercased().hasPrefix("imac") || ["Mac15,4", "Mac15,5", "Mac16,2", "Mac16,3"].contains(model!)
                ? "iMac" : nil
        }
    }
}
