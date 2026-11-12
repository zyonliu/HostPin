import Darwin
import Foundation

public struct Rule: Identifiable, Hashable, Sendable {
    public let id: String
    public let group: String
    public let name: String
    public let englishName: String
    public let domains: [String]
    public let addresses: [String]
    public let port: UInt16
    public let certificateNames: [String]
    public let downloadURL: URL?

    public func matches(_ query: String) -> Bool {
        let search = [name, englishName, group] + domains
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            search.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

public enum HostPinError: LocalizedError, Sendable {
    case message(String)

    public var errorDescription: String? {
        switch self { case let .message(value): return value }
    }
}

public func isIPAddress(_ string: String) -> Bool {
    guard !string.utf8.contains(0) else { return false }
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return inet_pton(AF_INET, string, &ipv4) == 1 || inet_pton(AF_INET6, string, &ipv6) == 1
}

public func isHostname(_ string: String) -> Bool {
    guard !string.isEmpty, string.utf8.count <= 253 else { return false }
    return string.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
        label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
}

public func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen = Set<Value>()
    return values.filter { seen.insert($0).inserted }
}

public enum RuleCatalog {
    public static let source = URL(string: "https://www.dogfight360.com/Usbeam/usbeam_new_40.xml")!
    public static let mirror = URL(string: "https://usbeam.steam302.xyz/Usbeam/usbeam_new_40.xml")!
    public static let maxSize = 8 * 1024 * 1024

    public static func httpsSource(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }

    public static func parse(_ data: Data) throws -> [Rule] {
        guard data.count <= maxSize, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw HostPinError.message("规则文件过大或不是 UTF-8 格式。")
        }
        var sections: [String: [String: String]] = [:]
        var sectionOrder: [String] = []
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.hasPrefix("["), line.hasSuffix("]") {
                let key = String(line.dropFirst().dropLast())
                if sections[key] == nil { sectionOrder.append(key); sections[key] = [:] }
                current = key
            } else if let current, let separator = line.firstIndex(of: "="), !line.hasPrefix(";"), !line.hasPrefix("#") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                sections[current]?[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let groups = split(sections["usbeam"]?["Group"])
        let publics = sections["Public"] ?? [:]
        var rules: [Rule] = []
        var used = Set<String>()
        var expandedBytes = 0
        for group in unique(groups.filter { $0 != "|" } + sectionOrder) {
            guard let values = sections[group], values["Group_ID"] != nil else { continue }
            let ids = values.keys.compactMap { key -> Int? in
                guard key.hasSuffix(".domain") else { return nil }
                return Int(key.dropLast(".domain".count))
            }.sorted()
            for numericID in ids {
                let id = String(numericID)
                let domains = unique(split(values[id + ".domain"]).map { $0.lowercased() }.filter(isHostname))
                guard !domains.isEmpty, used.insert(id).inserted else { continue }
                let name = values[id + ".name"] ?? id
                let localized = values[id + ".name_zh"].flatMap { $0.isEmpty ? nil : $0 } ?? name
                var pool: [String] = []
                for entry in split(values[id + ".ip"]) {
                    let expanded = expand(entry, publics: publics)
                    expandedBytes += expanded.utf8.count
                    guard expandedBytes <= 32 * 1024 * 1024 else {
                        throw HostPinError.message("规则展开后的内容过大。")
                    }
                    pool.append(contentsOf: split(expanded).filter(isIPAddress))
                }
                let addresses = unique(pool)
                let target = expand(values[id + ".dltest"] ?? "", publics: publics)
                let normalizedURL = target.contains("://") || !target.contains("/") ? target : "http://" + target
                let url = URL(string: normalizedURL).flatMap { url in
                    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host.map(isHostname) == true &&
                    url.user == nil && url.password == nil ? url : nil
                }
                let port = values[id + ".port"].flatMap(UInt16.init).flatMap { $0 == 0 ? nil : $0 } ?? 443
                rules.append(Rule(id: id, group: values["ZH"] ?? group, name: localized, englishName: name,
                                  domains: domains, addresses: addresses, port: port,
                                  certificateNames: split(values[id + ".cert"]), downloadURL: url))
            }
        }
        guard !rules.isEmpty else { throw HostPinError.message("文件中没有可用的 UsbEAm 规则。") }
        return rules
    }

    private static func split(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func expand(_ value: String, publics: [String: String]) -> String {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return value }
        return publics[String(value.dropFirst().dropLast())] ?? ""
    }
}
