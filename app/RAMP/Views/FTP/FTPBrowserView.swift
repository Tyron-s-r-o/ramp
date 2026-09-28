import AppKit
import SwiftUI
import RAMPCore

/// Browser of the connected site: header (site + disconnect), path bar (breadcrumb, up, refresh, editable
/// path), the file table (drag & drop both ways) and the collapsible transfers panel at the bottom.
struct FTPBrowserView: View {
    let model: RemoteModel
    @Bindable var browser: RemoteBrowserModel
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var pendingDelete: [RemoteItem]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch browser.state {
            case .preparing, .connecting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Pripájam sa k \(browser.site.host)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failed(message)
            case .connected:
                FTPPathBar(browser: browser)
                Divider()
                if let error = browser.error {
                    inlineError(error)
                    Divider()
                }
                table
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                if !browser.jobs.isEmpty {
                    FTPTransfersPanel(browser: browser)
                }
            }
        }
        .alert("Premenovať", isPresented: renameBinding, presenting: renaming) { item in
            TextField("Nový názov", text: $renameText)
            Button("Premenovať") { Task { await browser.rename(item, to: renameText) } }
                .disabled(RemoteBrowserModel.nameProblem(renameText))
            Button("Zrušiť", role: .cancel) {}
        } message: { item in
            Text(verbatim: item.path)
        }
        .alert("Nový priečinok", isPresented: $creatingFolder) {
            TextField("Názov priečinka", text: $folderName)
            Button("Vytvoriť") { Task { await browser.createFolder(named: folderName) } }
                .disabled(RemoteBrowserModel.nameProblem(folderName))
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text(verbatim: browser.path)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { items in
            Button("Zmazať", role: .destructive) { browser.enqueueDelete(items) }
            Button("Zrušiť", role: .cancel) {}
        } message: { items in
            if items.contains(where: { $0.kind == .directory }) {
                Text("Priečinky sa zmažú aj s celým obsahom. Na serveri to nejde vrátiť späť.")
            } else {
                Text("Na serveri to nejde vrátiť späť.")
            }
        }
        .confirmationDialog(uploadTitle, isPresented: uploadBinding, titleVisibility: .visible,
                            presenting: browser.pendingUpload) { pending in
            Button("Prepísať") { browser.enqueueUpload(pending.urls, into: pending.remoteDir, conflict: .overwrite) }
            Button("Preskočiť existujúce") { browser.enqueueUpload(pending.urls, into: pending.remoteDir, conflict: .skip) }
            Button("Zrušiť", role: .cancel) {}
        } message: { pending in
            Text(verbatim: Self.conflictList(pending.conflicts))
        }
        .confirmationDialog(downloadTitle, isPresented: downloadBinding, titleVisibility: .visible,
                            presenting: browser.pendingDownload) { pending in
            Button("Prepísať") { browser.enqueueDownload(pending.items, into: pending.localDir, conflict: .overwrite) }
            Button("Preskočiť existujúce") { browser.enqueueDownload(pending.items, into: pending.localDir, conflict: .skip) }
            Button("Zrušiť", role: .cancel) {}
        } message: { pending in
            Text(verbatim: Self.conflictList(pending.conflicts))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            FTPProtocolBadge(proto: browser.site.proto)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: browser.site.name).font(.headline).lineLimit(1)
                Text(verbatim: FTPProtocolStyle.address(browser.site))   // protocol is in the badge
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if browser.isConnecting || browser.loading {
                ProgressView().controlSize(.small)
            }
            // Only a live (or opening) session can be disconnected; a failed one has its own actions below.
            if browser.state == .connected || browser.isConnecting {
                Button {
                    model.disconnect()
                } label: {
                    Label("Odpojiť", systemImage: "eject")
                }
                .help("Odpojiť sa od servera")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Pripojenie zlyhalo").font(.headline)
            Text(verbatim: message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .lineLimit(8)
                .frame(maxWidth: 480)
            HStack {
                Button("Upraviť prístup…") { model.startEdit(browser.site) }
                if browser.authFailed || browser.site.auth == .password {
                    Button("Zadať heslo…") {
                        let field: SecretPrompt.Field = browser.site.auth == .privateKey ? .passphrase : .password
                        Task { await model.retryWithNewSecret(browser, field: field) }
                    }
                }
                Button("Skúsiť znova") { Task { await browser.connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(verbatim: message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { browser.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Zavrieť"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.red.opacity(0.1))
    }

    // MARK: Table

    private var table: some View {
        RemoteFileTable(items: browser.items, path: browser.path, actions: actions)
            .overlay {
                if browser.items.isEmpty && !browser.loading {
                    VStack(spacing: 6) {
                        Text("Prázdny priečinok").foregroundStyle(.secondary)
                        Text("Súbory sem môžete pretiahnuť z Findera.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    private var actions: RemoteFileTableActions {
        let browser = browser
        return RemoteFileTableActions(
            // Symlinks are tried as folders (e.g. www → public_html); a file link just fails to list.
            open: { item in if item.kind != .file { browser.open(item.path) } },
            download: { items in chooseDownloadFolder(items) },
            rename: { item in
                renameText = item.name
                renaming = item
            },
            delete: { items in pendingDelete = items },
            newFolder: {
                folderName = ""
                creatingFolder = true
            },
            copyPath: { items in browser.copyPaths(items) },
            refresh: { browser.refresh() },
            goUp: { browser.goUp() },
            drop: { urls, dir in Task { await browser.requestUpload(urls, into: dir) } },
            promise: { item, url, completion in browser.promiseDownload(item, to: url, completion: completion) })
    }

    /// "Stiahnuť…": choose a folder (default ~/Downloads), then conflicts → ask once.
    private func chooseDownloadFolder(_ items: [RemoteItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Stiahnuť sem")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let browser = browser
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { browser.requestDownload(items, into: url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: Dialog helpers

    static func conflictList(_ names: [String]) -> String {
        let shown = names.prefix(8).joined(separator: "\n")
        return names.count > 8 ? shown + "\n… (+\(names.count - 8))" : shown
    }

    private var deleteTitle: Text {
        guard let items = pendingDelete else { return Text("Zmazať?") }
        return items.count == 1 ? Text("Zmazať \(items[0].name)?") : Text("Zmazať \(items.count) položiek?")
    }

    private var uploadTitle: Text {
        Text("Na serveri už existuje: \(browser.pendingUpload?.conflicts.count ?? 0)")
    }

    private var downloadTitle: Text {
        Text("V cieľovom priečinku už existuje: \(browser.pendingDownload?.conflicts.count ?? 0)")
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var uploadBinding: Binding<Bool> {
        Binding(get: { browser.pendingUpload != nil }, set: { if !$0 { browser.pendingUpload = nil } })
    }

    private var downloadBinding: Binding<Bool> {
        Binding(get: { browser.pendingDownload != nil }, set: { if !$0 { browser.pendingDownload = nil } })
    }
}

// MARK: - Path bar

/// Up · breadcrumb (click a segment) · edit path · refresh.
struct FTPPathBar: View {
    @Bindable var browser: RemoteBrowserModel
    @State private var editing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .help("O priečinok vyššie")
                .disabled(browser.path == "/" || browser.path.isEmpty)
                .accessibilityLabel(Text("O priečinok vyššie"))
            if editing {
                TextField("Cesta", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($fieldFocused)
                    .onSubmit {
                        editing = false
                        browser.open(text)
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { if !fieldFocused { editing = false } }
            } else {
                breadcrumb
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing() }
            }
            Button { startEditing() } label: { Image(systemName: "character.cursor.ibeam") }
                .help("Zadať cestu")
                .accessibilityLabel(Text("Zadať cestu"))
            Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Obnoviť zoznam")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(Text("Obnoviť zoznam"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let crumbs = browser.breadcrumbs
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 1 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button { browser.open(crumb.path) } label: {
                        Text(verbatim: crumb.name)
                            .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: crumb.path))
                }
            }
        }
        .frame(height: 22)
    }

    private func startEditing() {
        text = browser.path
        editing = true
        fieldFocused = true
    }
}

// MARK: - Transfers

/// Collapsible list of transfer jobs (progress, files x/y, bytes, cancel, error).
struct FTPTransfersPanel: View {
    @Bindable var browser: RemoteBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button {
                    browser.transfersExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(browser.transfersExpanded ? 90 : 0))
                        Text("Prenosy")
                            .font(.subheadline.weight(.semibold))
                        if browser.activeJobCount > 0 {
                            Text(verbatim: "\(browser.activeJobCount)")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 6)
                                .background(.tint.opacity(0.2), in: .capsule)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Vymazať dokončené") { browser.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!browser.jobs.contains { !$0.isActive })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if browser.transfersExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.jobs.reversed()) { job in
                            FTPTransferRow(job: job) { browser.cancel(job) }
                            Divider()
                        }
                    }
                }
                .frame(height: min(CGFloat(browser.jobs.count) * 52, 170))
            }
        }
        .background(.background.secondary)
    }
}

struct FTPTransferRow: View {
    let job: RemoteTransferJob
    let cancel: () -> Void

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: job.title).lineLimit(1).truncationMode(.middle)
                    // Delete jobs have no destination — "→ /" read like a transfer into the root.
                    if job.kind == .delete {
                        Text("zmazanie").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "→ " + job.destination)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                switch job.status {
                case .running, .queued:
                    if job.kind == .delete || job.progress == nil {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView(value: job.progress?.fraction ?? 0).controlSize(.small)
                    }
                case .failed(let message):
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                default:
                    EmptyView()
                }
                Text(verbatim: detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.isActive {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Zrušiť prenos")
                    .accessibilityLabel(Text("Zrušiť prenos"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch job.status {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        default:
            switch job.kind {
            case .upload: "arrow.up.circle"
            case .download: "arrow.down.circle"
            case .delete: "trash.circle"
            }
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var detail: String {
        let status: String = switch job.status {
        case .queued: String(localized: "Čaká")
        case .running: job.kind == .delete ? String(localized: "Maže sa…") : ""
        case .done: String(localized: "Hotovo")
        case .cancelled: String(localized: "Zrušené")
        case .failed: String(localized: "Chyba")
        }
        guard let p = job.progress, job.kind != .delete else { return status }
        var parts: [String] = []
        if !status.isEmpty { parts.append(status) }
        parts.append(String(localized: "súbory \(p.filesDone)/\(p.filesTotal)"))
        if let total = p.bytesTotal {
            parts.append(String(localized: "\(Self.bytes.string(fromByteCount: p.bytesDone)) z \(Self.bytes.string(fromByteCount: total))"))
        } else {
            parts.append(Self.bytes.string(fromByteCount: p.bytesDone))
        }
        return parts.joined(separator: " · ")
    }
}
