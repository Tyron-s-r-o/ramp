import AppKit
import SwiftUI
import RAMPCore

/// Vhosty: searchable list of enabled vhosts. Click → browser, ⌥-click → `optionClickTarget` (Finder / PhpStorm),
/// context menu offers all targets, Enter in the search field opens the first match in the browser.
struct MenuVhostList: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = filtered
        let grouped = app.vhosts.hasGroups
        let sections = VhostSection.make(matches)
        // Visual order (groups A–Z, ungrouped last) — Enter opens the first visible match.
        let ordered = grouped ? sections.flatMap(\.vhosts) : matches
        let visibleRows = grouped
            ? sections.reduce(0) { $0 + 1 + (isExpanded($1) ? $1.vhosts.count : 0) }
            : matches.count
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionTitle("Vhosty")
            TextField("Hľadať vhost", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($searchFocused)
                .onSubmit { if let first = ordered.first { app.vhosts.openInBrowser(first) } }
            if matches.isEmpty {
                Text(search.isEmpty ? "Žiadne zapnuté vhosty" : "Nič sa nenašlo")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if grouped {
                            ForEach(sections) { section in
                                let expanded = isExpanded(section)
                                MenuVhostGroupHeader(section: section, expanded: expanded) {
                                    app.vhosts.toggleExpanded(section)
                                }
                                if expanded {
                                    ForEach(section.vhosts) { MenuVhostRow(vhost: $0, defaultBranch: defaultBranch) }
                                }
                            }
                        } else {
                            ForEach(matches) { MenuVhostRow(vhost: $0, defaultBranch: defaultBranch) }
                        }
                    }
                }
                // ~12 rows visible, the rest scrolls (headers are shorter than rows, so the bound holds).
                .frame(maxHeight: 12 * 24)
                .fixedSize(horizontal: false, vertical: visibleRows <= 12)
            }
        }
        .onAppear { searchFocused = true }
    }

    /// Shares the collapse state with the Vhosty window; a search here expands every group.
    private func isExpanded(_ section: VhostSection) -> Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !app.vhosts.collapsedGroups.contains(section.id)
    }

    private var defaultBranch: String? { app.vhosts.defaultPHPBranch }

    private var filtered: [Vhost] {
        let enabled = app.vhosts.vhosts.filter(\.enabled)
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return enabled }
        return enabled.filter { v in
            ([v.domain, v.group ?? ""] + v.aliases).contains { $0.localizedStandardContains(query) }
        }
    }
}

/// Compact collapsible group header (chevron, name, count).
private struct MenuVhostGroupHeader: View {
    let section: VhostSection
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Group {
                    if let group = section.group { Text(verbatim: group) } else { Text("Bez skupiny") }
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                Text(verbatim: "\(section.vhosts.count)").font(.caption2.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? Text("Rozbalené") : Text("Zbalené"))
    }
}

private struct MenuVhostRow: View {
    @Environment(AppModel.self) private var app
    let vhost: Vhost
    let defaultBranch: String?
    @State private var hovering = false

    var body: some View {
        let vhosts = app.vhosts
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                vhosts.open(vhost, target: app.opener.optionClickTarget)
            } else {
                vhosts.openInBrowser(vhost)
            }
        } label: {
            HStack {
                Text(verbatim: vhost.domain).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let branch = vhost.phpBranch ?? defaultBranch {
                    Text(verbatim: "PHP \(branch)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(.rect)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("Klik: prehliadač · ⌥-klik: priečinok projektu"))
        .contextMenu {
            Button("Otvoriť v prehliadači") { vhosts.openInBrowser(vhost) }
            Button("Otvoriť vo Finderi") { vhosts.open(vhost, target: .finder) }
            if app.opener.isPhpStormAvailable {
                Button("Otvoriť v PhpStorme") { vhosts.open(vhost, target: .phpStorm) }
            }
        }
    }
}
