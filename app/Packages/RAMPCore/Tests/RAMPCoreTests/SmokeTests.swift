import Testing
@testable import RAMPCore

@Suite struct SmokeTests {
    @Test func versionIsSet() {
        #expect(!RAMPCore.version.isEmpty)
    }
}
