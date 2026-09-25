import Foundation
import os
import RAMPHostsKit
import Synchronization

let helperLog = Logger(subsystem: RAMPHostsHelper.label, category: "helper")

/// Exits the helper after `delay` seconds without in-flight requests; launchd relaunches it on demand
/// (which also picks up an updated binary from the app bundle).
final class IdleExit: Sendable {
    private struct State {
        var inFlight = 0
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())
    private let delay: DispatchTimeInterval

    init(delay: DispatchTimeInterval = .seconds(30)) {
        self.delay = delay
    }

    func begin() {
        state.withLock {
            $0.inFlight += 1
            $0.generation &+= 1
        }
    }

    func end() {
        state.withLock { $0.inFlight -= 1 }
        arm()
    }

    /// Schedules an exit unless another request starts before the delay elapses.
    func arm() {
        let armed = state.withLock {
            $0.generation &+= 1
            return $0.generation
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let idle = state.withLock { $0.inFlight == 0 && $0.generation == armed }
            if idle {
                helperLog.notice("idle, exiting")
                exit(0)
            }
        }
    }
}

/// The helper's only exported object. Exactly two operations: `version` and `setHostsBlock`.
/// The target path is a constant (`HostsFileWriter.systemHostsPath`), never supplied by the client;
/// hostnames are validated by RAMPHostsKit before anything is written. All writes are serialized on `queue`.
/// Sendable without `@unchecked`: only immutable, Sendable stored properties.
final class HelperService: NSObject, RAMPHostsHelperProtocol, Sendable {
    private let queue = DispatchQueue(label: "sk.tyron.ramp.hostshelper.write")
    private let idle: IdleExit

    init(idle: IdleExit) {
        self.idle = idle
    }

    func version(withReply reply: @escaping @Sendable (String) -> Void) {
        idle.begin()
        reply(RAMPHostsHelper.version)
        idle.end()
    }

    func setHostsBlock(_ names: [String], withReply reply: @escaping @Sendable (String?) -> Void) {
        idle.begin()
        guard names.count <= Hostname.maxNames else {
            helperLog.error("rejected setHostsBlock: \(names.count) names (max \(Hostname.maxNames))")
            reply(HostsError.tooManyNames(names.count).localizedDescription)
            idle.end()
            return
        }
        queue.async { [idle] in
            defer { idle.end() }
            do {
                let writer = HostsFileWriter(path: URL(filePath: HostsFileWriter.systemHostsPath))
                let changed = try writer.apply(names: names)
                if changed { Self.flushDNSCache() }
                helperLog.notice("setHostsBlock: \(names.count) names, \(changed ? "changed" : "unchanged", privacy: .public)")
                reply(nil)
            } catch {
                helperLog.error("setHostsBlock failed (\(names.count) names): \(error.localizedDescription, privacy: .public)")
                reply(error.localizedDescription)
            }
        }
    }

    /// Fixed argv, empty environment, no shell.
    private static func flushDNSCache() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                helperLog.error("\(executable, privacy: .public) exited \(process.terminationStatus)")
            }
        } catch {
            helperLog.error("\(executable, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Accepts connections (already filtered by the listener's code-signing requirement) and exports `HelperService`.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RAMPHostsHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
