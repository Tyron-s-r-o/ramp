import Foundation

/// XPC interface of the privileged hosts helper (Mach service `RAMPHostsHelper.label`).
/// The helper renders the block itself from the validated names; the client never sends file content.
@objc public protocol RAMPHostsHelperProtocol {
    /// Helper build version (`RAMPHostsHelper.version`), used to decide whether to re-register.
    func version(withReply reply: @escaping @Sendable (String) -> Void)
    /// Replaces the RAMP block in /private/etc/hosts. Reply `nil` = success, else a readable error text.
    func setHostsBlock(_ names: [String], withReply reply: @escaping @Sendable (String?) -> Void)
}

/// Identifiers shared by the app and the helper.
public enum RAMPHostsHelper {
    public static let label = "sk.tyron.ramp.hostshelper"
    public static let plistName = label + ".plist"
    public static let appIdentifier = "sk.tyron.ramp"
    public static let version = "1"

    /// Code-signing requirement pinning a peer to an exact identifier and Team ID.
    /// - Throws: `HostsError.invalidTeamID` unless `teamID` matches `^[A-Z0-9]{10}$`;
    ///   `HostsError.invalidIdentifier` unless `identifier` is non-empty `[A-Za-z0-9.-]`.
    public static func codeSigningRequirement(identifier: String, teamID: String) throws -> String {
        let teamOK = teamID.utf8.count == 10 && teamID.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        }
        guard teamOK else { throw HostsError.invalidTeamID(teamID) }
        let identifierOK = !identifier.isEmpty && identifier.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-")
        }
        guard identifierOK else { throw HostsError.invalidIdentifier(identifier) }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
