import Darwin
import Foundation
import HostPinCore
import OpenDirectory
import Security

final class HostsService: NSObject, HostsWriting, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "com.hostpin.app.writer.serial")
    private let adminOnly: Bool

    init(adminOnly: Bool) {
        self.adminOnly = adminOnly
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener's signing requirement is applied before it accepts a peer.
        guard !adminOnly || isAdministrator(connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: HostsWriting.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func checkReady(reply: @escaping (String?) -> Void) { reply(nil) }

    func replaceHosts(_ proposed: String, expected: String, backupEnabled: Bool, backupRetention: Int, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try HostsWriter.replace(proposed, expected: expected, at: HostsDocument.systemURL,
                                        backupDirectory: HelperConfiguration.backupDirectory, owner: 0,
                                        backupEnabled: backupEnabled, backupRetention: backupRetention)
                // Signal the resolver directly. The only subprocess has fixed arguments.
                let flush = Process()
                flush.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                flush.arguments = ["-HUP", "mDNSResponder"]
                try? flush.run()
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func prepareBackupDirectory(reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try HostsWriter.prepareBackupDirectory(HelperConfiguration.backupDirectory, owner: 0)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
}

private func isAdministrator(_ uid: uid_t) -> Bool {
    do {
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers,
                                attribute: kODAttributeTypeUniqueID, matchType: UInt32(kODMatchEqualTo),
                                queryValues: String(Int32(bitPattern: uid)), returnAttributes: kODAttributeTypeRecordName,
                                maximumResults: 1)
        guard let account = try query.resultsAllowingPartial(false).first as? ODRecord else { return false }
        let admin = try node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil)
        try admin.isMemberRecord(account)
        return true
    } catch {
        return false
    }
}

func signingTeam() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let signature = info as? [String: Any] else { return nil }
    return signature[kSecCodeInfoTeamIdentifier as String] as? String
}

guard geteuid() == 0 else { exit(EX_CONFIG) }
let label: String
let requirement: String?
if CommandLine.arguments.count == 1 {
    label = HelperConfiguration.label
    requirement = signingTeam().flatMap {
        HelperConfiguration.requirement(identifier: HelperConfiguration.appIdentifier, team: $0)
    }
} else {
    label = HelperConfiguration.localLabel
    requirement = HelperConfiguration.localRequirement(identifier: HelperConfiguration.appIdentifier,
                                                        hashes: Array(CommandLine.arguments.dropFirst()))
}
guard let requirement else { exit(EX_CONFIG) }
let service = HostsService(adminOnly: label == HelperConfiguration.localLabel)
let listener = NSXPCListener(machServiceName: label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = service
listener.resume()
RunLoop.main.run()
