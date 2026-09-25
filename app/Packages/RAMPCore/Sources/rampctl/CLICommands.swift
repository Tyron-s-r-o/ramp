import Foundation
import RAMPCore

// rampctl cli … — terminal integration (~/.ramp/bin shims, PATH block in shell startup files, MAMP lines).
// Honors HOME (sandbox runs: HOME=/tmp/ramp-cli-home) and RAMP_HOME.
//
//   rampctl cli status                       shims, PATH block per file, MAMP conflicts, what a new login shell runs
//   rampctl cli install [--disable-mamp]     shims + PATH block (+ comment out MAMP php/composer/mysql lines)
//   rampctl cli uninstall                    remove shims + PATH blocks, re-enable MAMP lines RAMP disabled
//   rampctl cli default <branch>|auto        PHP behind `php` / `composer` (ramp.json cli.defaultPHP)
//   rampctl cli update-composer              download + verify Composer 2 stable
//   rampctl cli restore-mamp                 re-enable the MAMP lines RAMP disabled

let cliUsageText = """
       rampctl cli status | install [--disable-mamp] | uninstall | default <branch>|auto | update-composer | restore-mamp
"""

func cliCommand(_ args: [String]) async -> Int32 {
    let store = ConfigStore(paths: paths)
    let cli = CLIIntegration(paths: paths)
    let shell = cli.shell
    do {
        guard let sub = args.first else { usage() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "status":
            guard rest.isEmpty else { usage() }
            let config = try await store.load()
            let status = shell.status()
            out("shims:    \(cliPath(cli.shimDir))")
            out("          \(status.shims.isEmpty ? "(none)" : status.shims.joined(separator: " "))")
            out("php:      \(CLIShimGenerator.defaultBranch(config).map { "PHP \($0)" } ?? "-")"
                + (config.cli.defaultPHP == nil ? " (auto)" : ""))
            out("composer: " + (cli.composer.installedAt.map {
                "\(cliPath(paths.composerPhar)) (downloaded \($0.formatted(date: .abbreviated, time: .shortened)))"
            } ?? "not downloaded (rampctl cli update-composer)"))
            for f in status.files {
                out("block:    \(f.hasBlock ? "yes" : "no ")  \(cliPath(f.file))\(f.exists ? "" : " (missing)")")
            }
            for l in status.conflicts {
                let what = l.disableable ? "MAMP" : "MAMP (mixed PATH, left alone)"
                out("conflict: \(what) \(l.file.map { cliPath($0) } ?? ""):\(l.index + 1): \(l.text)")
            }
            for l in status.disabledLines {
                out("disabled: \(l.file.map { cliPath($0) } ?? ""):\(l.index + 1): \(l.text)")
            }
            let probed = await shell.probe()
            out("new login shell: php → \(probed ?? "(not found / timed out)")"
                + (shell.resolvesToRAMP(probed) ? "  [RAMP]" : "  [not RAMP]"))
        case "install":
            guard rest.allSatisfy({ $0 == "--disable-mamp" }) else { usage() }
            let config = try await store.load()
            let shims = try cli.syncShims(config: config)
            out("shims: \(shims.written.count) written, \(shims.removed.count) removed"
                + (shims.skipped.isEmpty ? "" : ", not managed (left alone): \(shims.skipped.joined(separator: " "))"))
            if !cli.composer.isInstalled {
                do {
                    try await cli.composer.update()
                    out("composer: downloaded \(cliPath(paths.composerPhar))")
                } catch {
                    err("warning: \(error.localizedDescription)")
                }
            }
            let report = try shell.install(disableMAMP: rest.contains("--disable-mamp"))
            printShellReport(report)
            let left = shell.status().blockingConflicts
            if !left.isEmpty {
                err("warning: \(left.count) MAMP line(s) still shadow RAMP (aliases beat PATH) — rerun with --disable-mamp:")
                for l in left { err("  \(l.file.map { cliPath($0) } ?? ""):\(l.index + 1): \(l.text)") }
            }
            out("open a new terminal (or: exec $SHELL -l) to use RAMP's php / composer / mysql")
        case "uninstall":
            guard rest.isEmpty else { usage() }
            printShellReport(try shell.uninstall(restoreMAMP: true))
            let removed = cli.removeShims()
            out("shims removed: \(removed.count)")
        case "default":
            guard rest.count == 1 else { usage() }
            let value = rest[0] == "auto" ? nil : rest[0]
            let config = try await store.load()
            if let value, !CLIShimGenerator.phpBranches(config).contains(value) {
                err("PHP \(value) is not installed and enabled (available: \(CLIShimGenerator.phpBranches(config).joined(separator: " ")))")
                return 2
            }
            let saved = try await store.update { $0.cli.defaultPHP = value }
            try cli.syncShims(config: saved)
            out("php → PHP \(CLIShimGenerator.defaultBranch(saved) ?? "-")\(value == nil ? " (auto)" : "")")
        case "update-composer":
            guard rest.isEmpty else { usage() }
            let sha = try await cli.composer.update()
            out("composer: \(cliPath(paths.composerPhar)) sha256 \(sha)")
        case "restore-mamp":
            guard rest.isEmpty else { usage() }
            printShellReport(try shell.restoreMAMP())
        default:
            usage()
        }
        return 0
    } catch {
        err("cli: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        return 1
    }
}

private func printShellReport(_ r: ShellIntegration.ChangeReport) {
    for f in r.modified { out("modified: \(cliPath(f))") }
    for b in r.backups { out("backup:   \(cliPath(b))") }
    for f in r.removedFiles { out("removed:  \(cliPath(f))") }
    if r.disabledMAMP > 0 { out("MAMP lines disabled: \(r.disabledMAMP)") }
    if r.restoredMAMP > 0 { out("MAMP lines re-enabled: \(r.restoredMAMP)") }
    if r.modified.isEmpty && r.removedFiles.isEmpty { out("shell files: no change") }
}

private func cliPath(_ url: URL) -> String { url.path(percentEncoded: false) }
