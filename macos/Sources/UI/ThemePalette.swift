import AppKit

/// Explicit semantic roles: white input backgrounds and white button labels
/// intentionally resolve differently. Light values preserve the original artwork.
struct ThemePalette: Equatable, Sendable {
    enum Role: CaseIterable {
        case background, surface, raised, hover, sidebar, sidebarSelected, sidebarHover
        case text, secondaryText, accent, onAccent, border, controlBorder, focusBorder
        case primaryButton, primaryHover, dangerButton, selected, selection
        case errorText, errorSurface, errorBorder, warning, shadow, backdrop
        case connection, gradientStart, gradientEnd, networkLine, networkRing, networkGlow
        case overlay, toast, toastText
    }
    var theme: ResolvedTheme
    static let light = ThemePalette(theme: .light)
    static let dark = ThemePalette(theme: .dark)

    subscript(_ role: Role, light original: UInt32) -> UInt32 {
        guard theme == .dark else { return original }
        switch role {
        case .background: return 0x111a16
        case .surface: return 0x19261f
        case .raised: return 0x223229
        case .hover: return 0x293d31
        case .sidebar: return 0x0d1511
        case .sidebarSelected, .selected: return 0x2d4836
        case .sidebarHover: return 0x223229
        case .text: return 0xe9efe5
        case .secondaryText: return 0xa6b6a6
        case .accent: return 0xd8efad
        case .onAccent, .overlay: return 0xffffff
        case .border: return 0x34473b
        case .controlBorder: return 0x718575
        case .focusBorder: return 0xa6b6a6
        case .primaryButton: return 0x25674d
        case .primaryHover: return 0x307b5c
        case .dangerButton: return 0xa84e3e
        case .selection: return 0x43564a
        case .errorText: return 0xf3a59a
        case .errorSurface: return 0x352721
        case .errorBorder: return 0x78524a
        case .warning: return 0xe4c28a
        case .shadow: return 0x000000
        case .backdrop: return 0x050b07
        case .connection: return 0x192b20
        case .gradientStart: return 0x203527
        case .gradientEnd: return 0x19261f
        case .networkLine: return 0x91b879
        case .networkRing: return 0x719965
        case .networkGlow: return 0x48643b
        case .toast: return 0x2d4836
        case .toastText: return 0xe9efe5
        }
    }
    var background: UInt32 { self[.background, light: 0xfafbf8] }
    var surface: UInt32 { self[.surface, light: 0xffffff] }
    var text: UInt32 { self[.text, light: 0x1d332d] }
    var secondaryText: UInt32 { self[.secondaryText, light: 0x77847b] }
    var border: UInt32 { self[.border, light: 0xe5e9df] }
    var appearance: NSAppearance? { NSAppearance(named: theme == .dark ? .darkAqua : .aqua) }
    static func resolve(_ appearance: NSAppearance) -> ResolvedTheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

@MainActor final class AppearanceRootView: NSView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}
