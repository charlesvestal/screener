import SwiftUI

/// About / Acknowledgements sheet (from the host list toolbar): the license
/// and the bundled THIRD_PARTY_NOTICES text (iShareScreen AGPL-3.0 origin,
/// BigInt MIT notice).
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    static var noticesText: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The third-party notices are missing from this build."
        }
        return text
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screener").font(.title2.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                    Text("Screener is free software under the GNU Affero General Public License v3.0.")
                    Divider()
                    Text("Acknowledgements").font(.headline)
                    Text(Self.noticesText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
