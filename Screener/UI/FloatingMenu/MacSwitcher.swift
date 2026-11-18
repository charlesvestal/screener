// The control menu's "Switch Mac" tile: a compact list of the saved Macs
// (online dot from Bonjour, the current one marked). Picking another one
// ends this session cleanly and connects to it (HostConnector.switchSession).
import SwiftUI

struct MacSwitchOption: Identifiable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let reachability: HostReachability
    let isCurrent: Bool
}

/// What the session offers for switching Macs (built by HostListView).
struct MacSwitcher {
    var macs: [MacSwitchOption]
    /// Switch to the saved Mac with this id.
    var select: (UUID) -> Void
    /// The list is open (true) / closed: Bonjour browses only while it is,
    /// for the online dots.
    var listShown: (Bool) -> Void = { _ in }
}

struct SwitchMacTile: View {
    let switcher: MacSwitcher
    /// Closes the control panel after a pick.
    var picked: () -> Void = {}
    @State private var showList = false

    var body: some View {
        Button { showList = true } label: {
            TileLabel(title: "Switch Mac", image: "arrow.left.arrow.right.square", selected: showList,
                      destructive: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch Mac")
        .accessibilityHint("Ends this session and connects to another saved Mac.")
        .popover(isPresented: $showList) {
            MacSwitcherList(macs: switcher.macs) { id in
                showList = false
                picked()
                switcher.select(id)
            }
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showList) { _, shown in switcher.listShown(shown) }
        .onDisappear { if showList { switcher.listShown(false) } }
    }
}

private struct MacSwitcherList: View {
    let macs: [MacSwitchOption]
    let pick: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switch Mac").font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(macs) { mac in row(mac) }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 300)
    }

    private func row(_ mac: MacSwitchOption) -> some View {
        Button { if !mac.isCurrent { pick(mac.id) } } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(mac.reachability.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mac.name).font(.body).lineLimit(1)
                    Text(mac.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if mac.isCurrent {
                    Text("Current").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mac.isCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mac.name)
        .accessibilityValue([mac.isCurrent ? "Current" : nil, mac.reachability.accessibilityLabel]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(mac.isCurrent ? .isSelected : [])
    }
}
