import AppKit
import Foundation
import Observation
import os
import RAMPCore
import Sparkle
import SwiftUI

private let updaterLog = Logger(subsystem: "sk.tyron.ramp", category: "updates")

/// Distribution values baked into Info.plist from `RAMP/Distribution.xcconfig` (08-03).
enum DistributionConfig {
    /// Sparkle feed URL (`SUFeedURL`), nil while it is still the OWNER placeholder.
    static var appcastURL: URL? { configuredURL("SUFeedURL") }

    /// `SUPublicEDKey` is a real key (not the TODO placeholder / empty).
    static var hasSparklePublicKey: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && !key.hasPrefix("TODO") && !key.hasPrefix("$(")
    }

    /// Default service manifest for fresh installs (`RAMPDefaultManifestURL`), nil until configured.
    static var defaultManifestURL: URL? { configuredURL("RAMPDefaultManifestURL") }

    private static func configuredURL(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty, !raw.contains("OWNER"), !raw.hasPrefix("$("),
              let url = URL(string: raw), url.scheme == "https"
        else { return nil }
        return url
    }
}

/// Sparkle 2 wrapper (08-03): `SPUStandardUpdaterController` + observable `canCheckForUpdates` for the
/// "Skontrolovať aktualizácie…" command, the menu bar and Nastavenia › Aplikácia.
///
/// Not started in DEBUG builds (no Sparkle prompts while developing from DerivedData) nor while the feed URL /
/// EdDSA public key are still placeholders (Sparkle would show a configuration error on every launch).
/// Services are updated separately through the manifest (07-02); Sparkle only replaces RAMP.app.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Why the updater is inactive, nil when running.
    let disabledReason: LocalizedStringKey?
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var isEnabled: Bool { disabledReason == nil }

    private init() {
        #if DEBUG
        let reason: LocalizedStringKey? = "Vývojová verzia – aktualizácie aplikácie sú vypnuté."
        #else
        let reason: LocalizedStringKey? =
            DistributionConfig.appcastURL == nil || !DistributionConfig.hasSparklePublicKey
            ? "Aktualizácie aplikácie nie sú v tejto verzii nakonfigurované." : nil
        #endif
        disabledReason = reason
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts Sparkle (scheduled checks per `SUScheduledCheckInterval`) — called once at launch.
    func start() {
        guard isEnabled, observations.isEmpty else {
            if let reason = disabledReason { updaterLog.notice("Sparkle not started: \(String(describing: reason), privacy: .public)") }
            return
        }
        controller.startUpdater()
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false   // SPUUpdater is main-actor isolated: use the change
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false   // SPUUpdater is main-actor isolated: use the change
                Task { @MainActor in self?.automaticallyChecksForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
        updaterLog.notice("Sparkle started, feed \(updater.feedURL?.absoluteString ?? "?", privacy: .public)")
    }

    func checkForUpdates() {
        guard isEnabled else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        guard isEnabled else { return }
        controller.updater.automaticallyChecksForUpdates = on
    }
}

/// App menu (after "O aplikácii RAMP") — "Skontrolovať aktualizácie…".
struct CheckForUpdatesCommand: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Button("Skontrolovať aktualizácie…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Menu bar popover row — only shown when Sparkle is active (release builds).
struct CheckForUpdatesMenuItem: View {
    private let updater = AppUpdater.shared

    var body: some View {
        if updater.isEnabled {
            Button("Skontrolovať aktualizácie aplikácie…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
                .controlSize(.small)
        }
    }
}

/// Nastavenia › Aplikácia (08-03): RAMP.app self-update via Sparkle (services: section Aktualizácie).
struct AppUpdateSettingsSection: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Section("Aplikácia") {
            if let reason = updater.disabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Automaticky kontrolovať aktualizácie aplikácie",
                   isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                 set: { updater.setAutomaticallyChecksForUpdates($0) }))
                .disabled(!updater.isEnabled)
            HStack {
                if let last = updater.lastCheck {
                    Text("Posledná kontrola: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skontrolovať aktualizácie…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// After Sparkle replaced RAMP.app the registered hosts helper may still be the previous build: ask it for its
/// version at launch and re-register the daemon on a mismatch (08-03; the on-demand path in
/// `HelperHostsSync.apply` does the same lazily).
enum HelperUpgradeCheck {
    static func run(_ helper: HelperHostsSync) async {
        guard let result = await helper.verifyRegisteredVersion() else { return }
        if result.reregistered {
            updaterLog.notice("hosts helper \(result.running, privacy: .public) ≠ bundled \(result.bundled, privacy: .public) → re-registered")
        } else {
            updaterLog.info("hosts helper version \(result.running, privacy: .public) is current")
        }
    }
}
