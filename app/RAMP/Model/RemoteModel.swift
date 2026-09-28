import Foundation
import Observation
import RAMPCore

/// Editable copy of a saved FTP/SFTP site for `FTPSiteEditorSheet`. Secrets are separate: an empty
/// password / passphrase on edit means "keep the stored one".
struct RemoteSiteDraft: Identifiable, Equatable {
    var id: UUID
    var isNew: Bool
    var name = ""
    /// "" = ungrouped.
    var group = ""
    var proto: RemoteProtocol = .ftpes
    var host = ""
    /// Text so the field can be empty (→ default port of the protocol).
    var port = String(RemoteProtocol.ftpes.defaultPort)
    var username = ""
    var auth: RemoteAuthKind = .password
    var password = ""
    var privateKeyPath = ""
    var keyPassphrase = ""
    var initialPath = ""
    var passive = true
    var allowInsecureCertificate = false
    var notes = ""

    static func new() -> RemoteSiteDraft { RemoteSiteDraft(id: UUID(), isNew: true) }

    init(id: UUID, isNew: Bool) {
        self.id = id
        self.isNew = isNew
    }

    init(_ site: RemoteSite) {
        id = site.id
        isNew = false
        name = site.name
        group = site.group ?? ""
        proto = site.proto
        host = site.host
        port = String(site.port)
        username = site.username
        auth = site.auth
        privateKeyPath = site.privateKeyPath ?? ""
        initialPath = site.initialPath ?? ""
        passive = site.passive
        allowInsecureCertificate = site.allowInsecureCertificate
        notes = site.notes ?? ""
    }

    var usesKey: Bool { proto == .sftp && auth == .privateKey }
    var usesTLS: Bool { proto == .ftpes || proto == .ftps }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    var portNumber: Int? {
        let text = port.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return proto.defaultPort }
        guard let n = Int(text), (1...65_535).contains(n) else { return nil }
        return n
    }

    var isValid: Bool { !trimmedHost.isEmpty && portNumber != nil && (!usesKey || !privateKeyPath.isEmpty) }

    var site: RemoteSite {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteSite(
            id: id, name: trimmedName.isEmpty ? trimmedHost : trimmedName, proto: proto, host: trimmedHost,
            port: portNumber ?? proto.defaultPort, username: username.trimmingCharacters(in: .whitespaces),
            auth: usesKey ? .privateKey : .password, privateKeyPath: usesKey ? privateKeyPath : nil,
            initialPath: path.isEmpty ? nil : path, passive: passive,
            allowInsecureCertificate: usesTLS && allowInsecureCertificate,
            group: RemoteModel.normalizeGroup(group), notes: note.isEmpty ? nil : note)
    }
}

/// One group of the FTP site list. `group == nil` = ungrouped.
struct RemoteSiteSection: Identifiable, Equatable {
    var group: String?
    var sites: [RemoteSite]
    var id: String { group ?? "" }

    /// Groups A–Z, ungrouped last; sites keep the incoming (sorted) order.
    static func make(_ sites: [RemoteSite]) -> [RemoteSiteSection] {
        let byGroup = Dictionary(grouping: sites) { RemoteModel.normalizeGroup($0.group) }
        let named = byGroup.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var sections = named.map { RemoteSiteSection(group: $0, sites: byGroup[$0] ?? []) }
        if let ungrouped = byGroup[nil], !ungrouped.isEmpty { sections.append(RemoteSiteSection(group: nil, sites: ungrouped)) }
        return sections
    }
}

/// Where a vault sheet has to be attached (a sheet can only be presented from the topmost sheet).
enum VaultPromptHost: Equatable { case main, editor, importer }

struct VaultPrompt: Identifiable, Equatable {
    enum Kind: Equatable { case setup, unlock }
    let id = UUID()
    var kind: Kind
    var host: VaultPromptHost
    /// Why the password is needed ("Uloženie hesla", "Pripojenie k …").
    var reason: String
}

/// Password / key passphrase asked for one connection (nothing stored, or the stored one was rejected).
struct SecretPrompt: Identifiable, Equatable {
    enum Field: Equatable { case password, passphrase }
    let id = UUID()
    var site: RemoteSite
    var field: Field
    /// Offer "Uložiť do trezora".
    var canSave = true
}

