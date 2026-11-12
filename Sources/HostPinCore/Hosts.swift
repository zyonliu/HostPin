import Darwin
import Foundation

public struct HostMapping: Identifiable, Sendable {
    public let address: String
    public let domains: [String]
    public let managed: Bool
    public var id: String { address + " " + domains.joined(separator: " ") }
}

public enum HostsDocument {
    public static let systemURL = URL(fileURLWithPath: "/private/etc/hosts")
    public static let maxSize = 1024 * 1024
    private static let marker = "HostPin:"

    public static func read(_ url: URL = systemURL) throws -> String {
        let data = try LimitedFile.read(url, maximumSize: maxSize)
        guard data.count <= maxSize, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw HostPinError.message("Hosts 文件过大或不是有效的 UTF-8 文本。")
        }
        return text
    }

    public static func mappings(in text: String) -> [HostMapping] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let parsed = parse(line) else { return nil }
            return HostMapping(address: parsed.address, domains: parsed.domains, managed: parsed.managed)
        }
    }

    public static func findRanges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let document = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < document.length {
            let search = NSRange(location: start, length: document.length - start)
            let match = document.range(of: query, options: .caseInsensitive, range: search)
            guard match.location != NSNotFound, match.length > 0 else { break }
            ranges.append(match)
            start = NSMaxRange(match)
        }
        return ranges
    }

    public static func copyLines(rule: Rule, address: String) -> String {
        rule.domains.map { "\(address)\t\($0)" }.joined(separator: "\n")
    }

    public static func removingManagedMappings(from text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        return text.components(separatedBy: newline)
            .filter { parse($0)?.managed != true }
            .joined(separator: newline)
    }

    public static func applying(_ changes: [(rule: Rule, address: String?)], to text: String) throws -> String {
        var destinations: [String: (rule: String, address: String?)] = [:]
        var orderedDomains: [String] = []
        for (rule, address) in changes {
            if let address, !isIPAddress(address) { throw HostPinError.message("IP 地址无效。") }
            for domain in rule.domains {
                if let previous = destinations[domain] {
                    guard previous.address == address else {
                        throw HostPinError.message("批量规则为 \(domain) 选出了不同 IP，请分别处理。")
                    }
                    continue
                }
                orderedDomains.append(domain)
                destinations[domain] = (rule.id, address)
            }
        }

        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let hasFinalNewline = lines.last == ""
        if hasFinalNewline { lines.removeLast() }
        var alreadyMapped = Set<String>()
        var retained: [String] = []
        for line in lines {
            guard let parsed = parse(line) else { retained.append(line); continue }
            let matches = parsed.domains.filter { destinations[$0] != nil }
            if matches.isEmpty { retained.append(line); continue }
            if parsed.managed {
                let rest = parsed.domains.filter { destinations[$0] == nil }
                if !rest.isEmpty { retained.append(([parsed.address] + rest).joined(separator: "\t") + " #" + parsed.comment) }
            } else {
                for domain in matches {
                    guard let address = destinations[domain]?.address else { continue }
                    guard address == parsed.address else {
                        throw HostPinError.message("\(domain) 已有手动映射。请在 Hosts 编辑器里先处理这一行。")
                    }
                    alreadyMapped.insert(domain)
                }
                retained.append(line)
            }
        }
        let newLines = orderedDomains.compactMap { domain -> String? in
            guard !alreadyMapped.contains(domain), let target = destinations[domain], let address = target.address else { return nil }
            return "\(address)\t\(domain) # \(marker)\(target.rule)"
        }
        retained.append(contentsOf: newLines)
        let result = retained.joined(separator: newline)
        return (hasFinalNewline || !newLines.isEmpty) && !retained.isEmpty ? result + newline : result
    }

    private static func parse(_ line: String) -> (address: String, domains: [String], comment: String, managed: Bool)? {
        let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let content = parts.first else { return nil }
        let words = content.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1, isIPAddress(words[0]) else { return nil }
        let comment = parts.count == 2 ? String(parts[1]) : ""
        let tag = comment.trimmingCharacters(in: .whitespaces)
        let legacyID = tag.hasPrefix("UHE_") ? tag.dropFirst(4).prefix(while: \.isNumber) : ""
        return (words[0], words.dropFirst().map { $0.lowercased() }, comment,
                tag.hasPrefix(marker) || tag == "UHE_" || !legacyID.isEmpty)
    }
}

