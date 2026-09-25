import Foundation

/// Runs a short-lived helper process (mysqld --initialize, mysql client, config tests) without blocking
/// a cooperative thread: awaited via `terminationHandler`, combined stdout+stderr captured in a temp file
/// (no pipe-buffer deadlock), optional stdin bytes (secrets never go into argv).
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var output: String
    }

    static func run(_ argv: [String], environment: [String: String] = ServiceSpec.baseEnvironment(),
                    cwd: URL? = nil, stdin: Data? = nil, tempDir: URL) async -> Output {
        guard let exe = argv.first else { return Output(status: -1, output: "empty argv") }
        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outURL = tempDir.appending(path: ".run-\(UUID().uuidString).out", directoryHint: .notDirectory)
        let inURL = tempDir.appending(path: ".run-\(UUID().uuidString).in", directoryHint: .notDirectory)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: inURL)
        }
        guard fm.createFile(atPath: outURL.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]),
              let outHandle = try? FileHandle(forWritingTo: outURL) else {
            return Output(status: -1, output: "cannot create temp output file in \(tempDir.path(percentEncoded: false))")
        }
        var inHandle: FileHandle?
        if let stdin {
            guard fm.createFile(atPath: inURL.path(percentEncoded: false), contents: stdin,
                                attributes: [.posixPermissions: 0o600]),
                  let h = try? FileHandle(forReadingFrom: inURL) else {
                try? outHandle.close()
                return Output(status: -1, output: "cannot create temp input file")
            }
            inHandle = h
        }

        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = inHandle ?? FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = outHandle

        var launchError: String?
        let status: Int32 = await withCheckedContinuation { continuation in
            p.terminationHandler = { proc in continuation.resume(returning: proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                launchError = error.localizedDescription
                continuation.resume(returning: -1)
            }
        }
        try? outHandle.close()
        try? inHandle?.close()
        if let launchError { return Output(status: -1, output: "cannot run \(exe): \(launchError)") }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return Output(status: status, output: text)
    }
}
