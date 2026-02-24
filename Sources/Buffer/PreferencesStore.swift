import Carbon
import Foundation
import AppKit

struct HotKeyOption: Identifiable {
    let id: UInt32
    let keyCode: UInt32
    let label: String
}

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

enum HotKeyCatalog {
    static let options: [HotKeyOption] = [
        HotKeyOption(id: 49, keyCode: 49, label: "Space"),
        HotKeyOption(id: 0, keyCode: 0, label: "A"),
        HotKeyOption(id: 11, keyCode: 11, label: "B"),
        HotKeyOption(id: 8, keyCode: 8, label: "C"),
        HotKeyOption(id: 2, keyCode: 2, label: "D"),
        HotKeyOption(id: 14, keyCode: 14, label: "E"),
        HotKeyOption(id: 3, keyCode: 3, label: "F"),
        HotKeyOption(id: 5, keyCode: 5, label: "G"),
        HotKeyOption(id: 4, keyCode: 4, label: "H"),
        HotKeyOption(id: 34, keyCode: 34, label: "I"),
        HotKeyOption(id: 38, keyCode: 38, label: "J"),
        HotKeyOption(id: 40, keyCode: 40, label: "K"),
        HotKeyOption(id: 37, keyCode: 37, label: "L"),
        HotKeyOption(id: 46, keyCode: 46, label: "M"),
        HotKeyOption(id: 45, keyCode: 45, label: "N"),
        HotKeyOption(id: 31, keyCode: 31, label: "O"),
        HotKeyOption(id: 35, keyCode: 35, label: "P"),
        HotKeyOption(id: 12, keyCode: 12, label: "Q"),
        HotKeyOption(id: 15, keyCode: 15, label: "R"),
        HotKeyOption(id: 1, keyCode: 1, label: "S"),
        HotKeyOption(id: 17, keyCode: 17, label: "T"),
        HotKeyOption(id: 32, keyCode: 32, label: "U"),
        HotKeyOption(id: 9, keyCode: 9, label: "V"),
        HotKeyOption(id: 13, keyCode: 13, label: "W"),
        HotKeyOption(id: 7, keyCode: 7, label: "X"),
        HotKeyOption(id: 16, keyCode: 16, label: "Y"),
        HotKeyOption(id: 6, keyCode: 6, label: "Z"),
    ]

    static func label(for keyCode: UInt32) -> String {
        options.first(where: { $0.keyCode == keyCode })?.label ?? "Unknown"
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var hotKeyKeyCode: UInt32 {
        didSet { persist() }
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
        let defaultKeyCode = UInt32(45) // N
        let defaultModifiers = UInt32(optionKey)
        hotKeyKeyCode = UInt32(defaults.integer(forKey: Keys.hotKeyCode))
        hotKeyModifiers = UInt32(defaults.integer(forKey: Keys.hotKeyModifiers))
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? false
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system

        if hotKeyKeyCode == 0 && hotKeyModifiers == 0 {
            hotKeyKeyCode = defaultKeyCode
            hotKeyModifiers = defaultModifiers
            persist()
        }
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
        parts.append(HotKeyCatalog.label(for: hotKeyKeyCode))
        return parts.joined()
    }

    func updateHotKey(keyCode: UInt32, eventModifiers: NSEvent.ModifierFlags) {
        let mapped = Self.carbonModifiers(from: eventModifiers)
        guard mapped != 0 else {
            return
        }

        hotKeyKeyCode = keyCode
        hotKeyModifiers = mapped
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
        defaults.set(Int(hotKeyKeyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
        defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
        defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
    }

    private enum Keys {
        static let hotKeyCode = "preferences.hotkey.keycode"
        static let hotKeyModifiers = "preferences.hotkey.modifiers"
        static let launchAtLoginEnabled = "preferences.launchAtLoginEnabled"
        static let appearanceMode = "preferences.appearanceMode"
    }
}
