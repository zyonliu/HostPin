import Foundation

public enum HelperConfiguration {
    public static let label = "com.hostpin.app.writer"
    public static let localLabel = "com.hostpin.app.local-writer"
    public static let plistName = label + ".plist"
    public static let appIdentifier = "com.hostpin.app"
    public static let backupDirectory = URL(fileURLWithPath: "/private/var/db/HostPin-Backups", isDirectory: true)

    public static func requirement(identifier: String, team: String) -> String? {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              [appIdentifier, label].contains(identifier) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    public static func localRequirement(identifier: String, hashes: [String]) -> String? {
        guard [appIdentifier, localLabel].contains(identifier),
              hashes.count == 2,
              hashes.allSatisfy({ hash in
                  hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }) else { return nil }
        let pins = hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
        return "identifier \"\(identifier)\" and (\(pins))"
    }
}

@objc public protocol HostsWriting {
    func checkReady(reply: @escaping (String?) -> Void)
    func replaceHosts(_ proposed: String, expected: String, backupEnabled: Bool, backupRetention: Int, reply: @escaping (String?) -> Void)
    func prepareBackupDirectory(reply: @escaping (String?) -> Void)
}
