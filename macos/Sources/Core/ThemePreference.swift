import Foundation

enum ResolvedTheme: String, CaseIterable, Sendable { case light, dark }

enum ThemePreference: String, CaseIterable, Sendable {
    case light, dark, system
    var title: String { rawValue.capitalized }
    func resolved(system: ResolvedTheme) -> ResolvedTheme {
        switch self { case .light: .light; case .dark: .dark; case .system: system }
    }
}

@MainActor protocol ThemePreferenceStore {
    func read() -> String?
    func write(_ value: String)
}

@MainActor struct UserDefaultsThemeStore: ThemePreferenceStore {
    static let key = "appearance.theme"
    let defaults: UserDefaults
    func read() -> String? { defaults.string(forKey: Self.key) }
    func write(_ value: String) { defaults.set(value, forKey: Self.key) }
}

/// Presentation-only preference. It has no dependency on VPN commands or profiles.
@MainActor final class ThemeSettings {
    private let store: any ThemePreferenceStore
    private(set) var preference: ThemePreference
    init(store: any ThemePreferenceStore) {
        self.store = store
        preference = store.read().flatMap(ThemePreference.init(rawValue:)) ?? .system
    }
    func select(_ value: ThemePreference) {
        guard preference != value else { return }
        preference = value
        store.write(value.rawValue)
    }
}
