import Darwin
import Foundation
import RAMPCore

// rampctl update … (plan 07-02). With a running `rampctl up` the work is handed to it (request file in
// `run/update-requests/` + SIGUSR1, like `rampctl es`), so the affected service is restarted by the process that
// supervises it. Without `up`: applied here with a non-supervising controller (nothing runs → flip + offline checks);
// refused when RAMP services run under another process (RAMP.app).
//
//   rampctl update check [--manifest <url|path>]
//   rampctl update apply <component> <branch> | --all | --auto   [--manifest <url|path>]
//   rampctl update rollback <component> <branch>
// Exit: 0 all updated / nothing to do, 1 at least one rollback, 2 failure, 64 usage.

let updateUsageText = """
       rampctl update check [--manifest <url|path>]
       rampctl update apply <component> <branch> | --all | --auto [--manifest <url|path>]
       rampctl update rollback <component> <branch>
"""

private struct UpdateUsageError: Error {}

private func upOut(_ s: String) { print(s); fflush(stdout) }
private func upErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private func updateRequestDir(_ paths: Paths) -> URL {
    paths.runDir.appending(path: "update-requests", directoryHint: .isDirectory)
}

private func livePid(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
    else { return nil }
    return pid
}

/// Request handed to `rampctl up`.
struct UpdateRequest: Codable {
    enum Action: String, Codable { case apply, all, auto, rollback }
    var action: Action
    var component: String?
    var branch: String?
    var manifestURL: URL?
}

struct UpdateResponse: Codable {
    var code: Int32
    var lines: [String]
}

// MARK: Shared execution (client without `up`, or inside `up`)

/// Runs one request against `service`; returns exit code + report lines.
func performUpdate(_ request: UpdateRequest, service: UpdateService,
                   log: @escaping @Sendable (String) -> Void) async -> UpdateResponse {
    var lines: [String] = []
    func emit(_ s: String) { lines.append(s); log(s) }
    let manifest: Manifest?
    if let url = request.manifestURL {
        do { manifest = try await ManifestLoader.load(url) } catch {
            emit("error: manifest \(url.absoluteString): \(error.localizedDescription)")
            return UpdateResponse(code: 2, lines: lines)
        }
    } else {
        manifest = nil
    }

    if request.action == .rollback {
        guard let c = request.component, let b = request.branch else { return UpdateResponse(code: 64, lines: []) }
        let outcome = await service.rollbackToPrevious(component: c, branch: b)
        emit("\(c) \(b): rollback → \(outcome.message)")
        return UpdateResponse(code: code(for: [outcome]), lines: lines)
    }

    let plan: UpdatePlan
    do { plan = try await service.plan(manifest: manifest) } catch {
        emit("error: \(error.localizedDescription)")
        return UpdateResponse(code: 2, lines: lines)
    }
    let items: [UpdateItem]
    switch request.action {
    case .auto: items = plan.automatic
    case .all: items = plan.items.filter { $0.kind == .automatic || $0.kind == .offered }
    default:
        guard let item = plan.items.first(where: { $0.component == request.component && $0.branch == request.branch })
        else {
            emit("\(request.component ?? "?") \(request.branch ?? "?"): no update available")
            return UpdateResponse(code: 0, lines: lines)
        }
        items = [item]
    }
    if items.isEmpty { emit("nothing to update") }
    var outcomes: [UpdateOutcome] = []
    for item in items {
        let label = "\(item.component) \(item.branch)"
        emit("\(label): \(item.from ?? "—") → \(item.to) (\(item.kind))")
        let outcome = await service.apply(item, manifest: manifest) { step in
            if case .finished = step { return }
            log("  \(label): \(step)")
        }
        emit("\(label): \(outcome.message)")
        outcomes.append(outcome)
    }
    return UpdateResponse(code: code(for: outcomes), lines: lines)
}

private func code(for outcomes: [UpdateOutcome]) -> Int32 {
    if outcomes.contains(where: { if case .failed = $0 { true } else { false } }) { return 2 }
    if outcomes.contains(where: { if case .rolledBack = $0 { true } else { false } }) { return 1 }
    return 0
}

// MARK: Server side (inside `rampctl up`)

/// Serves `run/update-requests/*.req` for `rampctl up`; `wake()` on SIGUSR1. One request at a time.
final class UpdateRequestWorker: Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>

    init(controller: StackController, paths: Paths) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        let service = UpdateService(stack: controller)
        task = Task {
            for await _ in stream { await Self.drain(service: service, paths: paths) }
        }
        continuation.yield()
    }

    func wake() { continuation.yield() }

    func cancel() {
        continuation.finish()
        task.cancel()
    }

    private static func drain(service: UpdateService, paths: Paths) async {
        let fm = FileManager.default
        let dir = updateRequestDir(paths)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".req") }.sorted()
        for name in names {
            let req = dir.appending(path: name, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: req) else { continue }
            try? fm.removeItem(at: req)
            let response: UpdateResponse
            if let request = try? JSONDecoder().decode(UpdateRequest.self, from: data) {
                response = await performUpdate(request, service: service) { upOut("[update] \($0)") }
            } else {
                response = UpdateResponse(code: 64, lines: ["malformed update request"])
            }
            let res = dir.appending(path: String(name.dropLast(4)) + ".res", directoryHint: .notDirectory)
            if let out = try? JSONEncoder().encode(response) { try? out.write(to: res, options: .atomic) }
        }
    }
}

// MARK: Client

