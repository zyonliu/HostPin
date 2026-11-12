import Foundation
import AppKit

struct HostPinPreferences: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable {
        case system, light, dark

        var appKitAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    var english = false
    var appearance: Appearance = .system
    var iconSize = 32
    var latency = "TCP"
    var phaseOne = 3
    var phaseTwo = 1
    var backupEnabled = true
    var backupRetention = 100
    var dnsServer = "223.5.5.5"
    var catalogSource: URL?

    private static let key = "hostPinPreferences"
    private static let languageKey = "hostPinEnglish"

    static func load() -> Self {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) {
            return saved
        }
        var initial = Self()
        if let server = defaults.string(forKey: "dnsServer") { initial.dnsServer = server }
        return initial
    }

    func save() {
        UserDefaults.standard.set(english, forKey: Self.languageKey)
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static var englishEnabled: Bool { UserDefaults.standard.bool(forKey: languageKey) }
}
