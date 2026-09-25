import Foundation
import Synchronization
import Testing
@testable import RAMPCore

@Suite struct DownloadProgressTests {
    @Test func throttlesToMinInterval() {
        var tracker = DownloadRateTracker(totalBytes: 1_000, minInterval: 0.2)
        #expect(tracker.record(bytes: 10, at: 0) != nil)          // first sample always
        #expect(tracker.record(bytes: 20, at: 0.1) == nil)        // throttled
        #expect(tracker.record(bytes: 30, at: 0.25) != nil)
        #expect(tracker.record(bytes: 1_000, at: 0.26) != nil)    // completion is never throttled
        #expect(tracker.record(bytes: 40, at: 0.27, force: true) != nil)
    }

    @Test func speedIsMovingAverageOverWindow() {
        var tracker = DownloadRateTracker(totalBytes: 100_000_000, window: 2, minInterval: 0)
        #expect(tracker.record(bytes: 0, at: 0)?.bytesPerSecond == nil)            // no data yet
        #expect(tracker.record(bytes: 1_000, at: 0.1)?.bytesPerSecond == nil)      // < 0.5 s of data
        _ = tracker.record(bytes: 10_000_000, at: 1)
        // Burst long ago drops out of the 2 s window: 2 → 5 s at 2 MB/s.
        _ = tracker.record(bytes: 12_000_000, at: 3)
        _ = tracker.record(bytes: 14_000_000, at: 4)
        let p = tracker.record(bytes: 16_000_000, at: 5)
        #expect(p?.bytesPerSecond == 2_000_000)
        #expect(p?.secondsRemaining == 42)   // 84 MB left at 2 MB/s
    }

    @Test func responseLengthOverridesManifestSizeAndUnknownStaysNil() {
        var tracker = DownloadRateTracker(totalBytes: 500, minInterval: 0)
        #expect(tracker.record(bytes: 100, expected: 1_000, at: 0)?.totalBytes == 1_000)
        #expect(tracker.record(bytes: 100, expected: -1, at: 1)?.totalBytes == 500)   // -1 = unknown
        var unknown = DownloadRateTracker(totalBytes: nil, minInterval: 0)
        let p = unknown.record(bytes: 100, expected: -1, at: 0)
        #expect(p?.totalBytes == nil && p?.fraction == nil && p?.secondsRemaining == nil)
    }

    @Test func fractionAndEta() {
        let p = DownloadProgress(bytesReceived: 412_000_000, totalBytes: 670_000_000, bytesPerSecond: 11_200_000)
        #expect(abs((p.fraction ?? 0) - 0.6149) < 0.001)
        #expect(p.secondsRemaining == 24)   // 258 MB / 11.2 MB/s = 23.04 → rounded up
        #expect(DownloadProgress(bytesReceived: 900, totalBytes: 800).fraction == 1)
        #expect(DownloadProgress(bytesReceived: 1, totalBytes: 10, bytesPerSecond: 0).secondsRemaining == nil)
    }

    @Test func formatting() {
        let sk = Locale(identifier: "sk_SK"), en = Locale(identifier: "en_US")
        #expect(DownloadProgress.bytes(670_000_000, locale: sk) == "670 MB")
        #expect(DownloadProgress.bytes(412_345_678, locale: sk) == "412,3 MB")
        #expect(DownloadProgress.bytes(412_345_678, locale: en) == "412.3 MB")
        #expect(DownloadProgress.speed(11_234_567.4, locale: sk) == "11,2 MB")
        #expect(DownloadProgress.duration(23) == "0:23")
        #expect(DownloadProgress.duration(725) == "12:05")
        #expect(DownloadProgress.duration(3_723) == "1:02:03")
        #expect(DownloadProgress.duration(-5) == "0:00")
    }

    @Test func overallFraction() {
        let half = DownloadProgress(bytesReceived: 50, totalBytes: 100)
        #expect(InstallProgress.overallFraction(stage: .downloading, download: half) == 0.425)
        #expect(InstallProgress.overallFraction(stage: .downloading, download: nil) == 0)
        #expect(InstallProgress.overallFraction(stage: .verifying, download: nil) > 0.85)
        #expect(InstallProgress.overallFraction(stage: nil, download: nil) == 0)
    }

    // MARK: HTTPS path (delegate-based download task, stubbed transport)

    private func httpsInstall(status: Int) async throws -> (Result<InstalledPackage, any Error>, [InstallProgress]) {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1")
        let data = try Data(contentsOf: archive.url)
        let url = "https://stub.ramp.test/\(UUID().uuidString)/\(archive.fileName)"
        StubHTTP.responses.withLock { $0[url] = (status, data) }
        let json: [String: Any] = ["schema": 1, "generated": "2026-09-24T00:00:00Z", "components": [
            "redis": ["8.6": ["version": "8.6.1", "url": url, "sha256": archive.sha256, "size": archive.size]]]]
        let manifestData = try JSONSerialization.data(withJSONObject: json)
        let manifest = try Manifest.decode(from: manifestData, manifestURL: URL(string: "https://stub.ramp.test/m.json")!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        let installer = PackageInstaller(paths: fx.paths, configStore: ConfigStore(paths: fx.paths),
                                         session: URLSession(configuration: config))
        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let collector = Task { var all: [InstallProgress] = []; for await e in stream { all.append(e) }; return all }
        let result: Result<InstalledPackage, any Error>
        do {
            result = .success(try await installer.install(component: "redis", branch: "8.6", from: manifest,
                                                          progress: continuation))
        } catch {
            result = .failure(error)
        }
        continuation.finish()
        return (result, await collector.value)
    }

    @Test func httpsDownloadReportsBytesAndInstalls() async throws {
        let (result, events) = try await httpsInstall(status: 200)
        let record = try result.get()
        #expect(record.version == "8.6.1")
        let bytes = events.compactMap(\.download)
        #expect(!bytes.isEmpty)
        #expect(bytes.last?.fraction == 1)
        #expect(bytes.allSatisfy { $0.totalBytes != nil })
    }

    @Test func httpsErrorStatusFails() async throws {
        let (result, _) = try await httpsInstall(status: 404)
        #expect(throws: InstallError.self) { try result.get() }
    }
}

/// Serves registered bytes for https URLs in chunks (so the delegate sees several writes).
final class StubHTTP: URLProtocol, @unchecked Sendable {
    static let responses = Mutex<[String: (Int, Data)]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, data) = Self.responses.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = max(1, data.count / 4)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunk)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
