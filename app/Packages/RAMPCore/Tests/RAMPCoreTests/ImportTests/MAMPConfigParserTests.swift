import Foundation
import Testing
@testable import RAMPCore

/// Anonymized MAMP PRO fixtures (`Fixtures/mamp`, excluded from the target, read via #filePath).
enum MAMPFixtures {
    static let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/mamp", directoryHint: .isDirectory)

    static func text(_ name: String) throws -> String {
        try String(contentsOf: dir.appending(path: name), encoding: .utf8)
    }

    static func http() throws -> [MAMPVhost] { try MAMPConfigParser.parse(text("httpd.conf"), port: 80) }
    static func ssl() throws -> [MAMPVhost] { try MAMPConfigParser.parse(text("httpd-ssl.conf"), port: 443) }
}

@Suite struct MAMPConfigParserTests {
    private func vhost(_ name: String, in list: [MAMPVhost]) throws -> MAMPVhost {
        try #require(list.first { $0.serverName == name })
    }

    @Test func parsesAllPort80BlocksOfFixture() throws {
        let hosts = try MAMPFixtures.http()
        #expect(hosts.map(\.serverName) == [
            "___default___", "localhost", "project-a.local", "front.project-b.local", "legacy.local",
            "shop.local", "old.local", "seventyfour.local", "static.local", "api.missing.local",
            "secure-a.local", "secure-b.local", "redirect-only.local",
        ])
        #expect(!hosts.contains { $0.serverName == "commented-out.local" })
    }

    @Test func extractsDocrootAliasesAndPHP() throws {
        let hosts = try MAMPFixtures.http()
        let a = try vhost("project-a.local", in: hosts)
        #expect(a.documentRoot == "/Users/test/Sites/project-a/public")
        #expect(a.aliases == ["admin.project-a.local"])
        #expect(a.phpVersion == "8.3.14")
        #expect(a.redirectTarget == nil)

        let b = try vhost("front.project-b.local", in: hosts)
        #expect(b.aliases == ["sk.project-b.local", "cz.project-b.local", "hu.project-b.local"])
        #expect(b.phpVersion == "8.4.4")

        #expect(try vhost("legacy.local", in: hosts).phpVersion == "7.3.33")
        #expect(try vhost("shop.local", in: hosts).phpVersion == "8.2.26")
        #expect(try vhost("old.local", in: hosts).phpVersion == "8.1.31")
        #expect(try vhost("static.local", in: hosts).phpVersion == nil)
    }

    @Test func redirectsAndCatchAll() throws {
        let hosts = try MAMPFixtures.http()
        let s = try vhost("secure-a.local", in: hosts)
        #expect(s.redirectTarget == "https://secure-a.local/")
        #expect(s.documentRoot == nil)
        let d = try vhost("___default___", in: hosts)
        #expect(d.redirectTarget == nil) // `Redirect 404 /` has no target URL
        #expect(d.documentRoot == nil)
    }

    @Test func lineNumbersPointAtVirtualHostTag() throws {
        let text = try MAMPFixtures.text("httpd.conf")
        let lines = text.components(separatedBy: "\n")
        for host in try MAMPFixtures.http() {
            #expect(lines[host.line - 1].hasPrefix("<VirtualHost *:80>"))
        }
    }

    @Test func sslFileOnlyYieldsPort443Blocks() throws {
        let ssl = try MAMPFixtures.ssl()
        #expect(ssl.map(\.serverName) == ["___default___", "secure-a.local", "secure-b.local", "project-a.local"])
        let b = try vhost("secure-b.local", in: ssl)
        #expect(b.aliases == ["www.secure-b.local"])
        #expect(b.documentRoot == "/Users/test/Sites/secure-b/front/public")
        #expect(b.phpVersion == "8.3.14")
        #expect(try MAMPConfigParser.parse(MAMPFixtures.text("httpd-ssl.conf"), port: 80).isEmpty)
    }

    @Test func caseInsensitiveBareValuesTabsCRLF() throws {
        let text = "<virtualhost 127.0.0.1:80>\r\n\tservername  Mixed.Local\r\n\tdocumentroot /Users/test/Sites/mixed\r\n"
            + "\tSERVERALIAS a.mixed.local\tb.mixed.local\r\n\taction php-fastcgi /fcgi-bin/php8.2.26.fcgi\r\n</VIRTUALHOST>\r\n"
        let hosts = try MAMPConfigParser.parse(text, port: 80)
        #expect(hosts == [MAMPVhost(serverName: "mixed.local", aliases: ["a.mixed.local", "b.mixed.local"],
                                    documentRoot: "/Users/test/Sites/mixed", phpVersion: "8.2.26",
                                    redirectTarget: nil, line: 1)])
    }

    @Test func quotedValuesWithEscapesAndSpaces() throws {
        let text = #"""
        <VirtualHost *:80>
            ServerName "quoted.local"
            DocumentRoot "/Users/test/My Sites/quoted \"x\""
        </VirtualHost>
        """#
        let host = try #require(try MAMPConfigParser.parse(text, port: 80).first)
        #expect(host.documentRoot == #"/Users/test/My Sites/quoted "x""#)
    }

    @Test func setHandlerProxyFCGI() throws {
        let text = """
        <VirtualHost *:80>
            ServerName fpm.local
            DocumentRoot "/Users/test/Sites/fpm"
            <FilesMatch \\.php$>
                SetHandler "proxy:unix:/Applications/MAMP/tmp/php8.3-fpm.sock|fcgi://localhost"
            </FilesMatch>
        </VirtualHost>
        """
        #expect(try MAMPConfigParser.parse(text, port: 80).first?.phpVersion == "8.3")
    }

    @Test func serverNameWithPortStripped() throws {
        let text = "<VirtualHost *:80>\nServerName port.local:80\n</VirtualHost>\n"
        #expect(try MAMPConfigParser.parse(text, port: 80).first?.serverName == "port.local")
    }

    @Test func unterminatedBlockIsMalformedWithLine() {
        let text = "Listen 80\n\n<VirtualHost *:80>\n    ServerName broken.local\n    <Directory \"/x\">\n    </Directory>\n"
        #expect(throws: MAMPImportError.malformed(line: 3)) {
            try MAMPConfigParser.parse(text, port: 80)
        }
    }

    @Test func mismatchedClosingTagIsMalformed() {
        let text = "<VirtualHost *:80>\n  <Directory /x>\n</VirtualHost>\n"
        #expect(throws: MAMPImportError.malformed(line: 3)) {
            try MAMPConfigParser.parse(text, port: 80)
        }
    }

    @Test func tooLargeRejected() {
        let big = String(repeating: "# padding line to exceed the limit ............................\n", count: 90_000)
        #expect(big.utf8.count > MAMPConfigParser.maxBytes)
        #expect(throws: MAMPImportError.tooLarge) {
            try MAMPConfigParser.parse(big, port: 80)
        }
    }

    @Test func includesAreReportedNotFollowed() throws {
        let result = try MAMPConfigParser.parseDetailed(MAMPFixtures.text("httpd.conf"), port: 80)
        #expect(result.includes == ["/Users/test/Library/Application Support/appsolute/MAMP PRO/httpd-ssl.conf"])
        #expect(result.vhosts.count == 13)
    }
}
