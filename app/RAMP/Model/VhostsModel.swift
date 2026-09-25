import Foundation
import Observation
import RAMPCore

/// Editable copy of a vhost for `VhostEditorSheet`. `id` is kept on edit.
struct VhostDraft: Identifiable, Equatable {
    struct Alias: Identifiable, Equatable {
        let id = UUID()
        var name: String
    }

    var id: UUID
    var isNew: Bool
    var domain: String
    var aliases: [Alias]
    var docroot: String
    /// `nil` = Apache default branch.
    var phpBranch: String?
    var enabled: Bool
    /// UI folder; "" = ungrouped.
    var group: String

    static func new() -> VhostDraft {
        VhostDraft(id: UUID(), isNew: true, domain: "", aliases: [], docroot: "", phpBranch: nil, enabled: true,
                   group: "")
    }

    init(id: UUID, isNew: Bool, domain: String, aliases: [Alias], docroot: String, phpBranch: String?, enabled: Bool,
         group: String) {
        self.id = id
        self.isNew = isNew
        self.domain = domain
        self.aliases = aliases
        self.docroot = docroot
        self.phpBranch = phpBranch
        self.enabled = enabled
        self.group = group
    }

    init(_ vhost: Vhost) {
        self.init(id: vhost.id, isNew: false, domain: vhost.domain, aliases: vhost.aliases.map { Alias(name: $0) },
                  docroot: vhost.docroot, phpBranch: vhost.phpBranch, enabled: vhost.enabled, group: vhost.group ?? "")
    }

    var vhost: Vhost {
        Vhost(id: id, domain: domain, aliases: aliases.map(\.name), docroot: docroot, phpBranch: phpBranch,
              enabled: enabled, group: Vhost.normalizeGroup(group))
    }
}

/// One group of the Vhosty list / menu bar list. `group == nil` = "Bez skupiny".
struct VhostSection: Identifiable, Equatable {
    var group: String?
    var vhosts: [Vhost]

    /// Stable key (also the UserDefaults collapse key); a real group can never be empty.
    var id: String { group ?? "" }

    /// Groups A–Z (case/number aware), ungrouped last; vhosts keep the incoming order.
    static func make(_ vhosts: [Vhost]) -> [VhostSection] {
        let byGroup = Dictionary(grouping: vhosts) { Vhost.normalizeGroup($0.group) }
        let named = byGroup.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var sections = named.map { VhostSection(group: $0, vhosts: byGroup[$0] ?? []) }
        if let ungrouped = byGroup[nil], !ungrouped.isEmpty { sections.append(VhostSection(group: nil, vhosts: ungrouped)) }
        return sections
    }
}

/// Outcome of a save from the editor sheet.
enum VhostSaveOutcome: Equatable {
    case saved
    /// Validation failed — shown inline in the sheet, nothing was written.
    case invalid([VhostIssue])
    /// Apache rejected / other error — reported through `AppModel.lastError`, sheet stays open.
    case failed
}

/// Vhosty section state. Every change goes through `VhostService` (validate → save → `httpd -t` + graceful
/// reload, rollback on rejection → hosts sync); a hosts failure leaves the vhost applied and shows "Retry".
@MainActor @Observable
final class VhostsModel {
    @ObservationIgnored weak var app: AppModel?

    var search = ""
    /// Short success confirmation shown at the bottom of Vhosty (auto-hides).
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Quick PHP filter from the column header (nil = all branches).
    var phpFilter: String?
    var editor: VhostDraft?
    /// Collapsed section keys (`VhostSection.id`), persisted per viewer in UserDefaults.
    private(set) var collapsedGroups: Set<String> = VhostsModel.loadCollapsed()
    static let collapsedGroupsKey = "vhostCollapsedGroups"
    private(set) var saving = false
    /// Vhost ids with a running enable / delete.
    private(set) var busy: Set<UUID> = []
    /// Ids whose docroot is missing on disk (red in the list).
    private(set) var missingDocroots: Set<UUID> = []

    // MARK: Derived

    var config: RampConfig { app?.config ?? RampConfig() }

    var vhosts: [Vhost] {
        config.vhosts.sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
    }

