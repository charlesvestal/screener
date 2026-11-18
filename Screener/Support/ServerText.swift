// Text the Mac (or anything pretending to be it) sends us — the RFB refusal
// reason, the auth rejection reason, the session-select console user name,
// the DeviceInfo model, SRP options — is attacker-controlled. Before it
// reaches the log or the UI it goes through `ServerText.sanitize`
// (security review L3): control and invisible formatting characters (incl.
// newlines that could forge log lines and bidi overrides that could reorder
// what the user reads) become spaces, runs of whitespace collapse, and the
// result is capped. The UI shows such text only labelled as coming from the
// Mac (`ServerText.labelled`).
import Foundation

enum ServerText {
    static let defaultMaxLength = 200

    static func sanitize(_ s: String) -> String { sanitize(s, maxLength: defaultMaxLength) }

    static func sanitize(_ s: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in s.unicodeScalars {
            let bad = scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
                || scalar.value == 0xFFFD
            let space = bad || scalar.properties.isWhitespace
            if space {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        var text = String(out)
        while text.hasSuffix(" ") { text.removeLast() }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    /// "Message from the Mac: “…”" for a sanitized, non-empty `s`; nil otherwise.
    static func labelled(_ s: String?) -> String? {
        guard let s else { return nil }
        let clean = sanitize(s)
        return clean.isEmpty ? nil : "Message from the Mac: “\(clean)”"
    }
}
