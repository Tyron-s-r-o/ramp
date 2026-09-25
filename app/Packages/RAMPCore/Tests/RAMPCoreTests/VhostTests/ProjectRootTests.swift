import Foundation
import Testing
@testable import RAMPCore

@Suite struct ProjectRootTests {
    typealias F = VhostFixtures

    private func fs(dirs: [String] = [], files: [String] = []) -> FakeFileChecking {
        var fs = FakeFileChecking()
        for d in dirs { fs.kinds[d] = .directory }
        for f in files { fs.kinds[f] = .file }
        return fs
    }

    @Test func docrootWithIdeaIsItself() {
        let p = "/Users/tester/Sites/shop"
        let checker = fs(dirs: [p, p + "/.idea"])
        #expect(ProjectRoot.resolve(docroot: p, home: F.home, fs: checker) == p)
    }

    @Test func wwwWithGitInParent() {
        let p = "/Users/tester/Sites/asteel"
        let checker = fs(dirs: [p, p + "/www", p + "/.git"])
        #expect(ProjectRoot.resolve(docroot: p + "/www", home: F.home, fs: checker) == p)
        #expect(ProjectRoot.resolve(docroot: p + "/www/", home: F.home, fs: checker) == p)
    }

    @Test func gitWorktreeFileCounts() {
        let p = "/Users/tester/Sites/feature"
        let checker = fs(dirs: [p, p + "/public"], files: [p + "/.git"])
        #expect(ProjectRoot.resolve(docroot: p + "/public", home: F.home, fs: checker) == p)
    }

    @Test func gitFourLevelsUpIsIgnored() {
        let top = "/Users/tester/Sites/mono"
        let docroot = top + "/a/b/c/d"
        let checker = fs(dirs: [top, top + "/.git", docroot])
        #expect(ProjectRoot.resolve(docroot: docroot, home: F.home, fs: checker) == docroot)
        // Three levels up is still found.
        #expect(ProjectRoot.resolve(docroot: top + "/a/b/c", home: F.home, fs: checker) == top)
    }

    @Test func neverReturnsHome() {
        let docroot = "/Users/tester/site"
        let checker = fs(dirs: [docroot, "/Users/tester/.git", "/Users/tester"])
        #expect(ProjectRoot.resolve(docroot: docroot, home: F.home, fs: checker) == docroot)
    }

    @Test func nothingFoundOutsideHomeStaysDocroot() {
        let docroot = "/Volumes/Work/site/www"
        let checker = fs(dirs: [docroot])
        #expect(ProjectRoot.resolve(docroot: docroot, home: F.home, fs: checker) == docroot)
    }
}
