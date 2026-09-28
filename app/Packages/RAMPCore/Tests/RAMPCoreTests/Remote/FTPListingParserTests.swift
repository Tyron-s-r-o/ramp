import Foundation
import Testing
@testable import RAMPCore

struct FTPListingParserTests {
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: MLSD

    @Test func mlsdFactsAndKinds() {
        let body = """
        type=cdir;modify=20240101000000;perm=flcdmpe; .
        type=pdir;modify=20240101000000;perm=flcdmpe; ..
        type=dir;modify=20240115103000;UNIX.mode=0755;perm=flcdmpe; public html\r
        type=file;size=1234;modify=20240115103005.123;UNIX.mode=0644;perm=adfrw; index.php
        type=OS.unix=symlink;modify=20240115103000; current
        type=OS.unix=slink:/var/www/x;modify=20240115103000; www
        Type=File;Size=7;Modify=20240115103000; UPPER case.txt
        """
        let items = FTPListingParser.parseMLSD(body, directory: "/web")
        #expect(items.map(\.name) == ["public html", "index.php", "current", "www", "UPPER case.txt"])
        #expect(items[0].kind == .directory)
        #expect(items[0].path == "/web/public html")
        #expect(items[0].permissions == "rwxr-xr-x")
        #expect(items[0].size == nil)
        #expect(items[1].kind == .file)
        #expect(items[1].size == 1234)
        #expect(items[1].permissions == "rw-r--r--")
        #expect(abs(items[1].modified!.timeIntervalSince(utc(2024, 1, 15, 10, 30, 5)) - 0.123) < 0.001)
        #expect(items[2].kind == .symlink)
        #expect(items[3].kind == .symlink)
        #expect(items[4].kind == .file)
        #expect(items[4].size == 7)
    }

    @Test func mlsdTimeRejectsGarbage() {
        #expect(FTPListingParser.parseMLSDTime("2024011510") == nil)
        #expect(FTPListingParser.parseMLSDTime("20240115103000") == utc(2024, 1, 15, 10, 30))
    }

    @Test func mlsdRootDirectory() {
        let items = FTPListingParser.parseMLSD("type=file;size=1; a.txt\n", directory: "/")
        #expect(items.first?.path == "/a.txt")
    }

    @Test func mlsdNameWithSemicolonAndDiacritics() {
        let items = FTPListingParser.parseMLSD("type=file;size=3; ščťž; ok.txt\n", directory: "/d")
        #expect(items.first?.name == "ščťž; ok.txt")
    }

    // MARK: LIST unix

    @Test func unixListing() {
        let now = utc(2024, 6, 1, 12)
        let body = """
        total 24
        drwxr-xr-x    5 web  www      4096 Jan 12 10:30 .
        drwxr-xr-x    3 web  www      4096 Jan 12 10:30 ..
        drwxr-xr-x    2 web  www      4096 Mar  3 09:05 my folder
        -rw-r--r--    1 web  www     12345 Dec 24  2022 old file.txt
        -rw-r--r--    1 1001 1001        0 May 31 23:59 empty
        lrwxrwxrwx    1 web  www        11 Feb  2 08:00 link name -> target dir
        -rw-r--r--    1 ftp       99 Apr  1  2021 nogroup.txt
        """
        let items = FTPListingParser.parseLIST(body, directory: "/home/web", now: now)
        #expect(items.map(\.name) == ["my folder", "old file.txt", "empty", "link name", "nogroup.txt"])
        #expect(items[0].kind == .directory)
        #expect(items[0].path == "/home/web/my folder")
        #expect(items[0].modified == utc(2024, 3, 3, 9, 5))
        #expect(items[0].permissions == "rwxr-xr-x")
        #expect(items[1].size == 12345)
        #expect(items[1].modified == utc(2022, 12, 24))
        #expect(items[2].size == 0)
        #expect(items[3].kind == .symlink)
        #expect(items[4].size == 99)
        #expect(items[4].modified == utc(2021, 4, 1))
    }

    @Test func unixRecentDateInFutureMeansLastYear() {
        let now = utc(2024, 1, 10)
        let items = FTPListingParser.parseLIST("-rw-r--r-- 1 a b 5 Dec 20 10:00 f\n", directory: "/", now: now)
        #expect(items.first?.modified == utc(2023, 12, 20, 10))
    }

    @Test func unixNameWithLeadingDoubleSpaceKept() {
        let items = FTPListingParser.parseLIST("-rw-r--r-- 1 a b 5 Dec 20  2020  two\n", directory: "/")
        #expect(items.first?.name == " two")
    }

    // MARK: LIST dos

    @Test func dosListing() {
        let body = """
        01-15-24  10:30AM       <DIR>          wwwroot dir\r
        12-31-99  11:59PM                 2048 report 2023.pdf\r
        07-04-2023  12:05AM                1 midnight.txt\r
        """
        let items = FTPListingParser.parseLIST(body, directory: "/")
        #expect(items.map(\.name) == ["wwwroot dir", "report 2023.pdf", "midnight.txt"])
        #expect(items[0].kind == .directory)
        #expect(items[0].modified == utc(2024, 1, 15, 10, 30))
        #expect(items[1].size == 2048)
        #expect(items[1].modified == utc(1999, 12, 31, 23, 59))
        #expect(items[2].modified == utc(2023, 7, 4, 0, 5))
    }

    @Test func garbageLinesIgnored() {
        #expect(FTPListingParser.parseLIST("hello world\n\n", directory: "/").isEmpty)
    }

    // MARK: PWD

    @Test func pwdReply() {
        #expect(FTPListingParser.parsePWDReply(#"257 "/home/web" is the current directory"#) == "/home/web")
        #expect(FTPListingParser.parsePWDReply(#"257 "/a ""b"" c" created"#) == #"/a "b" c"#)
        #expect(FTPListingParser.parsePWDReply("257 nothing") == nil)
    }

    @Test func permissionOctal() {
        #expect(FTPListingParser.permissionString(octal: "100644") == "rw-r--r--")
        #expect(FTPListingParser.permissionString(octal: "0700") == "rwx------")
        #expect(FTPListingParser.permissionString(octal: "zz") == nil)
    }
}
