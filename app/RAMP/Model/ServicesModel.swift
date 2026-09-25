import Foundation
import Observation
import RAMPCore

/// One row of the Services section.
struct ServiceRowState: Identifiable, Equatable {
    var id: ServiceID
    var displayName: String
    var state: ServiceState
    /// TCP port (nil for FPM — unix socket).
    var port: Int?

    var since: Date? { if case .running(_, let since) = state { since } else { nil } }
    var isTransitioning: Bool {
        switch state {
        case .starting, .stopping: true
        default: false
        }
    }
    /// Apache (SIGUSR1) and PHP-FPM (SIGUSR2) support graceful reload.
    var isReloadable: Bool {
        switch id {
        case .apache, .phpFPM: true
        default: false
        }
    }
}

/// Mirrors the supervisor for the Services section and the menu bar. The ONLY consumer of
/// `StackController.events` (an `AsyncStream` supports one subscriber).
@MainActor @Observable
final class ServicesModel {
    private(set) var rows: [ServiceRowState] = []
    private(set) var health = StackHealth(level: .stopped)
    @ObservationIgnored weak var app: AppModel?

    @ObservationIgnored private let stack: StackController
    @ObservationIgnored private var expected: Set<ServiceID> = []
    @ObservationIgnored private var observer: Task<Void, Never>?
    /// Optional services never degrade the health when stopped.
    static let optionalServices: Set<ServiceID> = [.elasticsearch]

    init(stack: StackController) {
        self.stack = stack
        let events = stack.events
        observer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: Actions

    func start(_ id: ServiceID) async {
        if id == .elasticsearch, let es = app?.elasticsearch {   // 06-04: prepare + auto-stop session
            await perform("start:\(id.name)") { await es.start() }
            return
        }
        await perform("start:\(id.name)") {
            let state = await self.stack.start(id)
            if case .failed(let reason) = state {
                self.app?.report(title: String(localized: "\(id.displayName) sa nepodarilo spustiť"), message: reason)
            }
        }
    }

    func stop(_ id: ServiceID) async {
        if id == .elasticsearch, let es = app?.elasticsearch {
            await perform("stop:\(id.name)") { await es.stop() }
            return
        }
        await perform("stop:\(id.name)") { await self.stack.stop(id) }
    }

    func restart(_ id: ServiceID) async {
        if id == .elasticsearch, let es = app?.elasticsearch {
            await perform("restart:\(id.name)") { await es.restart() }
            return
        }
        await perform("restart:\(id.name)") {
            do {
                if case .failed(let reason) = try await self.stack.restart(id) {
                    self.app?.report(title: String(localized: "\(id.displayName) sa nepodarilo reštartovať"),
                                     message: reason)
                }
            } catch {
                self.app?.report(title: String(localized: "\(id.displayName) sa nepodarilo reštartovať"), error: error)
            }
        }
    }

    func reload(_ id: ServiceID) async {
        await perform("reload:\(id.name)") {
            do {
                try await self.stack.reload(id)
            } catch {
                self.app?.report(title: String(localized: "\(id.displayName) sa nepodarilo načítať znova"),
                                 error: error)
            }
        }
    }

    /// Graceful Apache reload (SIGUSR1) after `httpd -t`.
    func restartApache() async {
        await reload(.apache)
    }

    func startAll() async {
        await perform("startAll") {
            do {
                try await self.stack.prepare()
                let report = try await self.stack.startAll()
                if !report.errors.isEmpty {
                    let message = report.errors.map { "\($0.key.displayName): \($0.value)" }.sorted()
                        .joined(separator: "\n")
                    self.app?.report(title: String(localized: "Niektoré služby sa nepodarilo spustiť"), message: message)
                }
            } catch {
                self.app?.report(title: String(localized: "Služby sa nepodarilo spustiť"), error: error)
            }
        }
    }

    func stopAll() async {
        await perform("stopAll") { await self.stack.stopAll() }
    }

    func isBusy(_ action: String, _ id: ServiceID) -> Bool {
        app?.busy.contains("\(action):\(id.name)") ?? false
    }

    var isBusyAll: Bool {
        guard let busy = app?.busy else { return false }
        return busy.contains("startAll") || busy.contains("stopAll") || busy.contains("launch")
    }

    // MARK: State

    func refresh() async {
        await app?.reloadConfig()
        let config = app?.config ?? RampConfig()
        #if DEBUG
        if ScreenshotMode.isActive {
            rows = DemoData.serviceRows(config)
            expected = DemoData.expectedServices(rows)
            recomputeHealth()
            return
        }
        #endif
        expected = await stack.expectedServices()
        var rows = await stack.orderedStatus().map { status in
            ServiceRowState(id: status.id, displayName: status.id.displayName, state: status.state,
                            port: Self.port(of: status.id, config: config))
        }
        // Elasticsearch (06-04): optional row, only when installed (never part of the stack specs).
        if let es = app?.elasticsearch, ElasticsearchConfigGenerator.isInstalled(config) {
            rows.append(ServiceRowState(id: .elasticsearch, displayName: ServiceID.elasticsearch.displayName,
                                        state: await es.service.state(),
                                        port: Self.port(of: .elasticsearch, config: config)))
        }
        self.rows = rows
        recomputeHealth()
    }

    private func handle(_ event: ServiceEvent) {
        guard case .stateChanged(let id, let state) = event else { return }
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].state = state
            recomputeHealth()
        } else {
            Task { await refresh() }
        }
    }

    private func recomputeHealth() {
        let states = Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { _, new in new })
        let xdebug = (app?.config.php.branches ?? [:])
            .filter { $0.value.enabled && $0.value.xdebug != .off }.keys.sorted()
        health = StackHealth.evaluate(states: states, expected: expected, optional: Self.optionalServices,
                                      xdebugBranches: xdebug)
    }

    private func perform(_ key: String, _ body: @MainActor () async -> Void) async {
        app?.busy.insert(key)
        await body()
        app?.busy.remove(key)
        await refresh()
    }

    static func port(of id: ServiceID, config: RampConfig) -> Int? {
        switch id {
        case .apache: config.apache.port
        case .mysql: config.mysql.port
        case .redis: config.redis.port
        case .elasticsearch: config.elasticsearch.httpPort
        case .phpFPM, .custom: nil
        }
    }
}
