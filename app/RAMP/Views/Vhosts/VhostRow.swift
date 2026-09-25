import SwiftUI
import RAMPCore

/// Domain cell: primary name + aliases in secondary text.
struct VhostDomainCell: View {
    let vhost: Vhost

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: vhost.domain)
                .foregroundStyle(vhost.enabled ? .primary : .secondary)
            if !vhost.aliases.isEmpty {
                Text(verbatim: vhost.aliases.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: vhost.aliases.joined(separator: "\n")))
            }
        }
    }
}

/// Docroot cell: middle-truncated, full path as tooltip, red when the folder is missing.
struct VhostDocrootCell: View {
    let docroot: String
    let missing: Bool
    /// Shortened form for the list (full path stays in the tooltip).
    var display: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel(Text("Priečinok neexistuje"))
            }
            Text(verbatim: display ?? docroot)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(missing ? .red : .primary)
        .help(missing ? Text("Priečinok neexistuje: \(docroot)") : Text(verbatim: docroot))
    }
}

/// Open / edit / delete actions — shared by the context menu and the trailing buttons.
struct VhostActions: View {
    let vhost: Vhost
    let model: VhostsModel
    let phpStormAvailable: Bool
    let onDelete: (Vhost) -> Void
    var compact = false

    var body: some View {
        Button { model.openInBrowser(vhost) } label: {
            Label("Otvoriť v prehliadači", systemImage: "safari")
        }
        .help("Otvoriť v prehliadači")
        Button { model.open(vhost, target: .finder) } label: {
            Label("Zobraziť vo Finderi", systemImage: "folder")
        }
        .help("Zobraziť vo Finderi")
        if phpStormAvailable {
            Button { model.open(vhost, target: .phpStorm) } label: {
                Label("Otvoriť v PhpStorme", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Otvoriť v PhpStorme")
        }
        if !compact {
            Divider()
            Button { model.startEdit(vhost) } label: {
                Label("Upraviť…", systemImage: "pencil")
            }
            Button(role: .destructive) { onDelete(vhost) } label: {
                Label("Odstrániť…", systemImage: "trash")
            }
        }
    }
}

/// Column geometry shared by the list header and the rows (replaces the former `Table` columns).
enum VhostColumns {
    static let spacing: CGFloat = 10
    static let enabled: CGFloat = 60
    static let domainMin: CGFloat = 160
    static let php: CGFloat = 110
    static let docrootMin: CGFloat = 160
    static let actions: CGFloat = 180
    /// Leading/trailing inset of the header so its titles line up with the `.inset` list rows.
    static let headerInset: CGFloat = 20
}

/// Non-scrolling column titles above the grouped list.
struct VhostColumnHeader: View {
    @Bindable var model: VhostsModel

    var body: some View {
        HStack(spacing: VhostColumns.spacing) {
            Text("Doména").frame(minWidth: VhostColumns.domainMin, maxWidth: .infinity, alignment: .leading)
            phpFilterMenu.frame(width: VhostColumns.php, alignment: .leading)
            Text(verbatim: "Docroot").frame(minWidth: VhostColumns.docrootMin, maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: VhostColumns.actions, height: 1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, VhostColumns.headerInset)
        .padding(.vertical, 5)
    }

    /// Click "PHP" → pick a branch to show only its vhosts.
    private var phpFilterMenu: some View {
        Menu {
            Picker(selection: $model.phpFilter) {
                Text("Všetky verzie").tag(String?.none)
                ForEach(model.phpBranchesInUse, id: \.branch) { item in
                    Text(verbatim: "PHP \(item.branch) (\(item.count))").tag(Optional(item.branch))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: model.phpFilter.map { "PHP \($0)" } ?? "PHP")
                Image(systemName: model.phpFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .imageScale(.small)
            }
            .foregroundStyle(model.phpFilter == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filtrovať podľa verzie PHP")
    }
}

/// One vhost in the grouped list: domain + aliases, PHP, docroot, trailing actions + enable switch.
struct VhostListRow: View {
    let vhost: Vhost
    let model: VhostsModel
    let defaultBranch: String?
    let phpStormAvailable: Bool
    let onDelete: (Vhost) -> Void

    var body: some View {
        HStack(spacing: VhostColumns.spacing) {
            VhostDomainCell(vhost: vhost)
                .frame(minWidth: VhostColumns.domainMin, maxWidth: .infinity, alignment: .leading)
            php.frame(width: VhostColumns.php, alignment: .leading)
            VhostDocrootCell(docroot: vhost.docroot, missing: model.missingDocroots.contains(vhost.id),
                             display: model.displayDocroot(vhost.docroot))
                .frame(minWidth: VhostColumns.docrootMin, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                VhostActions(vhost: vhost, model: model, phpStormAvailable: phpStormAvailable,
                             onDelete: onDelete, compact: true)
                Button { model.startEdit(vhost) } label: {
                    Label("Upraviť…", systemImage: "pencil")
                }
                .help("Upraviť…")
                Button { onDelete(vhost) } label: {
                    Label("Odstrániť…", systemImage: "trash")
                }
                .help("Odstrániť…")
                Toggle("Zapnutý", isOn: Binding(
                    get: { vhost.enabled },
                    set: { value in Task { await model.setEnabled(vhost, value) } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(model.busy.contains(vhost.id))
                    .help(vhost.enabled ? Text("Vypnúť vhost") : Text("Zapnúť vhost"))
                    .padding(.leading, 6)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: VhostColumns.actions, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.vertical, 5)
    }

    @ViewBuilder private var php: some View {
        if let branch = vhost.phpBranch {
            Text(verbatim: branch)
        } else if let defaultBranch {
            Text("predvolená (\(defaultBranch))").foregroundStyle(.secondary)
        } else {
            Text("predvolená").foregroundStyle(.secondary)
        }
    }
}

/// Collapsible group header: chevron, name ("Bez skupiny" for ungrouped), vhost count.
struct VhostGroupHeader: View {
    let section: VhostSection
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: section.group == nil ? "tray" : "folder")
                    .foregroundStyle(.secondary)
                title
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(section.vhosts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: section.group ?? String(localized: "Bez skupiny")))
        .accessibilityValue(expanded ? Text("Rozbalené") : Text("Zbalené"))
        .accessibilityHint(Text("Rozbaliť alebo zbaliť skupinu"))
    }

    @ViewBuilder private var title: some View {
        if let group = section.group {
            Text(verbatim: group)
        } else {
            Text("Bez skupiny")
        }
    }
}
