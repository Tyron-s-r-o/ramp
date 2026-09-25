import AppKit
import SwiftUI
import RAMPCore

/// Databáza › Redis: compact status line + DB picker + MATCH search, keys (left, fixed width) and
/// key detail (right). Plain HStack + Divider — no HSplitView / Table-in-Form (window-layout blowups);
/// every scrolling pane is `maxHeight: .infinity, minHeight: 0`.
struct RedisBrowserView: View {
    @Environment(AppModel.self) private var app
    let model: DatabaseModel

    @AppStorage("redisBrowserTree") private var treeMode = true
    @State private var search = "*"
    @State private var confirmFlush = false
    @State private var patternCount: Int?
    @State private var confirmPatternDelete = false

    private var browser: RedisBrowserModel { model.redisBrowser }
    private var running: Bool { model.state(of: .redis).isRunning }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            if running {
                HStack(spacing: 0) {
                    RedisKeyListView(browser: browser, treeMode: treeMode)
                        .frame(width: 320)
                        .frame(maxHeight: .infinity)
                    Divider()
                    RedisKeyDetailView(browser: browser)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            } else {
                stoppedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: running) {
            browser.app = app
            if running {
                browser.configure(host: model.redisHost, port: model.redisPort)
                await browser.reload()
            } else {
                browser.disconnect()
            }
        }
        .onDisappear { browser.autoRefresh = false }
        .confirmationDialog(Text("Vymazať všetky kľúče v Redise?"), isPresented: $confirmFlush,
                            titleVisibility: .visible) {
            Button("Vymazať všetko (FLUSHALL)", role: .destructive) {
                Task {
                    await model.flushRedis()
                    browser.clearSelection()
                    await browser.reload()
                }
            }
        } message: {
            Text("Natrvalo sa vymažú všetky kľúče vo všetkých databázach Redisu (počet: \(model.redis?.keys ?? 0)).")
        }
        .confirmationDialog(Text("Vymazať kľúče podľa vzoru?"), isPresented: $confirmPatternDelete,
                            titleVisibility: .visible) {
            Button("Vymazať \(patternCount ?? 0) kľúčov", role: .destructive) {
                Task { await browser.deleteMatching() }
            }
            .disabled((patternCount ?? 0) == 0)
        } message: {
            Text("Vzor „\(browser.pattern)“ v DB \(browser.db) zodpovedá \(patternCount ?? 0) kľúčom. Vymažú sa natrvalo (SCAN + UNLINK).")
        }
    }

    // MARK: Status line