public enum HostsWriter {
    public static func replace(
        _ proposed: String, expected: String, at url: URL, backupDirectory: URL, owner: uid_t,
        backupEnabled: Bool = true, backupRetention: Int = 100
    ) throws {
        guard proposed.utf8.count <= HostsDocument.maxSize, expected.utf8.count <= HostsDocument.maxSize,
              !proposed.contains("\0"), !proposed.isEmpty else {
            throw HostPinError.message("Hosts 内容为空、过大或包含无效字符。")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == owner, status.st_nlink == 1, status.st_mode & 0o022 == 0 else {
            throw HostPinError.message("Hosts 文件的类型或所有者不符合要求。")
        }
        let current = try HostsDocument.read(url)
        guard current == expected else { throw HostPinError.message("Hosts 已在其他地方更改。请刷新后再试。") }
        guard current != proposed else { return }

        let backup = backupEnabled
            ? try createBackup(current, in: backupDirectory, owner: owner, mode: status.st_mode)
            : nil
        var committed = false
        defer { if !committed, let backup { unlink(backup.path) } }

        let template = url.deletingLastPathComponent().appendingPathComponent(".hostpin-XXXXXX").path
        var temporaryPath = Array(template.utf8CString)
        let output = mkstemp(&temporaryPath)
        guard output >= 0 else { throw ioError() }
        let temporary = String(cString: temporaryPath)
        defer { close(output); unlink(temporary) }
        try writeAll(Data(proposed.utf8), to: output)
        guard fchown(output, status.st_uid, status.st_gid) == 0,
              fchmod(output, mode_t(status.st_mode & 0o777)) == 0, fsync(output) == 0 else { throw ioError() }
        guard try HostsDocument.read(url) == expected else {
            throw HostPinError.message("Hosts 在写入期间发生更改，请重新预览。")
        }
        guard rename(temporary, url.path) == 0 else { throw ioError() }
        committed = true
        if let backup {
            pruneBackups(in: backupDirectory, keeping: max(1, min(100, backupRetention)),
                         newestName: backup.lastPathComponent)
        }
    }

    public static func prepareBackupDirectory(_ url: URL, owner: uid_t) throws {
        // The production location is a direct child of root-owned /private/var/db.
        if mkdir(url.path, 0o755) != 0, errno != EEXIST { throw ioError() }
        var directory = stat()
        guard lstat(url.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == owner, (directory.st_mode & 0o022) == 0 else {
            throw HostPinError.message("备份目录的权限不符合要求。")
        }
        // The files retain the readability of the source. Only the owner can write.
        guard chmod(url.path, 0o755) == 0 else { throw ioError() }
    }

    private static func createBackup(_ current: String, in directory: URL, owner: uid_t, mode: mode_t) throws -> URL {
        try prepareBackupDirectory(directory, owner: owner)
        let backup = directory.appendingPathComponent("hosts-" + UUID().uuidString)
        let handle = open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard handle >= 0 else { throw ioError() }
        defer { close(handle) }
        do {
            try writeAll(Data(current.utf8), to: handle)
            guard fchmod(handle, mode & 0o644) == 0, fsync(handle) == 0 else { throw ioError() }
        } catch {
            unlink(backup.path)
            throw error
        }
        return backup
    }

    private static func pruneBackups(in directory: URL, keeping count: Int, newestName: String) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let backups = files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name != newestName, name.hasPrefix("hosts-"), UUID(uuidString: String(name.dropFirst(6))) != nil,
                  let attributes = try? url.resourceValues(forKeys: keys), attributes.isRegularFile == true else { return nil }
            return (url, attributes.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in backups.dropFirst(count - 1) { try? FileManager.default.removeItem(at: url) }
    }

    private static func writeAll(_ data: Data, to handle: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(handle, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ioError() }
                offset += count
            }
        }
    }

    private static func ioError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
