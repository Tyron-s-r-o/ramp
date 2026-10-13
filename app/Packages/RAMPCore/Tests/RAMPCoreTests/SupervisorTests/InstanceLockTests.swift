import Foundation
import Testing
@testable import RAMPCore

struct InstanceLockTests {
    private func tempLock() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ramp-instance-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "run/ramp-app.lock", directoryHint: .notDirectory)
    }

    @Test func secondAcquireFailsWhileHeld() throws {
        let url = tempLock()
        let first = try #require(InstanceLock.acquire(at: url))
        #expect(InstanceLock.acquire(at: url) == nil)   // flock is per open file description → conflicts in-process too
        #expect(InstanceLock.holderPID(at: url) == getpid())
        _ = first
    }

    @Test func releasedWhenHolderGoesAway() throws {
        let url = tempLock()
        do {
            let held = try #require(InstanceLock.acquire(at: url))
            _ = held
        }
        #expect(InstanceLock.acquire(at: url) != nil)
    }
}
