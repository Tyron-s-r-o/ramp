import Foundation
import Observation
import RAMPCore

/// Nastavenia (05-06). App-only preferences live in UserDefaults (`@AppStorage` in the view: hideDockIcon,
/// optionClickTarget, AppleLanguages); stack settings are a draft of ramp.json saved through `ConfigStore` +
/// `StackController.applyConfigChanges()` so rampctl sees the same values.
@MainActor @Observable
final class SettingsModel {
    @ObservationIgnored weak var app: AppModel?

    let loginItem = LoginItem()

    /// Stack settings draft (text fields → validated on save).
    struct Draft: Equatable {
        var apachePort = ""
        var defaultPHP: String?
        var tld = ""
        var manageHostsFile = true
        var mysqlPort = ""
        var redisPort = ""
        var rootPassword = ""
        var tmpSocketSymlink = true
    }

    enum Field: Hashable {
        case apachePort, mysqlPort, redisPort, tld, rootPassword
    }

    var draft = Draft()
    private(set) var loaded = Draft()
    private(set) var errors: [Field: String] = [:]
    private(set) var isSaving = false
    /// Transient "Uložené" confirmation.
    private(set) var savedAt: Date?

    var isDirty: Bool { draft != loaded }
    var mysqlInitialized: Bool { app?.config.mysql.initialized ?? false }
    /// Installed PHP branches, highest first.
    var phpBranches: [String] {
        (app?.config.installed["php"].map { Array($0.keys) } ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Fills the draft from the current config (on appear and after save); unsaved edits are kept unless `force`.
    func load(force: Bool = false) {
        guard let config = app?.config else { return }
        let fresh = Draft(
            apachePort: String(config.apache.port),
            defaultPHP: config.apache.defaultPHP,
            tld: config.hosts.defaultTLD,
            manageHostsFile: config.hosts.manageHostsFile,
            mysqlPort: String(config.mysql.port),
            redisPort: String(config.redis.port),
            rootPassword: config.mysql.rootPassword,
            tmpSocketSymlink: config.mysql.tmpSocketSymlink)
        if force || !isDirty { draft = fresh }
        loaded = fresh
    }

    func revert() {
        draft = loaded
        errors = [:]
    }

    // MARK: Validation

    struct Validated: Sendable {
        var apachePort: Int, mysqlPort: Int, redisPort: Int
        var defaultPHP: String?
        var tld: String
        var manageHostsFile: Bool
        var rootPassword: String?
        var tmpSocketSymlink: Bool
    }

    func validate() -> Validated? {
        var errors: [Field: String] = [:]
        func port(_ text: String, _ field: Field) -> Int {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let value = Int(trimmed), (1...65535).contains(value) else {
                errors[field] = String(localized: "Port musí byť číslo 1–65535")
                return 0
            }
            guard value != 443 else {
                errors[field] = String(localized: "Port 443 je vyhradený pre HTTPS")
                return 0
            }
            return value
        }
        let apache = port(draft.apachePort, .apachePort)
        let mysql = port(draft.mysqlPort, .mysqlPort)
        let redis = port(draft.redisPort, .redisPort)
        let duplicate = String(localized: "Port už používa iná služba")
        if errors[.mysqlPort] == nil, mysql == apache { errors[.mysqlPort] = duplicate }
        if errors[.redisPort] == nil, redis == apache || redis == mysql { errors[.redisPort] = duplicate }

        let tld = draft.tld.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n")).lowercased()
        if tld.wholeMatch(of: /[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?/) == nil {
            errors[.tld] = String(localized: "TLD môže obsahovať len písmená, číslice a pomlčku (napr. local)")
        }
        var password: String?
        if !mysqlInitialized {
            if draft.rootPassword.isEmpty {
                errors[.rootPassword] = String(localized: "Heslo nesmie byť prázdne")
            } else if draft.rootPassword.contains(where: \.isNewline) {
                errors[.rootPassword] = String(localized: "Heslo nesmie obsahovať nový riadok")
            }
            password = draft.rootPassword
        }
        self.errors = errors
        guard errors.isEmpty else { return nil }
        return Validated(apachePort: apache, mysqlPort: mysql, redisPort: redis, defaultPHP: draft.defaultPHP,
                         tld: tld, manageHostsFile: draft.manageHostsFile, rootPassword: password,
                         tmpSocketSymlink: draft.tmpSocketSymlink)
    }

    // MARK: Save

    /// "Uložiť": ramp.json → `applyConfigChanges()` (Apache graceful / service restart per 02-05) → hosts sync.
    func save() async {
        guard let app, !isSaving, let v = validate() else { return }
        isSaving = true
        defer { isSaving = false }
        let hostsWasManaged = app.config.hosts.manageHostsFile
        do {
            try await app.configStore.update { config in
                config.apache.port = v.apachePort
                config.apache.defaultPHP = v.defaultPHP
                config.hosts.defaultTLD = v.tld
                config.hosts.manageHostsFile = v.manageHostsFile
                config.mysql.port = v.mysqlPort
                config.redis.port = v.redisPort
                config.mysql.tmpSocketSymlink = v.tmpSocketSymlink
                // Only before the datadir exists; afterwards the password is changed in MySQL itself.
                if let password = v.rootPassword, !config.mysql.initialized { config.mysql.rootPassword = password }
            }
        } catch {
            app.report(title: String(localized: "Nastavenia sa nepodarilo uložiť"), error: error)
            return
        }
        do {
            let report = try await app.stack.applyConfigChanges()
            if !report.errors.isEmpty {
                app.report(title: String(localized: "Niektoré služby odmietli novú konfiguráciu"),
                           message: report.errors.sorted { $0.key.description < $1.key.description }
                               .map { "\($0.key.description): \($0.value)" }.joined(separator: "\n"))
            }
        } catch {
            app.report(title: String(localized: "Konfiguráciu sa nepodarilo použiť"), error: error)
        }
        await app.reloadConfig()
        if hostsWasManaged && !v.manageHostsFile {
            // No longer managed → remove RAMP's block instead of leaving stale entries behind.
            do {
                _ = try await app.hostsHelper.syncer.apply(names: [])
            } catch {
                app.report(title: String(localized: "Súbor /etc/hosts nie je aktuálny"), error: error)
            }
        } else {
            await app.syncHosts()
        }
        load(force: true)
        savedAt = .now
    }
}
