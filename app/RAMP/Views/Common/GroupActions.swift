import SwiftUI

/// Right-click menu of a list group header (Vhosty, FTP): add into the group, rename, ungroup, collapse.
struct GroupHeaderMenu: View {
    /// nil = the "Bez skupiny" section (it can't be renamed or dissolved).
    let group: String?
    let expanded: Bool
    let addTitle: LocalizedStringKey
    let add: () -> Void
    let rename: () -> Void
    let ungroup: () -> Void
    let toggle: () -> Void

    var body: some View {
        Button(action: add) { Label(addTitle, systemImage: "plus") }
        if group != nil {
            Button(action: rename) { Label("Premenovať skupinu…", systemImage: "pencil") }
            Button(action: ungroup) { Label("Zrušiť skupinu", systemImage: "folder.badge.minus") }
        }
        Divider()
        Button(action: toggle) {
            Label(expanded ? "Zbaliť" : "Rozbaliť", systemImage: expanded ? "chevron.up" : "chevron.down")
        }
    }
}

/// State of the "Premenovať skupinu" prompt: the group being renamed and the edited name (prefilled with the old
/// one, so confirming without typing changes nothing).
struct GroupRename: Equatable {
    var old: String
    var name: String
    init(_ group: String) { old = group; name = group }
}

/// "Premenovať skupinu" prompt; an empty name dissolves the group (items move to "Bez skupiny").
private struct GroupRenameAlert: ViewModifier {
    @Binding var rename: GroupRename?
    let onRename: (_ old: String, _ new: String) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Premenovať skupinu", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Názov skupiny", text: Binding(get: { rename?.name ?? "" }, set: { rename?.name = $0 }))
                Button("Premenovať") {
                    if let r = rename, r.name != r.old { onRename(r.old, r.name) }
                    rename = nil
                }
                Button("Zrušiť", role: .cancel) { rename = nil }
            } message: {
                Text("Ak zadáte názov existujúcej skupiny, skupiny sa zlúčia. Prázdny názov skupinu zruší.")
            }
    }
}

extension View {
    func groupRenameAlert(_ rename: Binding<GroupRename?>,
                          onRename: @escaping (_ old: String, _ new: String) -> Void) -> some View {
        modifier(GroupRenameAlert(rename: rename, onRename: onRename))
    }
}
