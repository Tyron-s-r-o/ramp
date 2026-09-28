import Foundation

/// Opens a session for a saved site: SFTP via Citadel, FTP/FTPES/FTPS via libcurl.
/// Connects and authenticates eagerly, so connection / login / host-key / certificate errors
/// are thrown here (as `RemoteError`), not on the first listing.
public enum RemoteConnector {
    public static func connect(site: RemoteSite, secrets: SiteSecrets?, knownHosts: KnownHosts) async throws -> any RemoteFileSystem {
        guard !site.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemoteError.connectionFailed("Chýba adresa servera.")
        }
        switch site.proto {
        case .sftp:
            return try await SFTPFileSystem.connect(site: site, secrets: secrets, knownHosts: knownHosts)
        case .ftp, .ftpes, .ftps:
            return try await FTPFileSystem.connect(site: site, secrets: secrets)
        }
    }
}