struct SecretPromptResult {
    var value: String
    var save: Bool
}

/// SFTP host key decision (unknown key or changed key).
struct HostKeyPrompt: Identifiable {
    let id = UUID()
    var error: RemoteError
    var siteID: UUID

    var isMismatch: Bool {
        if case .hostKeyMismatch = error { return true }
        return false
    }
}

/// FTP section: saved sites (plain metadata), the master-password vault and the one connected browser.
///
/// The vault is unlocked lazily (`ensureUnlocked`) — only when a secret is written or read — and stays
/// unlocked until the app quits or "Zamknúť". PBKDF2 always runs off the main thread.
@MainActor @Observable
final class RemoteModel {
    @ObservationIgnored weak var app: AppModel?
    let store: SiteStore
    let vault: SiteVault
    let knownHosts: KnownHosts

    private(set) var sites: [RemoteSite] = []
    var search = ""
    var selectedSiteID: UUID?
    private(set) var collapsedGroups: Set<String> = RemoteModel.loadCollapsed()
    static let collapsedGroupsKey = "remoteCollapsedGroups"

    private(set) var vaultInitialized = false
    private(set) var vaultUnlocked = false

    var editor: RemoteSiteDraft?
    var importing = false
    var pendingDelete: RemoteSite?
    /// Connecting another site while transfers run → confirm first.
    var pendingSwitch: RemoteSite?
    private(set) var vaultPrompt: VaultPrompt?
    private(set) var secretPrompt: SecretPrompt?
    var hostKeyPrompt: HostKeyPrompt?
    private(set) var browser: RemoteBrowserModel?
    private(set) var saving = false

    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var vaultContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var secretContinuation: CheckedContinuation<SecretPromptResult?, Never>?

    init(paths: Paths) {
        let dir = paths.remote
        store = SiteStore(url: dir.appending(path: "sites.json"))
        vault = SiteVault(url: dir.appending(path: "vault.json"))
        knownHosts = KnownHosts(fileURL: dir.appending(path: "known_hosts.json"))
    }

    // MARK: Derived

