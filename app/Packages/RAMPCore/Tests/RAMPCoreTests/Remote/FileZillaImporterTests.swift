import Foundation
import Testing
@testable import RAMPCore

@Suite struct FileZillaImporterTests {
    // Anonymized fixture modelled on a real FileZilla 3.x sitemanager.xml.
    private static let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FileZilla3 version="3.69.1" platform="macos">
        <Servers>
            <Server>
                <Host>ftp.example.com</Host>
                <Port>21</Port>
                <Protocol>0</Protocol>
                <Type>0</Type>
                <User>top-user</User>
                <Pass encoding="base64">cGFzcyB3b3JkIMWhxI0=</Pass>
                <Logontype>1</Logontype>
                <PasvMode>MODE_DEFAULT</PasvMode>
                <Name>Top level</Name>
                <Comments>line one
    line two</Comments>
                <RemoteDir>1 0 3 var 3 www</RemoteDir>
            </Server>
            <Folder expanded="1">Klienti
                <Server>
                    <Host>sftp.example.org</Host>
                    <Port>2222</Port>
                    <Protocol>1</Protocol>
                    <User>deploy</User>
                    <Logontype>5</Logontype>
                    <Keyfile>/Users/someone/.ssh/id_ed25519</Keyfile>
                    <Name>Key site</Name>
                    <Comments />
                    <RemoteDir>1 0 4 home 6 my dir</RemoteDir>
                </Server>
                <Folder expanded="0">Shop
                    <Server>
                        <Host>implicit.example.net</Host>
                        <Port>990</Port>
                        <Protocol>3</Protocol>
                        <User>u3</User>
                        <Pass encoding="crypt" pubkey="ABCDEF">ZZZZencryptedZZZZ</Pass>
                        <PasvMode>MODE_ACTIVE</PasvMode>
                        <Name>Implicit</Name>
                    </Server>
                    <Server>
                        <Host>explicit.example.net</Host>
                        <Port>21</Port>
                        <Protocol>4</Protocol>
                        <User>u4</User>
                        <Pass>plain-pass</Pass>
                        <Name>Explicit</Name>
                    </Server>
                </Folder>
            </Folder>
            <Server>
                <Host>insecure.example.com</Host>
                <Protocol>6</Protocol>
                <User>anon</User>
                <Logontype>0</Logontype>
                <Name>Insecure</Name>
            </Server>
            <Server>
                <Host>bucket.example.com</Host>
                <Protocol>7</Protocol>
                <User>s3</User>
                <Name>Unsupported S3</Name>
            </Server>
        </Servers>
    </FileZilla3>
    """

    private func entries() throws -> [String: FileZillaImporter.Entry] {
        let list = try FileZillaImporter.parse(Data(Self.fixture.utf8))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.site.name, $0) })
    }

    @Test func parsesAllSupportedSites() throws {
        let list = try FileZillaImporter.parse(Data(Self.fixture.utf8))
        #expect(list.map(\.site.name) == ["Top level", "Key site", "Implicit", "Explicit", "Insecure"])
    }

    @Test func topLevelFTPWithBase64Password() throws {
        let e = try #require(try entries()["Top level"])
        #expect(e.site.proto == .ftp)
        #expect(e.site.host == "ftp.example.com")
        #expect(e.site.port == 21)
        #expect(e.site.username == "top-user")
        #expect(e.site.group == nil)
        #expect(e.site.passive)
        #expect(e.site.auth == .password)
        #expect(e.site.initialPath == "/var/www")
        #expect(e.site.notes == "line one\nline two")
        #expect(e.passwordStatus == .imported)
        #expect(e.secrets?.password == "pass word šč")
    }

    @Test func sftpWithKeyfileInFolder() throws {
        let e = try #require(try entries()["Key site"])
        #expect(e.site.proto == .sftp)
        #expect(e.site.port == 2222)
        #expect(e.site.group == "Klienti")
        #expect(e.site.auth == .privateKey)
        #expect(e.site.privateKeyPath == "/Users/someone/.ssh/id_ed25519")
        #expect(e.site.initialPath == "/home/my dir")
        #expect(e.site.notes == nil)
        #expect(e.passwordStatus == .none)
        #expect(e.secrets == nil)
    }

    @Test func nestedFoldersCryptAndActiveMode() throws {
        let e = try #require(try entries()["Implicit"])
        #expect(e.site.proto == .ftps)
        #expect(e.site.port == 990)
        #expect(e.site.group == "Klienti / Shop")
        #expect(e.site.passive == false)
        #expect(e.passwordStatus == .encryptedWithMasterPassword)
        #expect(e.secrets == nil)
    }

    @Test func explicitTLSPlainPassword() throws {
        let e = try #require(try entries()["Explicit"])
        #expect(e.site.proto == .ftpes)
        #expect(e.site.group == "Klienti / Shop")
        #expect(e.passwordStatus == .imported)
        #expect(e.secrets?.password == "plain-pass")
    }

    @Test func insecureFTPDefaultsPort() throws {
        let e = try #require(try entries()["Insecure"])
        #expect(e.site.proto == .ftp)
        #expect(e.site.port == 21)
        #expect(e.site.group == nil)
        #expect(e.passwordStatus == .none)
    }

    @Test func protocolMapping() {
        #expect(FileZillaImporter.mapProtocol(0) == .ftp)
        #expect(FileZillaImporter.mapProtocol(1) == .sftp)
        #expect(FileZillaImporter.mapProtocol(3) == .ftps)
        #expect(FileZillaImporter.mapProtocol(4) == .ftpes)
        #expect(FileZillaImporter.mapProtocol(6) == .ftp)
        #expect(FileZillaImporter.mapProtocol(2) == nil)
        #expect(FileZillaImporter.mapProtocol(7) == nil)
    }

    @Test func remoteDirDecoding() {
        #expect(FileZillaImporter.decodeRemoteDir("1 0 3 var 3 www") == "/var/www")
        #expect(FileZillaImporter.decodeRemoteDir("1 0 4 home 6 my dir 1 x") == "/home/my dir/x")
        #expect(FileZillaImporter.decodeRemoteDir("1 0") == "/")
        #expect(FileZillaImporter.decodeRemoteDir("") == nil)
        #expect(FileZillaImporter.decodeRemoteDir("1 0 9 short") == nil)
    }

    @Test func legacyNameAsTrailingTextAndMissingName() throws {
        let xml = """
        <FileZilla3><Servers>
          <Server><Host>legacy.example.com</Host><Protocol>0</Protocol><User>u</User>Legacy name</Server>
          <Server><Host>noname.example.com</Host><Protocol>1</Protocol><User>u</User></Server>
        </Servers></FileZilla3>
        """
        let list = try FileZillaImporter.parse(Data(xml.utf8))
        #expect(list.map(\.site.name) == ["Legacy name", "noname.example.com"])
        #expect(list[1].site.port == 22)
    }

    @Test func invalidXMLThrows() {
        #expect(throws: RemoteError.self) { try FileZillaImporter.parse(Data("<FileZilla3><Servers>".utf8)) }
        #expect(throws: RemoteError.self) {
            try FileZillaImporter.load(from: URL(filePath: "/nonexistent/sitemanager.xml"))
        }
    }
}
