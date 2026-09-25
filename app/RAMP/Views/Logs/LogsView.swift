import AppKit
import SwiftUI
import RAMPCore

struct LogsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.logs
        @Bindable var bindable = model
        // HStack, not HSplitView: NSSplitView adopts the ideal height of the log ScrollView
        // (all lines) and blows the whole window layout up (content rendered off-screen).
        HStack(spacing: 0) {
            LogFileList(model: model)
                .frame(width: 240)
            Divider()
            LogLinesView(model: model)
                .frame(minWidth: 360, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationTitle(Text("Logy"))
        .searchable(text: $bindable.filter, placement: .toolbar, prompt: Text("Filtrovať riadky"))
        .toolbar { toolbar(model) }
        .task { await model.runFileRefresh() }
        .task(id: model.selected) { await model.runFollow() }
        .onChange(of: app.logPreselection, initial: true) { _, id in
            guard let id else { return }
            model.select(service: id)
            app.logPreselection = nil
        }
    }

    @ToolbarContentBuilder private func toolbar(_ model: LogsModel) -> some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .automatic) {
            Picker(selection: $model.levelFilter) {
                Text("Všetko").tag(LogLevelFilter.all)
                Text("Len chyby").tag(LogLevelFilter.errors)
            } label: {
                Text("Úroveň")
            }
            .pickerStyle(.segmented)
            .help("Zobraziť všetky riadky alebo len chyby")

            Toggle(isOn: $model.follow) {
                Label("Sledovať", systemImage: "arrow.down.to.line")
            }
            .help("Automaticky posúvať na nové riadky")

            Button {
                model.clear()
            } label: {
                Label("Vyčistiť zobrazenie", systemImage: "clear")
            }
            .help("Vyčistiť zobrazenie (súbor ostane nezmenený)")

            Menu {
                Button("Otvoriť v Konzole") { openInConsole(model.selected) }
                    .disabled(model.selected == nil)
                Button("Zobraziť vo Finderi") {
                    if let url = model.selected { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(model.selected == nil)
                Button("Otvoriť priečinok logov") { NSWorkspace.shared.open(model.logsDir) }
            } label: {
                Label("Otvoriť", systemImage: "arrow.up.forward.app")
            }
            .help("Otvoriť log v inej aplikácii")
        }
    }

    private func openInConsole(_ url: URL?) {
        guard let url else { return }
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct LogFileList: View {
    @Bindable var model: LogsModel

    var body: some View {
        let groups = Dictionary(grouping: model.files, by: \.group)
        List(selection: $model.selected) {
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section {
                    ForEach(groups[group] ?? []) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack {
                                Text(Int64(file.size), format: .byteCount(style: .file))
                                Spacer()
                                Text(file.modified, format: .relative(presentation: .named))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(file.url)
                    }
                } header: {
                    Text(verbatim: Self.title(of: group))
                }
            }
        }
        .overlay {
            if model.files.isEmpty {
                ContentUnavailableView("Žiadne logy", systemImage: "doc.text",
                                       description: Text("Priečinok logov je zatiaľ prázdny."))
            }
        }
    }

    static func title(of group: LogGroup) -> String {
        switch group {
        case .apache: "Apache"
        case .php(let branch): "PHP \(branch)"
        case .mysql: "MySQL"
        case .redis: "Redis"
        case .elasticsearch: "Elasticsearch"
        case .other: String(localized: "Ostatné")
        }
    }
}

private struct LogLinesView: View {
    let model: LogsModel

    var body: some View {
        let visible = model.visibleLines
        let needle = model.filter.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            if let error = model.readError {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { line in
                            Text(Self.attributed(line, highlight: needle))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Self.color(line.level))
                                .fixedSize(horizontal: true, vertical: false)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: visible.last?.id) { _, last in
                    guard model.follow, let last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onChange(of: model.follow) { _, follow in
                    guard follow, let last = visible.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .overlay {
                if model.selected == nil {
                    ContentUnavailableView("Vyberte log", systemImage: "doc.text.magnifyingglass")
                } else if visible.isEmpty && model.readError == nil {
                    Group {
                        if needle.isEmpty && model.levelFilter == .all {
                            Text("Log je prázdny")
                        } else {
                            Text("Žiadne zodpovedajúce riadky")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func color(_ level: LogLine.Level) -> Color {
        switch level {
        case .normal: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    static func attributed(_ line: LogLine, highlight needle: String) -> AttributedString {
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        guard !needle.isEmpty else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = .yellow.opacity(0.45)
            searchRange = range.upperBound..<text.endIndex
        }
        return text
    }
}