    var filtered: [Vhost] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var result = vhosts
        if let phpFilter {
            result = result.filter { effectivePHPBranch($0) == phpFilter }
        }
        guard !query.isEmpty else { return result }
        return result.filter { v in
            ([v.domain, v.docroot, v.group ?? ""] + v.aliases).contains { $0.localizedStandardContains(query) }
        }
    }

    /// Branch the vhost actually runs on (its own, else the default).
    func effectivePHPBranch(_ vhost: Vhost) -> String? { vhost.phpBranch ?? defaultPHPBranch }

    /// Branches in use by at least one vhost, with counts (for the header filter menu).
    var phpBranchesInUse: [(branch: String, count: Int)] {
        Dictionary(grouping: config.vhosts.compactMap { effectivePHPBranch($0) }, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// Directory prefix shared by all docroots (e.g. `/Users/me/Sites/`), hidden in the list as `…/`.
    /// nil when there is < 2 vhosts or the common part is shallower than two components.
    var docrootCommonPrefix: String? {
        let dirs = config.vhosts.map { URL(filePath: $0.docroot).standardizedFileURL.pathComponents }
        guard dirs.count >= 2, var common = dirs.first else { return nil }
        for components in dirs.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        // Keep at least one component of every path visible (never swallow a whole docroot).
        let shortest = dirs.map(\.count).min() ?? 0
        if common.count >= shortest { common = Array(common.prefix(shortest - 1)) }
        guard common.count > 2 else { return nil }   // "/" + ≥2 real components
        return NSString.path(withComponents: common) + "/"
    }

    /// Docroot as shown in the list: common prefix → `…/`, otherwise home → `~`.
    func displayDocroot(_ docroot: String) -> String {
        if let prefix = docrootCommonPrefix, docroot.hasPrefix(prefix) {
            return "…/" + docroot.dropFirst(prefix.count)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return docroot.hasPrefix(home + "/") ? "~" + docroot.dropFirst(home.count) : docroot
    }

    /// Existing group names, A–Z.
    var groups: [String] {
        Set(config.vhosts.compactMap { Vhost.normalizeGroup($0.group) })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `filtered` split into sections. Empty when nothing matches.
    var filteredSections: [VhostSection] { VhostSection.make(filtered) }

    /// `true` when at least one vhost has a group — otherwise the list is shown flat, without headers.
    var hasGroups: Bool { config.vhosts.contains { Vhost.normalizeGroup($0.group) != nil } }

    /// Collapsed state; a search expands every section so matches are always visible.
    func isExpanded(_ section: VhostSection) -> Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !collapsedGroups.contains(section.id)
    }

    func toggleExpanded(_ section: VhostSection) {
        if collapsedGroups.contains(section.id) {
            collapsedGroups.remove(section.id)
        } else {
            collapsedGroups.insert(section.id)
        }
        UserDefaults.standard.set(collapsedGroups.sorted(), forKey: Self.collapsedGroupsKey)
    }

    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedGroupsKey) ?? [])
    }

    /// Group proposed for a docroot from its folder under ~/Sites (`VhostGroupSuggester`).
    func suggestedGroup(docroot: String) -> String? {
        VhostGroupSuggester.suggest(docroot: docroot, sitesRoot: VhostGroupSuggester.sitesRoot())
    }

    /// How many ungrouped vhosts "Zoskupiť podľa priečinkov v Sites" would fill.
    var autoGroupCount: Int {
        VhostCatalog.autoGroup(config, sitesRoot: VhostGroupSuggester.sitesRoot()).changed.count
    }

    /// Effective default branch (`apache.defaultPHP` or the highest installed + enabled one).
    var defaultPHPBranch: String? {
        guard let app else { return nil }
        return try? ApacheConfigGenerator(config: config, paths: app.paths).defaultPHPBranch()
    }

    /// Installed + enabled PHP branches, numerically sorted.
    var phpBranches: [String] {
        (config.installed["php"] ?? [:]).keys
            .filter { config.php.branches[$0]?.enabled ?? true }
            .compactMap { b in PHPBranch(b).map { (b, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var hostsPendingReason: String? {
        guard config.hosts.manageHostsFile, case .pending(let reason) = app?.hostsHelper.lastSync else { return nil }
        return reason
    }

    var showHelperBanner: Bool {
        guard let app, config.hosts.manageHostsFile else { return false }
        return app.hostsHelper.status != .enabled
    }

    func normalizedDomain(_ input: String) -> String {
        Vhost.normalizeDomain(input, tld: config.hosts.defaultTLD)
    }

    // MARK: Lifecycle

    func onAppear() async {
        refreshMissing()
        await app?.hostsHelper.refreshStatus()
    }

    func refreshMissing() {
        #if DEBUG
        if ScreenshotMode.isActive { missingDocroots = []; return }   // demo docroots do not exist on disk
        #endif
        missingDocroots = Set(config.vhosts.filter { v in
            var isDir: ObjCBool = false
            return !FileManager.default.fileExists(atPath: v.docroot, isDirectory: &isDir) || !isDir.boolValue
        }.map(\.id))
    }

    /// Live validation of the sheet draft (read-only metadata checks): issues of the draft vhost only.
    func preview(_ draft: VhostDraft) -> [VhostIssue] {
        #if DEBUG
        if ScreenshotMode.isActive { return [] }
        #endif
        guard let app else { return [] }
        let candidate = VhostCatalog.normalized(draft.vhost, tld: config.hosts.defaultTLD)
        var next = config
        if let index = next.vhosts.firstIndex(where: { $0.id == draft.id }) {
            next.vhosts[index] = candidate
        } else {
            next.vhosts.append(candidate)
        }
        return VhostValidator(config: next, paths: app.paths).validate().filter { $0.vhostID == draft.id }
    }

    // MARK: Actions

    func startAdd() { editor = .new() }

    func startEdit(_ vhost: Vhost) { editor = VhostDraft(vhost) }

    func startEdit(id: UUID) {
        if let v = config.vhosts.first(where: { $0.id == id }) { startEdit(v) }
    }

    func save(_ draft: VhostDraft) async -> VhostSaveOutcome {
        guard let app, !saving else { return .failed }
        saving = true
        defer { saving = false }
        let service = app.vhostService
        let vhost = draft.vhost
        let isNew = draft.isNew
        let outcome = await perform(errorTitle: isNew ? String(localized: "Vhost sa nepodarilo pridať")
                                                      : String(localized: "Vhost sa nepodarilo uložiť")) {
            isNew ? try await service.add(vhost) : try await service.update(vhost)
        }
        if outcome == .saved {
            editor = nil
            showNotice(String(localized: "Uložené · Apache znovu načítaný (\(vhost.domain))"))
        }
        return outcome
    }

    func setEnabled(_ vhost: Vhost, _ enabled: Bool) async {
        guard let app, !busy.contains(vhost.id) else { return }
        busy.insert(vhost.id)
        defer { busy.remove(vhost.id) }
        let service = app.vhostService
        let id = vhost.id
        let outcome = await perform(errorTitle: String(localized: "Vhost sa nepodarilo prepnúť")) {
            try await service.setEnabled(id: id, enabled)
        }
        if outcome == .saved {
            showNotice(enabled ? String(localized: "\(vhost.domain) zapnutý · Apache znovu načítaný")
                               : String(localized: "\(vhost.domain) vypnutý · Apache znovu načítaný"))
        }
        if case .invalid(let issues) = outcome {
            app.report(title: String(localized: "Vhost sa nepodarilo prepnúť"),
                       message: issues.map(\.message).joined(separator: "\n"))
        }
    }

    func remove(_ vhost: Vhost) async {
        guard let app, !busy.contains(vhost.id) else { return }
        busy.insert(vhost.id)
        defer { busy.remove(vhost.id) }
        let service = app.vhostService
        let id = vhost.id
        let outcome = await perform(errorTitle: String(localized: "Vhost sa nepodarilo odstrániť")) {
            try await service.remove(id: id)
        }
        if outcome == .saved { showNotice(String(localized: "\(vhost.domain) odstránený · Apache znovu načítaný")) }
    }

    /// Moves vhosts into `group` (`nil` = "Bez skupiny"). UI-only: saved to ramp.json, Apache/hosts untouched.
    func move(_ ids: Set<UUID>, toGroup group: String?) async {
        guard let app, !ids.isEmpty else { return }
        do {
            try await app.vhostService.setGroup(ids: ids, group)
        } catch {
            app.report(title: String(localized: "Vhosty sa nepodarilo presunúť"), error: error)
        }
        await app.reloadConfig()
    }

    /// "Zoskupiť podľa priečinkov v Sites": fills the group of ungrouped vhosts only.
    func autoGroup() async {
        guard let app else { return }
        do {
            try await app.vhostService.autoGroup(sitesRoot: VhostGroupSuggester.sitesRoot())
        } catch {
            app.report(title: String(localized: "Vhosty sa nepodarilo zoskupiť"), error: error)
        }
        await app.reloadConfig()
    }

    /// "Skúsiť znova" in the hosts banner.
    func retryHosts() async {
        guard let app else { return }
        await app.hostsHelper.refreshStatus()
        app.hostsHelper.record(await app.vhostService.syncHosts())
    }

    /// "Povoliť pomocníka…": register + open System Settings › Login Items (polls the status).
    func approveHelper() async {
        await app?.hostsHelper.approve()
    }

    // MARK: Open actions (shared ProjectOpener)

    func openInBrowser(_ vhost: Vhost) {
        app?.opener.openInBrowser(vhost, config: config)
    }

    func open(_ vhost: Vhost, target: ProjectOpenTarget) {
        guard let app else { return }
        do {
            try app.opener.openProject(vhost, target: target)
        } catch {
            app.report(title: error.title, message: error.message)
        }
    }

    // MARK: private

    private func perform(errorTitle: String,
                         _ operation: @escaping @Sendable () async throws -> VhostChangeResult) async -> VhostSaveOutcome {
        guard let app else { return .failed }
        let result: Result<VhostChangeResult, any Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        await app.reloadConfig()
        refreshMissing()
        switch result {
        case .success(let change):
            app.hostsHelper.record(change.hosts)
            return .saved
        case .failure(let error as VhostValidationError):
            return .invalid(error.issues)
        case .failure(VhostServiceError.apacheRejected(let output)):
            app.report(title: String(localized: "Apache konfiguráciu odmietol — zmena bola vrátená späť"),
                       message: output)
            return .failed
        case .failure(let error):
            app.report(title: errorTitle, error: error)
            return .failed
        }
    }
}
