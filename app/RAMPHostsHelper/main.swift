import Foundation
import os
import RAMPHostsKit

// Privileged hosts helper (root LaunchDaemon, launched on demand via its Mach service).
helperLog.notice("hostshelper starting, version \(RAMPHostsHelper.version, privacy: .public)")

guard getuid() == 0 else {
    helperLog.error("must run as root (uid \(getuid())), exiting")
    FileHandle.standardError.write(Data("\(RAMPHostsHelper.label): must run as root\n".utf8))
    exit(1)
}

// Fail closed: without our own Team ID we cannot pin the client.
guard let teamID = SigningInfo.ownTeamID() else {
    helperLog.error("helper is unsigned or ad-hoc signed (no Team ID), exiting")
    exit(1)
}

let clientRequirement: String
do {
    clientRequirement = try RAMPHostsHelper.codeSigningRequirement(identifier: RAMPHostsHelper.appIdentifier, teamID: teamID)
} catch {
    helperLog.error("cannot build client requirement: \(error.localizedDescription, privacy: .public)")
    exit(1)
}

let idleExit = IdleExit()
let listenerDelegate = ListenerDelegate(service: HelperService(idle: idleExit))
let listener = NSXPCListener(machServiceName: RAMPHostsHelper.label)
listener.setConnectionCodeSigningRequirement(clientRequirement)
listener.delegate = listenerDelegate
listener.resume()
idleExit.arm()
dispatchMain()
