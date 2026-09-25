import Foundation
import Network
import Synchronization

/// Minimal async Redis client over one TCP connection (Network.framework). One command at a time
/// (actor-serialized, no pipelining); every connect / round-trip has a timeout (default 3 s).
/// The selected DB is remembered and re-applied after a reconnect.
public actor RedisClient {
    public let host: String
    public let port: Int
    public let timeout: Duration

    private var connection: NWConnection?
    private var parser = RESPParser()
    private var selectedDB = 0
    private let queue = DispatchQueue(label: "sk.tyron.ramp.redis-client")

    public init(host: String = "127.0.0.1", port: Int = 6379, timeout: Duration = .seconds(3)) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    deinit {
        connection?.cancel()
    }

    public var database: Int { selectedDB }

    /// Sends one command; a server `-ERR` reply is returned as `.error` (use `call` to throw instead).
    public func command(_ args: [String]) async throws -> RESPValue {
        try await command(args.map { Data($0.utf8) })
    }

    public func command(_ args: [Data]) async throws -> RESPValue {
        do {
            let conn = try await ensureConnected()
            return try await roundTrip(conn, args)
        } catch let error as RESPError where error == .connectionClosed {
            // Stale idle connection (server restart / timeout) → one reconnect attempt.
            close()
            let conn = try await ensureConnected()
            return try await roundTrip(conn, args)
        }
    }

    /// Like `command` but throws `RESPError.server` on an error reply.
    @discardableResult
    public func call(_ args: [String]) async throws -> RESPValue {
        let v = try await command(args)
        if case .error(let m) = v { throw RESPError.server(m) }
        return v
    }

    @discardableResult
    public func call(_ args: [Data]) async throws -> RESPValue {
        let v = try await command(args)
        if case .error(let m) = v { throw RESPError.server(m) }
        return v
    }

    public func select(_ db: Int) async throws {
        guard db != selectedDB || connection == nil else { return }
        if connection != nil {
            try await call(["SELECT", String(db)])
        }
        selectedDB = db
    }

    public func close() {
        connection?.cancel()
        connection = nil
        parser = RESPParser()
    }

    // MARK: Connection

    private func ensureConnected() async throws -> NWConnection {
        if let connection, connection.state == .ready { return connection }
        close()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw RESPError.connectionFailed("bad port \(port)")
        }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let once = Once()
        try await withTimeout(conn, once) { resume in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success(()))
                case .failed(let error):
                    resume(.failure(RESPError.connectionFailed(error.localizedDescription)))
                case .waiting(let error):
                    resume(.failure(RESPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    resume(.failure(RESPError.connectionClosed))
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
        conn.stateUpdateHandler = nil
        connection = conn
        parser = RESPParser()
        if selectedDB != 0 {
            let reply = try await roundTrip(conn, [Data("SELECT".utf8), Data(String(selectedDB).utf8)])
            if case .error(let m) = reply { throw RESPError.server(m) }
        }
        return conn
    }

    /// Sends several commands in one write and reads the replies in order (e.g. TYPE for a page of keys).
    public func pipeline(_ commands: [[Data]]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        let conn = try await ensureConnected()
        var payload = Data()
        for c in commands { payload.append(RESPEncoder.command(c)) }
        let first = try await roundTrip(conn, payload: payload)
        var replies = [first]
        replies.reserveCapacity(commands.count)
        do {
            while replies.count < commands.count {
                replies.append(try await readReply(conn))
            }
        } catch {
            if connection === conn { close() }
            throw error
        }
        return replies
    }

    private func readReply(_ conn: NWConnection) async throws -> RESPValue {
        while true {
            if let value = try parser.next() { return value }
            parser.append(try await receive(conn))
        }
    }

    private func roundTrip(_ conn: NWConnection, _ args: [Data]) async throws -> RESPValue {
        try await roundTrip(conn, payload: RESPEncoder.command(args))
    }

    private func roundTrip(_ conn: NWConnection, payload: Data) async throws -> RESPValue {
        let once = Once()
        do {
            try await withTimeout(conn, once) { resume in
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        resume(.failure(RESPError.connectionFailed(error.localizedDescription)))
                    } else {
                        resume(.success(()))
                    }
                })
            }
            return try await readReply(conn)
        } catch {
            // Timeout / protocol error leaves the stream in an unknown state → drop the connection.
            if connection === conn { close() }
            throw error
        }
    }

    private func receive(_ conn: NWConnection) async throws -> Data {
        let once = Once()
        let box = DataBox()
        try await withTimeout(conn, once) { resume in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { content, _, isComplete, error in
                if let error {
                    resume(.failure(RESPError.connectionFailed(error.localizedDescription)))
                } else if let content, !content.isEmpty {
                    box.set(content)
                    resume(.success(()))
                } else if isComplete {
                    resume(.failure(RESPError.connectionClosed))
                } else {
                    resume(.failure(RESPError.connectionClosed))
                }
            }
        }
        return box.get()
    }

    /// Bridges a callback API into async with a single timeout; the first of (callback, timeout) wins.
    /// On timeout the connection is cancelled, so late callbacks are ignored.
    private func withTimeout(_ conn: NWConnection, _ once: Once,
                             _ body: @escaping @Sendable (@escaping @Sendable (Result<Void, any Error>) -> Void) -> Void) async throws {
        let nanos = Int(timeout.components.seconds) * 1_000_000_000
            + Int(timeout.components.attoseconds / 1_000_000_000)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let resume: @Sendable (Result<Void, any Error>) -> Void = { result in
                if once.fire() { cont.resume(with: result) }
            }
            queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) {
                if once.fire() {
                    conn.cancel()
                    cont.resume(throwing: RESPError.timeout)
                }
            }
            body(resume)
        }
    }
}

/// Thread-safe one-shot flag.
private final class Once: Sendable {
    private let fired = Atomic<Bool>(false)
    func fire() -> Bool {
        fired.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
}

private final class DataBox: Sendable {
    private let value = Mutex<Data>(Data())
    func set(_ d: Data) { value.withLock { $0 = d } }
    func get() -> Data { value.withLock { $0 } }
}
