import SwiftUI
import RAMPCore

/// Vhosty section: searchable list grouped into collapsible folders, add / edit sheet, delete confirmation,
/// hosts status, open actions, "move to group" and one-time "group by Sites folders".
///
/// A `List` with custom section headers (not `Table`): `Table` has no collapsible sections. Rows reproduce the
/// former table columns with fixed / flexible widths (`VhostColumns`). The list fills the available space —
/// nothing here reports a content-sized ideal height.
struct VhostsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: Vhost?
    @State private var newGroupIDs: Set<UUID>?
    @State private var newGroupName = ""
    @State private var autoGroupCount: Int?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let model = app.vhosts
        @Bindable var bindable = model
        VStack(spacing: 0) {
            HostsStatusBanner(model: model)
            if model.vhosts.isEmpty {
                ContentUnavailableView {
                    Label("Žiadne vhosty", systemImage: "globe")
                } description: {
                    Text("Pridajte projekt a RAMP ho sprístupní na vlastnej doméne.")
                } actions: {
                    Button("Pridať vhost") { model.startAdd() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                list(model)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.18), in: .capsule)
                    .overlay(Capsule().strokeBorder(.green.opacity(0.35)))
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.notice)
        .searchable(text: $bindable.search, placement: .toolbar, prompt: Text("Hľadať vhosty"))
        .searchFocused($searchFocused)
        .background {
            // ⌘F → focus the vhost search field.
            Button("Hľadať vhosty") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { autoGroupCount = model.autoGroupCount } label: {
                    Label("Zoskupiť podľa priečinkov v Sites", systemImage: "folder.badge.gearshape")
                }
                .help("Zoskupiť podľa priečinkov v Sites")
                .disabled(model.vhosts.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.startAdd() } label: {
                    Label("Pridať vhost", systemImage: "plus")
                }
                .help("Pridať vhost")
            }
        }
        .sheet(item: $bindable.editor) { draft in
            VhostEditorSheet(model: model, draft: draft)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { vhost in
            Button("Odstrániť", role: .destructive) { Task { await model.remove(vhost) } }
            Button("Zrušiť", role: .cancel) {}
        } message: { vhost in
            Text("Súbory projektu v \(vhost.docroot) sa NEVYMAŽÚ — odstráni sa len vhost z RAMP a záznam v /etc/hosts.")
        }
        .confirmationDialog("Zoskupiť podľa priečinkov v Sites?", isPresented: autoGroupBinding,
                            titleVisibility: .visible, presenting: autoGroupCount) { count in
            if count > 0 {
                Button("Zoskupiť") { Task { await model.autoGroup() } }
            }
            Button("Zrušiť", role: .cancel) {}
        } message: { count in
            if count > 0 {
                Text("Vhosty bez skupiny, ktorým sa doplní skupina podľa prvého priečinka v ~/Sites: \(count). Existujúce skupiny sa nezmenia.")
            } else {
                Text("Žiadny vhost bez skupiny nemá docroot vnorený v podpriečinku ~/Sites.")
            }
        }
        .alert("Nová skupina", isPresented: newGroupBinding) {
            TextField("Názov skupiny", text: $newGroupName)
            Button("Presunúť") {
                if let ids = newGroupIDs {
                    let name = newGroupName
                    Task { await model.move(ids, toGroup: name) }
                }
            }
            .disabled(!Self.isValidGroupName(newGroupName))
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Názov môže mať najviac \(Vhost.maxGroupLength) znakov.")
        }
        .task { await model.onAppear() }
    }

    private func list(_ model: VhostsModel) -> some View {
        let phpStorm = app.opener.isPhpStormAvailable
        let defaultBranch = model.defaultPHPBranch
        let sections = model.filteredSections
        let grouped = model.hasGroups
        func row(_ vhost: Vhost) -> some View {
            VhostListRow(vhost: vhost, model: model, defaultBranch: defaultBranch, phpStormAvailable: phpStorm,
                         onDelete: { pendingDelete = $0 })
        }
        return VStack(spacing: 0) {
            VhostColumnHeader(model: model)
            Divider()
            List(selection: $selection) {
                if grouped {
                    ForEach(sections) { section in
                        let expanded = model.isExpanded(section)
                        Section {
                            if expanded {
                                ForEach(section.vhosts) { row($0) }
                            }
                        } header: {
                            VhostGroupHeader(section: section, expanded: expanded) { model.toggleExpanded(section) }
                        }
                    }
                } else {
                    ForEach(sections.flatMap(\.vhosts)) { row($0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first, let vhost = model.vhosts.first(where: { $0.id == id }) {
                    VhostActions(vhost: vhost, model: model, phpStormAvailable: phpStorm,
                                 onDelete: { pendingDelete = $0 })
                    Divider()
                }
                if !ids.isEmpty {
                    moveMenu(ids, model: model)
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.startEdit(id: id) }
            }
        }
    }

    /// "Presunúť do skupiny ▸" — existing groups, new group, ungrouped. Acts on the whole selection.
    @ViewBuilder
    private func moveMenu(_ ids: Set<UUID>, model: VhostsModel) -> some View {
        let current = Set(model.vhosts.filter { ids.contains($0.id) }.map(\.group))
        Menu("Presunúť do skupiny") {
            ForEach(model.groups, id: \.self) { group in
                Button(group) { Task { await model.move(ids, toGroup: group) } }
                    .disabled(current == [group])
            }
            if !model.groups.isEmpty { Divider() }
            Button("Nová skupina…") {
                let first = model.vhosts.first { ids.contains($0.id) }
                newGroupName = first.flatMap { model.suggestedGroup(docroot: $0.docroot) } ?? ""
                newGroupIDs = ids
            }
            Button("Bez skupiny") { Task { await model.move(ids, toGroup: nil) } }
                .disabled(current == [nil])
        }
    }

    static func isValidGroupName(_ name: String) -> Bool {
        guard let group = Vhost.normalizeGroup(name) else { return false }
        return VhostValidator.groupProblem(group) == nil
    }

    private var deleteTitle: Text {
        if let vhost = pendingDelete {
            Text("Odstrániť vhost \(vhost.domain)?")
        } else {
            Text("Odstrániť vhost?")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var autoGroupBinding: Binding<Bool> {
        Binding(get: { autoGroupCount != nil }, set: { if !$0 { autoGroupCount = nil } })
    }

    private var newGroupBinding: Binding<Bool> {
        Binding(get: { newGroupIDs != nil }, set: { if !$0 { newGroupIDs = nil } })
    }
}