    private var statusRow: some View {
        HStack(spacing: 10) {
            let state = model.state(of: .redis)
            Circle().fill(state.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(DatabaseView.stateText(state))
                .foregroundStyle(state.isRunning ? .green : .secondary)
            let busy = app.busy.contains("start:redis") || app.busy.contains("stop:redis")
            Button {
                Task { await model.toggle(.redis) }
            } label: {
                if state.isRunning { Text("Zastaviť") } else { Text("Spustiť") }
            }
            .controlSize(.small)
            .disabled(busy)
            infoLine
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.loadingRedis || browser.loadingKeys || browser.working || model.flushing {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 8)
            if running {
                dbPicker
                TextField(text: $search, prompt: Text("Vzor (MATCH), napr. user:*")) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 200)
                    .onSubmit { Task { await browser.applyPattern(search) } }
                    .help("SCAN MATCH vzor — * a ? zástupné znaky; Enter použije")
                Button {
                    Task {
                        await model.refreshRedis()
                        await browser.reload()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Obnoviť kľúče")
            }
            actionsMenu
        }
    }

    @ViewBuilder private var infoLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: ":\(model.redisPort)")
            if let info = model.redis {
                Text(verbatim: "·")
                Text(verbatim: info.version ?? "—")
                Text(verbatim: "·")
                Text(verbatim: info.usedMemoryHuman ?? "—")
                Text(verbatim: "·")
                Text("Kľúče: \(info.keys)")
            }
            if let error = model.redisError ?? browser.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(verbatim: error)
            }
        }
        .monospacedDigit()
    }

    private var dbPicker: some View {
        Picker(selection: Binding(get: { browser.db }, set: { db in Task { await browser.selectDB(db) } })) {
            ForEach(0..<browser.databaseCount, id: \.self) { i in
                let n = browser.dbStats[i]?.keys ?? 0
                if n > 0 {
                    Text(verbatim: "DB \(i) (\(n))").tag(i)
                } else {
                    Text(verbatim: "DB \(i)").tag(i)
                }
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .fixedSize()
        .help("Databáza Redisu (SELECT)")
    }

    private var actionsMenu: some View {
        Menu {
            Toggle("Stromové zobrazenie (podľa „:“)", isOn: $treeMode)
            Toggle("Automaticky obnovovať", isOn: Binding(get: { browser.autoRefresh },
                                                          set: { browser.autoRefresh = $0 }))
            Divider()
            Button("Vymazať kľúče podľa vzoru…") {
                Task {
                    patternCount = await browser.countMatching()
                    if patternCount != nil { confirmPatternDelete = true }
                }
            }
            .disabled(!running)
            Button("Vymazať všetko (FLUSHALL)…", role: .destructive) { confirmFlush = true }
                .disabled(!running || model.flushing)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ďalšie akcie")
    }

    private var stoppedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").font(.largeTitle).foregroundStyle(.secondary)
            Text("Redis nebeží").font(.headline)
            Text("Spustite Redis, aby ste mohli prehliadať kľúče.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keys list

private struct RedisKeyListView: View {
    let browser: RedisBrowserModel
    let treeMode: Bool
    /// Expanded folder ids — explicit so a click anywhere on a folder row toggles it (not just the chevron).
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if browser.keys.isEmpty && !browser.loadingKeys {
                    Group {
                        if browser.pattern == "*" {
                            Text("Databáza je prázdna")
                        } else {
                            Text("Žiadne kľúče nezodpovedajú vzoru")
                        }
                    }
                    .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if treeMode {
                    List(selection: selection) {
                        ForEach(browser.tree) { node in nodeView(node) }
                    }
                } else {
                    List(browser.flatKeys, id: \.name, selection: selection) { key in
                        keyRow(name: key.name, key: key)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { browser.selectedID }, set: { browser.selectedID = $0 })
    }

    private func nodeView(_ node: RedisKeyNode) -> AnyView {
        if let key = node.key {
            return AnyView(keyRow(name: node.name, key: key))
        }
        let isOpen = Binding(
            get: { expanded.contains(node.id) },
            set: { open in if open { expanded.insert(node.id) } else { expanded.remove(node.id) } })
        return AnyView(
            DisclosureGroup(isExpanded: isOpen) {
                ForEach(node.children ?? []) { child in nodeView(child) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen.wrappedValue ? "folder.fill" : "folder").foregroundStyle(.secondary)
                    Text(verbatim: node.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(node.count, format: .number).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.15)) { isOpen.wrappedValue.toggle() } }
                .selectionDisabled()   // only the folder row — on the whole group it also blocked the keys inside
            }
        )
    }

    private func keyRow(name: String, key: RedisKey) -> some View {
        HStack(spacing: 6) {
            RedisTypeBadge(type: browser.type(of: key))
            Text(verbatim: name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: key.name))
        }
        .tag(key.name)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Načítané: \(browser.keys.count) z \(browser.totalInDB)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if browser.hasMore {
                Button("Načítať ďalšie") { Task { await browser.loadKeys(reset: false) } }
                    .controlSize(.small)
                    .disabled(browser.loadingKeys)
            }
        }
    }
}

struct RedisTypeBadge: View {
    let type: String?

    var body: some View {
        let (label, color) = Self.style(type)
        Text(verbatim: label)
            .font(.system(size: 9, weight: .semibold).monospaced())
            .foregroundStyle(color)
            .frame(width: 34)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }

    static func style(_ type: String?) -> (String, Color) {
        switch type {
        case "string": ("STR", .blue)
        case "hash": ("HASH", .purple)
        case "list": ("LIST", .orange)
        case "set": ("SET", .green)
        case "zset": ("ZSET", .teal)
        case "stream": ("XSTR", .pink)
        case nil: ("…", .secondary)
        case let other?: (String(other.prefix(4)).uppercased(), .gray)
        }
    }
}

// MARK: - Detail

private struct RedisKeyDetailView: View {
    let browser: RedisBrowserModel

    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var editingTTL = false
    @State private var ttlText = ""

    var body: some View {
        if let key = browser.selectedKey {
            VStack(alignment: .leading, spacing: 0) {
                header(key)
                    .padding(12)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .confirmationDialog(Text("Vymazať kľúč?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Vymazať", role: .destructive) { Task { await browser.deleteSelected() } }
            } message: {
                Text("Kľúč „\(key.name)“ sa natrvalo vymaže.")
            }
            .sheet(isPresented: $renaming) { renameSheet(key) }
            .sheet(isPresented: $editingTTL) { ttlSheet }
        } else {
            Text("Vyberte kľúč")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private func header(_ key: RedisKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RedisTypeBadge(type: browser.meta?.typeName ?? browser.type(of: key))
                Text(verbatim: key.name)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if browser.loadingDetail { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 14) {
                if let meta = browser.meta {
                    Label { ttlText(meta) } icon: { Image(systemName: "timer") }
                    if let size = meta.size {
                        Label { sizeText(meta.type, size) } icon: { Image(systemName: "number") }
                    }
                    if let mem = meta.memory {
                        Label { Text(mem, format: .byteCount(style: .memory)) } icon: { Image(systemName: "memorychip") }
                    }
                }
                Spacer(minLength: 4)
                actions(key)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let error = browser.detailError {
                Label { Text(verbatim: error) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
    }

    private func ttlText(_ meta: RedisKeyMeta) -> Text {
        guard let ms = meta.ttlMillis, ms >= 0 else { return Text("Bez expirácie") }
        let d = Duration.milliseconds(ms)
        return Text("TTL \(d.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
    }

    private func sizeText(_ type: RedisKeyType, _ size: Int64) -> Text {
        switch type {
        case .string: Text(size, format: .byteCount(style: .memory))
        case .hash: Text("Polí: \(size)")
        case .stream: Text("Záznamov: \(size)")
        default: Text("Prvkov: \(size)")
        }
    }

    private func actions(_ key: RedisKey) -> some View {
        HStack(spacing: 8) {
            Button {
                browser.copy(copyText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Kopírovať hodnotu")
            .disabled(browser.detail == nil)
            Button {
                browser.copy(key.name)
            } label: {
                Image(systemName: "key")
            }
            .help("Kopírovať názov kľúča")
            Button {
                ttlText = browser.meta?.ttlMillis.map { String(max(1, $0 / 1000)) } ?? ""
                editingTTL = true
            } label: {
                Image(systemName: "timer")
            }
            .help("Nastaviť TTL…")
            Button {
                newName = key.name
                renaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Premenovať…")
            Button {
                Task { await browser.loadDetail(key) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Obnoviť")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Vymazať kľúč…")
        }
        .buttonStyle(.borderless)
        .disabled(browser.working)
    }

    /// Text representation for "Kopírovať hodnotu".
    private var copyText: String {
        func d(_ data: Data) -> String { RedisValueFormat.display(data) }
        switch browser.detail {
        case .string(let v): return d(v.data)
        case .hash(let pairs, _): return pairs.map { "\(d($0.field))\t\(d($0.value))" }.joined(separator: "\n")
        case .list(let items, _): return items.map(d).joined(separator: "\n")
        case .set(let items, _): return items.map(d).joined(separator: "\n")
        case .zset(let items, _): return items.map { "\($0.score)\t\(d($0.member))" }.joined(separator: "\n")
        case .stream(let entries):
            return entries.map { e in
                e.id + "\t" + e.fields.map { "\(d($0.field))=\(d($0.value))" }.joined(separator: " ")
            }.joined(separator: "\n")
        case .unsupported, nil: return ""
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch browser.detail {
        case .string(let value):
            RedisStringDetail(browser: browser, value: value)
        case .hash(let pairs, let cursor):
            RedisPairsDetail(rows: pairs.map { ($0.field, $0.value) }, firstTitle: "Pole", secondTitle: "Hodnota",
                             more: cursor != "0" ? { Task { await browser.loadMoreMembers() } } : nil)
        case .list(let items, let start):
            RedisPagedDetail(browser: browser, start: start, total: Int(browser.meta?.size ?? 0),
                             rows: items.enumerated().map { (Data(String(start + $0.offset).utf8), $0.element) },
                             firstTitle: "Index")
        case .set(let members, let cursor):
            RedisPairsDetail(rows: members.map { (nil, $0) }, firstTitle: nil, secondTitle: "Člen",
                             more: cursor != "0" ? { Task { await browser.loadMoreMembers() } } : nil)
        case .zset(let items, let start):
            RedisPagedDetail(browser: browser, start: start, total: Int(browser.meta?.size ?? 0),
                             rows: items.map { (Data($0.score.utf8), $0.member) }, firstTitle: "Skóre")
        case .stream(let entries):
            RedisStreamDetail(entries: entries, total: Int(browser.meta?.size ?? 0))
        case .unsupported(let type):
            VStack(spacing: 6) {
                if type == "none" {
                    Text("Kľúč už neexistuje")
                } else {
                    Text("Typ „\(type)“ sa nedá zobraziť")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            Color.clear
        }
    }

    // MARK: Sheets

    private func renameSheet(_ key: RedisKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Premenovať kľúč").font(.headline)
            TextField(text: $newName) { Text("Nový názov") }
                .font(.body.monospaced())
                .frame(minWidth: 360)
            Text("Existujúci kľúč sa nikdy neprepíše (RENAMENX).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { renaming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Premenovať") {
                    Task {
                        if await browser.rename(to: newName) { renaming = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty || newName == key.name || browser.working)
            }
        }
        .padding(20)
    }

    private var ttlSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nastaviť TTL").font(.headline)
            HStack {
                TextField(text: $ttlText) { Text("Sekundy") }
                    .frame(width: 140)
                    .monospacedDigit()
                Text("sekúnd").foregroundStyle(.secondary)
            }
            HStack {
                Button("Odstrániť expiráciu (PERSIST)") {
                    Task {
                        await browser.setTTL(seconds: nil)
                        editingTTL = false
                    }
                }
                Spacer()
                Button("Zrušiť", role: .cancel) { editingTTL = false }
                    .keyboardShortcut(.cancelAction)
                Button("Nastaviť") {
                    Task {
                        await browser.setTTL(seconds: Int(ttlText))
                        editingTTL = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((Int(ttlText) ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

// MARK: - String

/// View mode of a JSON / PHP-serialized string value.
private enum RedisStringMode: String {
    case tree, pretty, raw
}

/// Kind + parsed tree of a string value, computed off the main thread.
private struct RedisStringAnalysis: Sendable {
    let kind: RedisValueKind
    let tree: StructuredValue?
    let error: StructuredParseError?

    static func make(_ value: RedisStringValue) -> RedisStringAnalysis {
        let kind = RedisValueFormat.kind(value.data)
        guard kind == .json || kind == .phpSerialized, !value.truncated else {
            return RedisStringAnalysis(kind: kind, tree: nil, error: nil)
        }
        do {
            return RedisStringAnalysis(kind: kind, tree: try RedisValueFormat.structured(value.data, kind: kind), error: nil)
        } catch {
            return RedisStringAnalysis(kind: kind, tree: nil, error: error)
        }
    }
}

private struct RedisStringDetail: View {
    let browser: RedisBrowserModel
    let value: RedisStringValue

    @AppStorage("redisBrowserStringMode") private var mode = RedisStringMode.tree
    @State private var analysis: RedisStringAnalysis?
    @State private var tree: RedisTreeState?
    @State private var phpPretty: NSAttributedString?
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmSave = false

    private var kind: RedisValueKind? { analysis?.kind }
    private var structured: Bool { kind == .json || kind == .phpSerialized }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: value) {
            editing = false
            analysis = nil
            tree = nil
            phpPretty = nil
            let value = value
            let result = await Task.detached(priority: .userInitiated) { RedisStringAnalysis.make(value) }.value
            guard !Task.isCancelled else { return }
            analysis = result
            tree = result.tree.map { RedisTreeState(root: $0) }
        }
        .task(id: PrettyKey(value: value, mode: mode, ready: analysis != nil)) {
            guard mode == .pretty, phpPretty == nil, analysis?.kind == .phpSerialized, let root = analysis?.tree else { return }
            let text = await Task.detached(priority: .userInitiated) { root.prettyText() }.value
            guard !Task.isCancelled else { return }
            phpPretty = Self.colored(text)
        }
        .confirmationDialog(Text("Uložiť novú hodnotu?"), isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Uložiť") {
                Task {
                    if await browser.saveString(draft) { editing = false }
                }
            }
        } message: {
            Text("Hodnota kľúča sa prepíše (SET … KEEPTTL, TTL zostane zachované).")
        }
    }

    private struct PrettyKey: Equatable {
        let value: RedisStringValue
        let mode: RedisStringMode
        let ready: Bool
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            switch kind {
            case .json?: badge("JSON", .blue)
            case .phpSerialized?: badge("PHP serialized", .purple)
            case .binary?: badge("Binárne (hex)", .orange)
            case .text?: badge("Text", .secondary)
            case nil: ProgressView().controlSize(.small)
            }
            if case .object(let className?, _)? = analysis?.tree {
                Text(verbatim: className)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(Text(verbatim: className))
            }
            if structured && !editing {
                Picker(selection: $mode) {
                    Text("Strom").tag(RedisStringMode.tree)
                    Text("Formátované").tag(RedisStringMode.pretty)
                    Text("Surové").tag(RedisStringMode.raw)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if value.truncated {
                Text("Zobrazených prvých \(value.data.count.formatted(.byteCount(style: .memory))) z \(value.total.formatted(.byteCount(style: .memory)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Zobraziť celé") { Task { await browser.loadFullString() } }
                    .controlSize(.small)
            }
            Spacer()
            if editing {
                Button("Zrušiť") { editing = false }
                    .controlSize(.small)
                Button("Uložiť") { confirmSave = true }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(browser.working)
            } else if let kind, kind != .binary, !value.truncated {
                Button("Upraviť") {
                    draft = String(decoding: value.data, as: UTF8.self)
                    editing = true
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if editing {
            RedisCodeTextView(text: $draft, editable: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        } else if let analysis {
            if structured && mode == .tree {
                if let tree {
                    RedisStructuredTreeView(state: tree, copy: browser.copy)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if let error = analysis.error {
                                Label {
                                    Text("Hodnotu sa nepodarilo rozparsovať: \(error.message) (bajt \(error.offset))")
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            } else {
                                Text("Strom je dostupný po načítaní celej hodnoty.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider()
                        RedisCodeTextView(attributed: Self.render(value.data, kind: analysis.kind, pretty: false))
                            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    }
                }
            } else if structured && mode == .pretty && analysis.kind == .phpSerialized {
                if let phpPretty {
                    RedisCodeTextView(attributed: phpPretty)
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if analysis.tree == nil {
                    RedisCodeTextView(attributed: Self.render(value.data, kind: analysis.kind, pretty: false))
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                RedisCodeTextView(attributed: Self.render(value.data, kind: analysis.kind, pretty: mode != .raw))
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private static var codeAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.textColor]
    }

    static func render(_ data: Data, kind: RedisValueKind, pretty: Bool) -> NSAttributedString {
        switch kind {
        case .binary:
            return NSAttributedString(string: RedisValueFormat.hexDump(data, limit: data.count), attributes: codeAttributes)
        case .json where pretty:
            return colored(RedisValueFormat.prettyJSON(String(decoding: data, as: UTF8.self)))
        default:
            return NSAttributedString(string: String(decoding: data, as: UTF8.self), attributes: codeAttributes)
        }
    }

    /// JSON(-like) text with syntax colours.
    static func colored(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: codeAttributes)
        // Colouring very large documents is slow and not useful.
        if text.utf16.count <= 512 * 1024 {
            for token in RedisValueFormat.jsonTokens(text) {
                let color: NSColor = switch token.kind {
                case .key: .systemPurple
                case .string: .systemRed
                case .number: .systemBlue
                case .literal: .systemOrange
                case .punctuation: .secondaryLabelColor
                }
                out.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: token.range.lowerBound, length: token.range.count))
            }
        }
        return out
    }
}

// MARK: - Structured tree (JSON / PHP serialized)

/// Expansion / search state of the tree. Rows are materialised only for expanded nodes, and arrays
/// show `pageSize` children at a time, so huge values stay responsive.
@MainActor @Observable
final class RedisTreeState {
    static let pageSize = 500
    /// "Rozbaliť všetko" stops after this many containers.
    static let expandAllBudget = 2_000

    struct Row: Identifiable {
        enum Kind { case node, more(remaining: Int) }
        let id: [Int]
        let path: [Int]
        let depth: Int
        let key: StructuredValue.Key?
        let visibility: StructuredValue.Visibility?
        let value: StructuredValue
        let kind: Kind
    }

    let root: StructuredValue
    private(set) var rows: [Row] = []
    private(set) var matches: Set<[Int]> = []
    private(set) var matchCount = 0
    private(set) var searching = false
    var focused: [Int]?
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    private var expanded: Set<[Int]> = []
    private var limits: [[Int]: Int] = [:]
    private var searchTask: Task<Void, Never>?

    init(root: StructuredValue) {
        self.root = root
        // Top two levels open.
        expanded.insert([])
        for i in 0..<min(root.childCount, Self.pageSize) where root.child(at: i).value.isContainer {
            expanded.insert([i])
        }
        rebuild()
    }

    func isExpanded(_ path: [Int]) -> Bool { expanded.contains(path) }

    func toggle(_ path: [Int]) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        rebuild()
    }

    func showMore(_ parent: [Int]) {
        limits[parent, default: Self.pageSize] += Self.pageSize
        rebuild()
    }

    func expandAll() {
        var queue: [([Int], StructuredValue)] = [([], root)]
        var head = 0
        var budget = Self.expandAllBudget
        while head < queue.count, budget > 0 {
            let (path, node) = queue[head]
            head += 1
            guard node.isContainer else { continue }
            expanded.insert(path)
            budget -= 1
            let limit = limits[path] ?? Self.pageSize
            for i in 0..<min(node.childCount, limit) {
                let child = node.child(at: i).value
                if child.isContainer { queue.append((path + [i], child)) }
            }
        }
        rebuild()
    }

    func collapseAll() {
        expanded = [[]]
        rebuild()
    }

    /// Expands ancestors (and pages) so the node at `path` is visible, and focuses it.
    func reveal(_ path: [Int]) {
        openPath(to: path)
        focused = path
        rebuild()
    }

    func accessPath(_ path: [Int]) -> String {
        let p = root.path(of: path)
        return p.isEmpty ? "$" : p
    }

    private func openPath(to path: [Int]) {
        for depth in 0..<path.count {
            let parent = Array(path.prefix(depth))
            expanded.insert(parent)
            if path[depth] >= limits[parent] ?? Self.pageSize {
                limits[parent] = (path[depth] / Self.pageSize + 1) * Self.pageSize
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            matches = []
            matchCount = 0
            searching = false
            rebuild()
            return
        }
        searching = true
        let root = root
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { root.search(q) }.value
            guard !Task.isCancelled, let self else { return }
            self.matches = Set(found)
            self.matchCount = found.count
            self.searching = false
            // Auto-expand the paths to the first matches (bounded, so a common word can't open everything).
            for path in found.prefix(200) { self.openPath(to: path) }
            self.focused = found.first
            self.rebuild()
        }
    }

    private func rebuild() {
        var out: [Row] = []
        func add(_ value: StructuredValue, key: StructuredValue.Key?, visibility: StructuredValue.Visibility?,
                 path: [Int]) {
            out.append(Row(id: path, path: path, depth: path.count, key: key, visibility: visibility,
                           value: value, kind: .node))
            guard value.isContainer, expanded.contains(path) else { return }
            let count = value.childCount
            let limit = min(count, limits[path] ?? Self.pageSize)
            for i in 0..<limit {
                let c = value.child(at: i)
                add(c.value, key: c.key, visibility: c.visibility, path: path + [i])
            }
            if count > limit {
                out.append(Row(id: path + [-1], path: path, depth: path.count + 1, key: nil, visibility: nil,
                               value: .null, kind: .more(remaining: count - limit)))
            }
        }
        add(root, key: nil, visibility: nil, path: [])
        rows = out
    }
}

private struct RedisStructuredTreeView: View {
    @Bindable var state: RedisTreeState
    let copy: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(text: $state.query) { Text("Hľadať v hodnote") }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if state.searching {
                    ProgressView().controlSize(.small)
                } else if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Zhody: \(state.matchCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Rozbaliť všetko") { state.expandAll() }
                    .controlSize(.small)
                Button("Zbaliť všetko") { state.collapseAll() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                List(state.rows) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(background(row))
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 20)
                .frame(minHeight: 0, maxHeight: .infinity)
                .onChange(of: state.focused) { _, target in
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func background(_ row: RedisTreeState.Row) -> some View {
        if case .node = row.kind, row.path == state.focused {
            Color.accentColor.opacity(0.25)
        } else if case .node = row.kind, state.matches.contains(row.path) {
            Color.yellow.opacity(0.22)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func rowView(_ row: RedisTreeState.Row) -> some View {
        switch row.kind {
        case .more(let remaining):
            Button("Zobraziť ďalších \(min(remaining, RedisTreeState.pageSize)) (zostáva \(remaining))") {
                state.showMore(row.path)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.leading, CGFloat(row.depth) * 14 + 16)
        case .node:
            nodeRow(row)
        }
    }

    private func nodeRow(_ row: RedisTreeState.Row) -> some View {
        HStack(spacing: 6) {
            Group {
                if row.value.isContainer && row.value.childCount > 0 {
                    Button {
                        state.toggle(row.path)
                    } label: {
                        Image(systemName: state.isExpanded(row.path) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            if let key = row.key {
                Text(verbatim: key.text)
                    .font(.body.monospaced())
                    .foregroundStyle(keyColor(key))
                    .lineLimit(1)
                if let vis = visibilityText(row.visibility) {
                    Text(verbatim: vis)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: "$")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            typeBadge(row.value)
            if !row.value.isContainer {
                scalarView(row.value)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if row.value.isContainer { state.toggle(row.path) }
        }
        .contextMenu {
            Button("Kopírovať cestu") { copy(state.accessPath(row.path)) }
            Button("Kopírovať hodnotu") { copy(row.value.copyText) }
            if case .reference(let n, _) = row.value, let target = state.root.phpSlotPath(n) {
                Divider()
                Button("Prejsť na cieľ referencie") { state.reveal(target) }
            }
        }
    }

    private func scalarView(_ value: StructuredValue) -> some View {
        let full = value.scalarText
        let oneLine: String = {
            let head = full.prefix(300)
            let flat = head.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "")
            return head.count < full.count ? flat + "…" : flat
        }()
        let shown: String = if case .string = value { "\"" + oneLine + "\"" } else { oneLine }
        return Text(verbatim: shown)
            .font(.body.monospaced())
            .foregroundStyle(scalarColor(value))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Text(verbatim: full.count > 2_000 ? String(full.prefix(2_000)) + "…" : full))
    }

    private func keyColor(_ key: StructuredValue.Key) -> Color {
        if case .int = key { return .secondary }
        return .purple
    }

    private func scalarColor(_ value: StructuredValue) -> Color {
        switch value {
        case .string: .red
        case .int, .double: .blue
        case .bool, .null: .orange
        case .reference: .teal
        default: .primary
        }
    }

    private func visibilityText(_ v: StructuredValue.Visibility?) -> String? {
        switch v {
        case .protected?: "protected"
        case .private(let c)?: "private \(Self.shortClass(c))"
        default: nil
        }
    }

    static func shortClass(_ name: String) -> String {
        name.split(separator: "\\").last.map(String.init) ?? name
    }

    private func typeBadge(_ value: StructuredValue) -> some View {
        let (text, full): (String, String?) = switch value {
        case .null: ("null", nil)
        case .bool: ("bool", nil)
        case .int: ("int", nil)
        case .double: ("float", nil)
        case .string(let s): ("string(\(s.utf8.count))", nil)
        case .array(let e): ("array[\(e.count)]", nil)
        case .object(let c?, let p): ("object \(Self.shortClass(c)) {\(p.count)}", c)
        case .object(nil, let p): ("object {\(p.count)}", nil)
        case .enumCase(let c, _): ("enum \(Self.shortClass(c))", c)
        case .reference(_, let byRef): (byRef ? "&ref" : "ref", nil)
        case .custom(let c, _): ("custom \(Self.shortClass(c))", c)
        }
        return Text(verbatim: text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .help(Text(verbatim: full ?? text))
    }
}

// MARK: - Collections

/// Two-column rows (field/value, index/value, score/member) with a search filter.
private struct RedisPairsDetail: View {
    let rows: [(Data?, Data)]
    let firstTitle: LocalizedStringKey?
    let secondTitle: LocalizedStringKey
    let more: (() -> Void)?

    @State private var filter = ""

    private var filtered: [(offset: Int, element: (Data?, Data))] {
        let all = Array(rows.enumerated())
        guard !filter.isEmpty else { return all }
        return all.filter { row in
            let (a, b) = row.element
            return (a.map { RedisValueFormat.display($0).localizedCaseInsensitiveContains(filter) } ?? false)
                || RedisValueFormat.display(b).localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(text: $filter, prompt: Text("Hľadať v načítaných")) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text("Načítané: \(rows.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let more {
                    Button("Načítať ďalšie", action: more).controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            RedisRowsList(rows: filtered.map { ($0.offset, $0.element.0, $0.element.1) },
                          firstTitle: firstTitle, secondTitle: secondTitle)
        }
    }
}

/// LRANGE / ZRANGE pages of 100.
private struct RedisPagedDetail: View {
    let browser: RedisBrowserModel
    let start: Int
    let total: Int
    let rows: [(Data, Data)]
    let firstTitle: LocalizedStringKey

    var body: some View {
        let page = RedisBrowserService.pageSize
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await browser.page(start - page) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(start == 0)
                Text("\(rows.isEmpty ? 0 : start + 1)–\(start + rows.count) z \(total)")
                    .monospacedDigit()
                    .font(.callout)
                Button {
                    Task { await browser.page(start + page) }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(start + page >= total)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            RedisRowsList(rows: rows.enumerated().map { ($0.offset, $0.element.0, $0.element.1) },
                          firstTitle: firstTitle, secondTitle: "Hodnota")
        }
    }
}

private struct RedisRowsList: View {
    let rows: [(Int, Data?, Data)]
    let firstTitle: LocalizedStringKey?
    let secondTitle: LocalizedStringKey

    /// Per-cell display cap — a single huge element must not stall the list.
    static let cellLimit = 4096

    static func cell(_ data: Data) -> String {
        let s = RedisValueFormat.display(data.count > cellLimit ? data.prefix(cellLimit) : data)
        return data.count > cellLimit ? s + " …" : s
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let firstTitle {
                    Text(firstTitle).frame(width: 180, alignment: .leading)
                }
                Text(secondTitle)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            if firstTitle != nil {
                                Text(verbatim: row.1.map(Self.cell) ?? "")
                                    .frame(width: 180, alignment: .leading)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                            }
                            Text(verbatim: Self.cell(row.2))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(8)
                        }
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(row.0.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}

private struct RedisStreamDetail: View {
    let entries: [RedisStreamEntry]
    let total: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Posledných \(entries.count) z \(total) záznamov").font(.callout).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            ForEach(Array(entry.fields.enumerated()), id: \.offset) { _, f in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: RedisRowsList.cell(f.field))
                                        .foregroundStyle(.purple)
                                        .frame(width: 160, alignment: .leading)
                                        .lineLimit(2)
                                    Text(verbatim: RedisRowsList.cell(f.value))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(6)
                                }
                                .font(.callout.monospaced())
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        Divider()
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}

// MARK: - NSTextView wrapper (fast for large values, own scrolling, no ideal-height growth)

struct RedisCodeTextView: NSViewRepresentable {
    var attributed: NSAttributedString?
    var text: Binding<String>?
    var editable = false

    init(attributed: NSAttributedString) {
        self.attributed = attributed
    }

    init(text: Binding<String>, editable: Bool) {
        self.text = text
        self.editable = editable
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.isEditable = editable
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.allowsUndo = editable
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.delegate = context.coordinator
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = text
        tv.isEditable = editable
        apply(to: tv)
    }

    private func apply(to tv: NSTextView) {
        if let attributed {
            if tv.textStorage?.isEqual(to: attributed) != true {
                tv.textStorage?.setAttributedString(attributed)
            }
        } else if let text, tv.string != text.wrappedValue {
            tv.string = text.wrappedValue
            tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tv.textColor = .textColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>?
        init(text: Binding<String>?) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text?.wrappedValue = tv.string
        }
    }
}


/// Window wrapper: the browser needs the shared DatabaseModel.
struct RedisBrowserWindow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        RedisBrowserView(model: app.database)
            .navigationTitle(Text(verbatim: "Redis"))
            .task { await app.database.refresh() }
    }
}