    var filtered: [RemoteSite] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sites }
        return sites.filter { s in
            [s.name, s.host, s.username, s.group ?? "", s.notes ?? ""].contains { $0.localizedStandardContains(query) }
        }
    }

    var filteredSections: [RemoteSiteSection] { RemoteSiteSection.make(filtered) }
    var hasGroups: Bool { sites.contains { Self.normalizeGroup($0.group) != nil } }

    var groups: [String] {
        Set(sites.compactMap { Self.normalizeGroup($0.group) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var selectedSite: RemoteSite? { sites.first { $0.id == selectedSiteID } }

    func site(id: UUID) -> RemoteSite? { sites.first { $0.id == id } }

    func isExpanded(_ section: RemoteSiteSection) -> Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !collapsedGroups.contains(section.id)
    }

    func toggleExpanded(_ section: RemoteSiteSection) {
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

    nonisolated static func normalizeGroup(_ group: String?) -> String? {
        guard let g = group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
        return g
    }

    // MARK: Lifecycle

    func onAppear() {
        #if DEBUG
        if ScreenshotMode.isRendering { loadDemo(); return }
        #endif
        reloadSites()
        refreshVaultState()
    }

    func reloadSites() {
        do {
            sites = try store.load()
        } catch {
            app?.report(title: String(localized: "Zoznam FTP prístupov sa nedá načítať"), error: error)
        }
    }

    func refreshVaultState() {
        vaultInitialized = vault.isInitialized
        vaultUnlocked = vault.isUnlocked
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Vault

    /// Unlocks (or sets up) the vault, asking the user when needed. `false` = the user cancelled.
    func ensureUnlocked(reason: String) async -> Bool {
        refreshVaultState()
        if vaultUnlocked { return true }
        #if DEBUG
        if ScreenshotMode.isRendering { return false }
        #endif
        vaultContinuation?.resume(returning: false)
        let host: VaultPromptHost = editor != nil ? .editor : (importing ? .importer : .main)
        return await withCheckedContinuation { continuation in
            vaultContinuation = continuation
            vaultPrompt = VaultPrompt(kind: vaultInitialized ? .unlock : .setup, host: host, reason: reason)
        }
    }

    func finishVaultPrompt(_ success: Bool) {
        vaultPrompt = nil
        refreshVaultState()
        let continuation = vaultContinuation
        vaultContinuation = nil
        continuation?.resume(returning: success && vaultUnlocked)
    }

    /// PBKDF2 (600k iterations) off the main thread.
    func unlockVault(password: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.unlock(masterPassword: password) }.value
        refreshVaultState()
    }

    func setupVault(password: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.setup(masterPassword: password) }.value
        refreshVaultState()
    }

    /// "Zabudnuté heslo": deletes every stored password; the prompt switches to setup.
    func resetVault() throws {
        try vault.reset()
        refreshVaultState()
        if let prompt = vaultPrompt {
            vaultPrompt = VaultPrompt(kind: .setup, host: prompt.host, reason: prompt.reason)
        }
    }

    func lockVault() {
        vault.lock()
        refreshVaultState()
        showNotice(String(localized: "Trezor s heslami je zamknutý"))
    }

    // MARK: Secret prompt (one-off password for a connection)

    func askSecret(_ prompt: SecretPrompt) async -> SecretPromptResult? {
        secretContinuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            secretContinuation = continuation
            secretPrompt = prompt
        }
    }

    func finishSecretPrompt(_ result: SecretPromptResult?) {
        secretPrompt = nil
        let continuation = secretContinuation
        secretContinuation = nil
        continuation?.resume(returning: result)
    }

    // MARK: Site CRUD

    func startAdd() {
        var draft = RemoteSiteDraft.new()
        if let group = selectedSite?.group { draft.group = group }
        editor = draft
    }

    func startEdit(_ site: RemoteSite) { editor = RemoteSiteDraft(site) }

    /// Group header › "Pridať do skupiny".
    func startAdd(inGroup group: String?) {
        var draft = RemoteSiteDraft.new()
        draft.group = group ?? ""
        editor = draft
    }

    // MARK: Groups (header context menu)

    /// Renames a group (merges into an existing one of the same name); "" / whitespace = ungroup.
    func renameGroup(_ old: String, to new: String) {
        let target = Self.normalizeGroup(new)
        guard target != old else { return }
        let updated = sites.map { site -> RemoteSite in
            var copy = site
            if copy.group == old { copy.group = target }
            return copy
        }
        do {
            try store.save(updated)
            sites = try store.load()
        } catch {
            app?.report(title: String(localized: "Skupinu sa nepodarilo premenovať"), error: error)
            return
        }
        if collapsedGroups.remove(old) != nil {
            collapsedGroups.insert(target ?? "")
            UserDefaults.standard.set(collapsedGroups.sorted(), forKey: Self.collapsedGroupsKey)
        }
    }

    /// "Zrušiť skupinu": its sites move to "Bez skupiny" (nothing is deleted).
    func ungroup(_ group: String) { renameGroup(group, to: "") }

    /// Saves metadata; a newly typed password / passphrase goes to the vault (asks for the master password).
    /// Returns `true` when the sheet can close.
    func save(_ draft: RemoteSiteDraft) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        let site = draft.site
        let newPassword = draft.usesKey ? "" : draft.password
        let newPassphrase = draft.usesKey ? draft.keyPassphrase : ""
        if !newPassword.isEmpty || !newPassphrase.isEmpty {
            guard await ensureUnlocked(reason: String(localized: "Heslo sa uloží zašifrované.")) else { return false }
            do {
                var secrets = (try vault.secrets(for: site.id)) ?? SiteSecrets()
                if !newPassword.isEmpty { secrets.password = newPassword }
                if !newPassphrase.isEmpty { secrets.keyPassphrase = newPassphrase }
                try vault.setSecrets(secrets, for: site.id)
            } catch {
                app?.report(title: String(localized: "Heslo sa nepodarilo uložiť"), error: error)
                return false
            }
        }
        let previous = sites.first { $0.id == site.id }
        do {
            sites = try store.upsert(site)
        } catch {
            app?.report(title: String(localized: "Prístup sa nepodarilo uložiť"), error: error)
            return false
        }
        // The open browser holds a snapshot of the site: a failed / pending one is simply dropped (the detail
        // then shows the edited site); a live session with changed connection settings is closed, so the next
        // connect uses the new protocol / host / login instead of the stale copy.
        if let browser, browser.site.id == site.id {
            let connectionChanged = previous.map { Self.connectionKey($0) != Self.connectionKey(site) } ?? true
            if browser.state != .connected || connectionChanged || !newPassword.isEmpty || !newPassphrase.isEmpty {
                disconnect()
            }
        }
        editor = nil
        selectedSiteID = site.id
        showNotice(String(localized: "Uložené: \(site.name)"))
        return true
    }

    func duplicate(_ site: RemoteSite) async {
        var copy = site
        copy.id = UUID()
        copy.name = String(localized: "\(site.name) (kópia)")
        refreshVaultState()
        if vaultInitialized, await ensureUnlocked(reason: String(localized: "Skopíruje sa aj uložené heslo.")),
           let secrets = try? vault.secrets(for: site.id) {
            try? vault.setSecrets(secrets, for: copy.id)
        }
        do {
            sites = try store.upsert(copy)
            selectedSiteID = copy.id
        } catch {
            app?.report(title: String(localized: "Prístup sa nepodarilo duplikovať"), error: error)
        }
    }

    func delete(_ site: RemoteSite) async {
        if browser?.site.id == site.id { disconnect() }
        refreshVaultState()
        // Secrets are encrypted — removing them needs the vault; cancelling leaves an orphaned blob only.
        if vaultInitialized, await ensureUnlocked(reason: String(localized: "Odstráni sa aj uložené heslo.")) {
            try? vault.removeSecrets(for: site.id)
        }
        do {
            sites = try store.delete(id: site.id)
            if selectedSiteID == site.id { selectedSiteID = nil }
            showNotice(String(localized: "Odstránené: \(site.name)"))
        } catch {
            app?.report(title: String(localized: "Prístup sa nepodarilo odstrániť"), error: error)
        }
    }

    /// Adds imported sites (+ their secrets) in one store write.
    func add(imported: [(RemoteSite, SiteSecrets?)], withSecrets: Bool) async throws -> Int {
        try store.save(sites + imported.map(\.0))
        sites = try store.load()
        let vault = vault
        let pairs = withSecrets ? imported.compactMap { site, secrets in secrets.map { (site.id, $0) } } : []
        if !pairs.isEmpty {
            try await Task.detached(priority: .userInitiated) {
                for (id, secrets) in pairs { try vault.setSecrets(secrets, for: id) }
            }.value
        }
        return imported.count
    }

    /// Duplicate key for the FileZilla import (same protocol, host, port, user and name).
    nonisolated static func duplicateKey(_ s: RemoteSite) -> String {
        [s.proto.rawValue, s.host.lowercased(), String(s.port), s.username, s.name].joined(separator: "\u{1F}")
    }

    // MARK: Connection

    /// Everything that affects how a session is opened (name, group, notes don't).
    private static func connectionKey(_ s: RemoteSite) -> [String] {
        [s.proto.rawValue, s.host, String(s.port), s.username, s.auth.rawValue, s.privateKeyPath ?? "",
         s.initialPath ?? "", String(s.passive), String(s.allowInsecureCertificate)]
    }

    func connect(_ site: RemoteSite) {
        if let browser, browser.site.id != site.id, browser.hasActiveJobs {
            pendingSwitch = site
            return
        }
        Task { await connectNow(site) }
    }

    func connectNow(_ site: RemoteSite) async {
        pendingSwitch = nil
        selectedSiteID = site.id
        if let browser, browser.site.id == site.id, browser.state == .connected { return }
        browser?.disconnect()
        let browser = RemoteBrowserModel(site: site, knownHosts: knownHosts)
        browser.owner = self
        self.browser = browser
        guard let secrets = await secretsForConnect(site), self.browser === browser else {
            if self.browser === browser { self.browser = nil }
            return
        }
        browser.secrets = secrets.value
        await browser.connect()
    }

    func disconnect() {
        browser?.disconnect()
        browser = nil
    }

    /// nil = the user cancelled; `.some(nil)` = connect without secrets.
    private func secretsForConnect(_ site: RemoteSite) async -> Box<SiteSecrets?>? {
        if Self.isAnonymous(site) { return Box(nil) }
        refreshVaultState()
        var secrets: SiteSecrets?
        if vaultInitialized {
            let reason = String(localized: "Pripojenie k \(site.name)")
            guard await ensureUnlocked(reason: reason) else { return nil }
            secrets = try? vault.secrets(for: site.id)
        }
        if site.auth == .password, (secrets?.password ?? "").isEmpty {
            guard let entered = await askAndStoreSecret(site: site, field: .password) else { return nil }
            secrets = entered
        }
        return Box(secrets)
    }

    /// Asks for a password / passphrase; optionally stores it in the vault. Returns the merged secrets.
    func askAndStoreSecret(site: RemoteSite, field: SecretPrompt.Field) async -> SiteSecrets? {
        guard let result = await askSecret(SecretPrompt(site: site, field: field)) else { return nil }
        refreshVaultState()
        let stored: SiteSecrets? = vaultUnlocked ? (try? vault.secrets(for: site.id)) : nil
        var secrets = stored ?? SiteSecrets()
        switch field {
        case .password: secrets.password = result.value
        case .passphrase: secrets.keyPassphrase = result.value
        }
        if result.save {
            try? await Task.sleep(for: .milliseconds(350))   // let the password sheet finish dismissing
            if await ensureUnlocked(reason: String(localized: "Heslo sa uloží zašifrované.")) {
                do {
                    try vault.setSecrets(secrets, for: site.id)
                } catch {
                    app?.report(title: String(localized: "Heslo sa nepodarilo uložiť"), error: error)
                }
            }
        }
        return secrets
    }

    /// Browser asks again for credentials (missing secret / rejected password).
    func retryWithNewSecret(_ browser: RemoteBrowserModel, field: SecretPrompt.Field) async {
        guard let secrets = await askAndStoreSecret(site: browser.site, field: field), self.browser === browser else { return }
        browser.secrets = secrets
        await browser.connect()
    }

    func handleHostKey(_ error: RemoteError, for browser: RemoteBrowserModel) {
        hostKeyPrompt = HostKeyPrompt(error: error, siteID: browser.site.id)
    }

    /// "Dôverovať a pripojiť".
    func trustHostKey(_ prompt: HostKeyPrompt) {
        hostKeyPrompt = nil
        guard case .unknownHostKey(let host, let port, let fingerprint) = prompt.error else { return }
        do {
            try knownHosts.trust(host: host, port: port, fingerprint: fingerprint)
        } catch {
            app?.report(title: String(localized: "Kľúč servera sa nepodarilo uložiť"), error: error)
            return
        }
        if let browser, browser.site.id == prompt.siteID { Task { await browser.connect() } }
    }

    /// Destructive secondary action on a changed key: forget it, reconnect → the unknown-key prompt asks again.
    func forgetHostKey(_ prompt: HostKeyPrompt) {
        hostKeyPrompt = nil
        guard case .hostKeyMismatch(let host, let port, _, _) = prompt.error else { return }
        do {
            try knownHosts.forget(host: host, port: port)
        } catch {
            app?.report(title: String(localized: "Kľúč servera sa nepodarilo odstrániť"), error: error)
            return
        }
        if let browser, browser.site.id == prompt.siteID { Task { await browser.connect() } }
    }

    nonisolated static func isAnonymous(_ site: RemoteSite) -> Bool {
        site.proto != .sftp && ["anonymous", "ftp"].contains(site.username.lowercased())
    }

    nonisolated static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Demo (screenshots)

    #if DEBUG
    private func loadDemo() {
        sites = DemoData.remoteSites
        vaultInitialized = true
        vaultUnlocked = true
        guard let site = sites.first(where: { $0.name == DemoData.remoteConnectedSite }) else { return }
        selectedSiteID = site.id
        let browser = RemoteBrowserModel(site: site, knownHosts: knownHosts)
        browser.owner = self
        browser.loadDemo()
        self.browser = browser
    }
    #endif
}

/// Distinguishes "cancelled" (nil) from "no value" (`Box(nil)`).
struct Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
