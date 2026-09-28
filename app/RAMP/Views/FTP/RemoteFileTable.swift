import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAMPCore

/// Callbacks of the file table (all on the main actor).
struct RemoteFileTableActions {
    var open: (RemoteItem) -> Void
    var download: ([RemoteItem]) -> Void
    var rename: (RemoteItem) -> Void
    var delete: ([RemoteItem]) -> Void
    var newFolder: () -> Void
    var copyPath: ([RemoteItem]) -> Void
    var refresh: () -> Void
    var goUp: () -> Void
    /// Files / folders dropped from Finder → upload into the remote folder.
    var drop: ([URL], String) -> Void
    /// Row dragged to Finder: download `item` to the destination URL, call completion when done.
    var promise: (RemoteItem, URL, @escaping @Sendable (Error?) -> Void) -> Void
}

/// Remote listing as an `NSTableView` (AppKit on purpose): multi-selection, sortable columns, context menu,
/// drops from Finder (into the folder or onto a folder row) and dragging rows OUT to Finder as lazy
/// `NSFilePromiseProvider`s — the download starts only when the drop lands, into the folder Finder names.
struct RemoteFileTable: NSViewRepresentable {
    let items: [RemoteItem]
    let path: String
    let actions: RemoteFileTableActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = RemoteTableView()
        let coordinator = context.coordinator
        table.keyHandler = coordinator
        for column in Column.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            col.minWidth = column.minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .size { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 22
        table.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        table.setAccessibilityLabel(String(localized: "Súbory na serveri"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        coordinator.table = table
        coordinator.update(items: items, path: path)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.update(items: items, path: path)
    }

    enum Column: String, CaseIterable {
        case name, size, modified, permissions

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var title: String {
            switch self {
            case .name: String(localized: "Názov")
            case .size: String(localized: "Veľkosť")
            case .modified: String(localized: "Zmenené")
            case .permissions: String(localized: "Práva")
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 320
            case .size: 90
            case .modified: 150
            case .permissions: 100
            }
        }
        var minWidth: CGFloat { self == .name ? 160 : 60 }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, RemoteTableKeyHandler {
        var actions: RemoteFileTableActions
        weak var table: NSTableView?
        private var source: [RemoteItem] = []
        private var rows: [RemoteItem] = []
        private var path = ""
        private let promiseDelegate = RemotePromiseDelegate()
        private var iconCache: [String: NSImage] = [:]

        private static let sizeFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        init(actions: RemoteFileTableActions) {
            self.actions = actions
            super.init()
            promiseDelegate.onPromise = { [weak self] item, url, completion in
                guard let self else {
                    completion(CocoaError(.userCancelled))
                    return
                }
                self.actions.promise(item, url, completion)
            }
        }

        /// Called from `updateNSView`, which SwiftUI may run while the table is inside one of its own
        /// delegate / data-source callouts (a drop, a selection change) — reloading synchronously there is
        /// "reentrant" (AppKit warns, and will assert). Apply on the next main-loop turn instead.
        func update(items: [RemoteItem], path: String) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(items: items, path: path) }
            }
        }

        private func apply(items: [RemoteItem], path: String) {
            guard let table else { return }
            let pathChanged = path != self.path
            guard pathChanged || items != source else { return }
            let selected = pathChanged ? [] : Set(selectedItems().map(\.path))
            source = items
            self.path = path
            rows = sorted(items, by: table.sortDescriptors.first)
            table.reloadData()
            let indexes = IndexSet(rows.indices.filter { selected.contains(rows[$0].path) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            if pathChanged { table.scrollRowToVisible(0) }
        }

        /// Folders first, then by the chosen column (names Finder-like).
        private func sorted(_ items: [RemoteItem], by descriptor: NSSortDescriptor?) -> [RemoteItem] {
            let key = Column(rawValue: descriptor?.key ?? "") ?? .name
            let ascending = descriptor?.ascending ?? true
            return items.sorted { a, b in
                let da = a.kind == .directory, db = b.kind == .directory
                if da != db { return da }
                let order: ComparisonResult
                switch key {
                case .name: order = a.name.localizedStandardCompare(b.name)
                case .size: order = Self.compare(a.size ?? -1, b.size ?? -1)
                case .modified: order = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
                case .permissions: order = (a.permissions ?? "").compare(b.permissions ?? "")
                }
                if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }

        private func selectedItems() -> [RemoteItem] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        /// Right-click target: the clicked row's selection (or just the clicked row), else nothing.
        private func clickedItems() -> [RemoteItem] {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return [] }
            if table.selectedRowIndexes.contains(table.clickedRow) { return selectedItems() }
            return [rows[table.clickedRow]]
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let item = rows[row]
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? RemoteCellView)
                ?? RemoteCellView(identifier: tableColumn.identifier, withIcon: column == .name)
            switch column {
            case .name:
                cell.textField?.stringValue = item.name
                cell.imageView?.image = icon(for: item)
                cell.textField?.textColor = item.kind == .symlink ? .secondaryLabelColor : .labelColor
                cell.toolTip = item.kind == .symlink ? String(localized: "Symbolický odkaz (pri sťahovaní sa preskočí)") : item.path
            case .size:
                cell.textField?.stringValue = item.kind == .directory ? "—" : item.size.map { Self.sizeFormatter.string(fromByteCount: $0) } ?? ""
                cell.textField?.alignment = .right
                cell.textField?.textColor = .secondaryLabelColor
            case .modified:
                cell.textField?.stringValue = item.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
                cell.textField?.textColor = .secondaryLabelColor
            case .permissions:
                cell.textField?.stringValue = item.permissions ?? ""
                cell.textField?.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                cell.textField?.textColor = .secondaryLabelColor
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selected = Set(selectedItems().map(\.path))
            rows = sorted(source, by: tableView.sortDescriptors.first)
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].path) }),
                                       byExtendingSelection: false)
        }

        private func icon(for item: RemoteItem) -> NSImage {
            let key: String
            let type: UTType
            switch item.kind {
            case .directory:
                key = "/dir"
                type = .folder
            case .symlink:
                key = "/link"
                type = .symbolicLink
            case .file:
                let ext = (item.name as NSString).pathExtension.lowercased()
                key = ext
                type = UTType(filenameExtension: ext) ?? .data
            }
            if let cached = iconCache[key] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            image.size = NSSize(width: 16, height: 16)
            iconCache[key] = image
            return image
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            actions.open(rows[row])
        }

        // MARK: Keyboard

        func handleKey(_ event: NSEvent) -> Bool {
            let items = selectedItems()
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 36, 76:   // Return / Enter → open a single folder
                if items.count == 1 { actions.open(items[0]); return true }
            case 51 where command, 117:   // ⌘⌫ / forward delete
                if !items.isEmpty { actions.delete(items); return true }
            case 126 where command:   // ⌘↑
                actions.goUp()
                return true
            case 125 where command:   // ⌘↓
                if items.count == 1 { actions.open(items[0]); return true }
            default:
                break
            }
            return false
        }

        // MARK: Drag out (file promises)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < rows.count, rows[row].kind != .symlink else { return nil }
            let item = rows[row]
            let type = item.kind == .directory ? UTType.folder
                : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promiseDelegate)
            provider.userInfo = RemotePromiseInfo(item: item)
            return provider
        }

        // MARK: Drop in (Finder → upload)

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
            if dropOperation == .on, row >= 0, row < rows.count, rows[row].kind == .directory {
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)   // whole table = current folder
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let target = (row >= 0 && row < rows.count && rows[row].kind == .directory && dropOperation == .on)
                ? rows[row].path : path
            let drop = actions.drop
            DispatchQueue.main.async { drop(urls, target) }   // leave the drag callout before SwiftUI state changes
            return true
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let items = clickedItems()
            if items.count == 1, items[0].kind != .file {
                menu.addItem(ClosureMenuItem(String(localized: "Otvoriť"), symbol: "folder") { [weak self] in self?.actions.open(items[0]) })
                menu.addItem(.separator())
            }
            if !items.isEmpty {
                let downloadable = items.filter { $0.kind != .symlink }
                let download = ClosureMenuItem(String(localized: "Stiahnuť…"), symbol: "arrow.down.circle") { [weak self] in
                    self?.actions.download(downloadable)
                }
                download.isEnabled = !downloadable.isEmpty
                menu.addItem(download)
                if items.count == 1 {
                    menu.addItem(ClosureMenuItem(String(localized: "Premenovať…"), symbol: "pencil") { [weak self] in
                        self?.actions.rename(items[0])
                    })
                }
                menu.addItem(ClosureMenuItem(String(localized: "Kopírovať cestu"), symbol: "doc.on.doc") { [weak self] in
                    self?.actions.copyPath(items)
                })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(String(localized: "Zmazať…"), symbol: "trash") { [weak self] in
                    self?.actions.delete(items)
                })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(String(localized: "Nový priečinok…"), symbol: "folder.badge.plus") { [weak self] in
                self?.actions.newFolder()
            })
            menu.addItem(ClosureMenuItem(String(localized: "Obnoviť zoznam"), symbol: "arrow.clockwise") { [weak self] in
                self?.actions.refresh()
            })
        }
    }
}

