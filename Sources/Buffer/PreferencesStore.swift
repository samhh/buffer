import AppKit
import Carbon
import Foundation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var hotKeyKeyCode: UInt32 {
        didSet { persist() }
    }
    @Published var hotKeyKey: String {
        didSet {
            let normalized = KeyboardLayoutMapper.normalizedKey(hotKeyKey)
            guard !normalized.isEmpty else {
                hotKeyKey = oldValue
                return
            }

            if hotKeyKey != normalized {
                hotKeyKey = normalized
                return
            }

            refreshResolvedHotKeyKeyCode()
        }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet { persist() }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet { persist() }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { persist() }
    }

    private let defaults = UserDefaults.standard

    init() {
        let defaultKey = "n"
        let defaultModifiers = UInt32(optionKey)
        let storedKeyCode = UInt32(defaults.integer(forKey: Keys.hotKeyCode))
        let storedKey = KeyboardLayoutMapper.normalizedKey(defaults.string(forKey: Keys.hotKey))
        let key = storedKey.isEmpty ? (KeyboardLayoutMapper.keyEquivalent(for: storedKeyCode) ?? defaultKey) : storedKey

        hotKeyKeyCode = storedKeyCode
        hotKeyKey = key
        hotKeyModifiers = UInt32(defaults.integer(forKey: Keys.hotKeyModifiers))
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? false
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system

        if defaults.object(forKey: Keys.hotKey) == nil && defaults.object(forKey: Keys.hotKeyCode) == nil && defaults.object(forKey: Keys.hotKeyModifiers) == nil {
            hotKeyKey = defaultKey
            hotKeyModifiers = defaultModifiers
        }

        refreshResolvedHotKeyKeyCode()
    }

    var hotKeyDisplay: String {
        hotKeyDisplayGlyphs
    }

    var hotKeyDisplayGlyphs: String {
        var parts: [String] = []
        if hotKeyModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotKeyModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotKeyModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotKeyModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyboardLayoutMapper.displayLabel(for: hotKeyKey))
        return parts.joined()
    }

    func updateHotKey(key: String, eventModifiers: NSEvent.ModifierFlags) {
        let mapped = Self.carbonModifiers(from: eventModifiers)
        guard mapped != 0 else {
            return
        }

        hotKeyKey = key
        hotKeyModifiers = mapped
    }

    func refreshResolvedHotKeyKeyCode() {
        if let resolved = KeyboardLayoutMapper.keyCode(for: hotKeyKey) {
            hotKeyKeyCode = resolved
            return
        }

        // Keep existing key code when the current input source cannot map the key.
        persist()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func persist() {
        defaults.set(hotKeyKey, forKey: Keys.hotKey)
        defaults.set(Int(hotKeyKeyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
        defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
        defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
    }

    private enum Keys {
        static let hotKey = "preferences.hotkey.key"
        static let hotKeyCode = "preferences.hotkey.keycode"
        static let hotKeyModifiers = "preferences.hotkey.modifiers"
        static let launchAtLoginEnabled = "preferences.launchAtLoginEnabled"
        static let appearanceMode = "preferences.appearanceMode"
    }
}