func updateCommand(_ args: [String]) async -> Int32 {
    let paths = Paths.standard()
    do {
        var rest = args
        var manifestURL: URL?
        if let i = rest.firstIndex(of: "--manifest") {
            guard i + 1 < rest.count else { throw UpdateUsageError() }
            manifestURL = manifestURLArgument(rest[i + 1])
            rest.removeSubrange(i...(i + 1))
        }
        guard let sub = rest.first else { throw UpdateUsageError() }
        let operands = Array(rest.dropFirst())
        switch sub {
        case "check":
            guard operands.isEmpty else { throw UpdateUsageError() }
            return await updateCheck(paths: paths, manifestURL: manifestURL)
        case "apply":
            let request: UpdateRequest
            switch operands {
            case ["--all"]: request = UpdateRequest(action: .all, manifestURL: manifestURL)
            case ["--auto"]: request = UpdateRequest(action: .auto, manifestURL: manifestURL)
            case let o where o.count == 2 && !o[0].hasPrefix("-"):
                request = UpdateRequest(action: .apply, component: o[0], branch: o[1], manifestURL: manifestURL)
            default: throw UpdateUsageError()
            }
            return await dispatch(request, paths: paths)
        case "rollback":
            guard operands.count == 2 else { throw UpdateUsageError() }
            return await dispatch(UpdateRequest(action: .rollback, component: operands[0], branch: operands[1]),
                                  paths: paths)
        default:
            throw UpdateUsageError()
        }
    } catch {
        upErr("usage:\n" + updateUsageText)
        return 64
    }
}

private func manifestURLArgument(_ raw: String) -> URL {
    if let url = URL(string: raw), let scheme = url.scheme, scheme == "file" || scheme == "https" { return url }
    let path = (raw as NSString).expandingTildeInPath
    return URL(filePath: path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path)
        .standardizedFileURL
}

private func updateCheck(paths: Paths, manifestURL: URL?) async -> Int32 {
    let store = ConfigStore(paths: paths)
    do {
        let config = try await store.load()
        guard let url = manifestURL ?? config.manifestURL else {
            upErr("error: no manifest configured (rampctl install --manifest … or --manifest)")
            return 2
        }
        let manifest = try await ManifestLoader.load(url)
        let plan = UpdatePolicy.plan(manifest: manifest, config: config)
        upOut("manifest: \(url.absoluteString)")
        if plan.isEmpty {
            upOut("everything is up to date")
            return 0
        }
        let header = ["KIND", "COMPONENT", "BRANCH", "INSTALLED", "AVAILABLE", "NOTE"]
        var rows = [header]
        for item in plan.items {
            var note: [String] = []
            if item.requiresDumpFirst { note.append("dump first") }
            if item.kind == .migration { note.append("migration, not applied by update") }
            rows.append([item.kind.description, item.component, item.branch, item.from ?? "—", item.to,
                         note.joined(separator: ", ")])
        }
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        for row in rows {
            upOut(row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        return 0
    } catch {
        upErr("error: \(error.localizedDescription)")
        return 2
    }
}

private func dispatch(_ request: UpdateRequest, paths: Paths) async -> Int32 {
    if let upPid = livePid(paths.runDir.appending(path: "rampctl.pid", directoryHint: .notDirectory)) {
        return await remote(request, paths: paths, upPid: upPid)
    }
    // No `up`: make sure nothing of ours runs under another supervisor (RAMP.app) before flipping `current`.
    if let config = try? await ConfigStore(paths: paths).load(),
       let specs = try? ServiceSpecFactory.specs(config: config, paths: paths) {
        let ids = specs.map(\.id) + [.elasticsearch]
        let running = ids.filter { livePid(paths.pidFile(service: $0.name)) != nil }
        if !running.isEmpty {
            upErr("error: \(running.map(\.name).joined(separator: ", ")) run under another RAMP process "
                + "(RAMP.app?) — apply the update there, or stop it first")
            return 2
        }
    }
    let controller = StackController(paths: paths, supervisor: ServiceSupervisor(paths: paths, cleanupOrphans: false))
    let response = await performUpdate(request, service: UpdateService(stack: controller)) { upOut($0) }
    return response.code
}

private func remote(_ request: UpdateRequest, paths: Paths, upPid: pid_t) async -> Int32 {
    let fm = FileManager.default
    let dir = updateRequestDir(paths)
    let id = UUID().uuidString
    let req = dir.appending(path: "\(id).req", directoryHint: .notDirectory)
    let res = dir.appending(path: "\(id).res", directoryHint: .notDirectory)
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(request).write(to: req, options: .atomic)
    } catch {
        upErr("error: cannot write the update request: \(error.localizedDescription)")
        return 2
    }
    guard kill(upPid, SIGUSR1) == 0 else {
        try? fm.removeItem(at: req)
        upErr("error: cannot signal rampctl up (pid \(upPid))")
        return 2
    }
    upOut("update handed to rampctl up (pid \(upPid))…")
    let deadline = ContinuousClock.now + .seconds(3600)
    while ContinuousClock.now < deadline {
        if let data = try? Data(contentsOf: res), let response = try? JSONDecoder().decode(UpdateResponse.self, from: data) {
            try? fm.removeItem(at: res)
            response.lines.forEach(upOut)
            return response.code
        }
        if kill(upPid, 0) != 0 { break }
        try? await Task.sleep(for: .milliseconds(200))
    }
    try? fm.removeItem(at: req)
    upErr("error: rampctl up (pid \(upPid)) did not answer the update request")
    return 2
}