// MARK: - Table view

@MainActor
protocol RemoteTableKeyHandler: AnyObject {
    func handleKey(_ event: NSEvent) -> Bool
}

final class RemoteTableView: NSTableView {
    weak var keyHandler: (any RemoteTableKeyHandler)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Text cell with an optional leading icon (name column).
final class RemoteCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)
        textField = text
        var constraints = [text.centerYAnchor.constraint(equalTo: centerYAnchor),
                           text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)]
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            addSubview(image)
            imageView = image
            constraints += [image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                            image.centerYAnchor.constraint(equalTo: centerYAnchor),
                            image.widthAnchor.constraint(equalToConstant: 16),
                            image.heightAnchor.constraint(equalToConstant: 16),
                            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// NSMenuItem running a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - File promises

/// `userInfo` of one dragged row.
final class RemotePromiseInfo: NSObject, Sendable {
    let item: RemoteItem
    init(item: RemoteItem) { self.item = item }
}

/// Writes promised files on its own queue: the write blocks that queue until the browser's transfer job has
/// downloaded the item (Finder keeps the destination coordinated until the completion handler runs).
final class RemotePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    /// Main actor only: starts the download (`RemoteBrowserModel.promiseDownload`).
    @MainActor var onPromise: ((RemoteItem, URL, @escaping @Sendable (Error?) -> Void) -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "sk.tyron.ramp.remote-promises"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 8
        return q
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? RemotePromiseInfo)?.item.name ?? "download"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        guard let item = (filePromiseProvider.userInfo as? RemotePromiseInfo)?.item else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let result = PromiseResult()
        Task { @MainActor [weak self] in
            guard let onPromise = self?.onPromise else {
                result.finish(CocoaError(.userCancelled))
                return
            }
            onPromise(item, url) { error in result.finish(error) }
        }
        completionHandler(result.wait())
    }
}

/// One-shot result the promise queue waits for.
private final class PromiseResult: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: (any Error)?
    private var finished = false

    func finish(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.error = error
        semaphore.signal()
    }

    func wait() -> (any Error)? {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
