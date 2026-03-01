import AppKit
import Carbon
import Foundation

enum KeyboardLayoutMapper {
    static func normalizedKey(_ key: String?) -> String {
        guard let key, let scalar = key.unicodeScalars.first else {
            return ""
        }

        guard !CharacterSet.controlCharacters.contains(scalar) else {
            return ""
        }

        return String(scalar).lowercased()
    }

    static func normalizedKey(from event: NSEvent) -> String? {
        let key = normalizedKey(event.charactersIgnoringModifiers)
        return key.isEmpty ? nil : key
    }

    static func displayLabel(for key: String) -> String {
        if key == " " {
            return "Space"
        }

        return key.uppercased()
    }

    static func keyEquivalent(for keyCode: UInt32) -> String? {
        let code = UInt16(keyCode)
        if let translated = translatedKey(for: code, carbonModifiers: 0) {
            let key = normalizedKey(translated)
            if !key.isEmpty {
                return key
            }
        }

        if let translated = translatedKey(for: code, carbonModifiers: UInt32(shiftKey)) {
            let key = normalizedKey(translated)
            if !key.isEmpty {
                return key
            }
        }

        return nil
    }

    static func keyCode(for key: String) -> UInt32? {
        let target = normalizedKey(key)
        guard !target.isEmpty else {
            return nil
        }

        for keyCode in UInt16(0)..<UInt16(128) {
            if let translated = translatedKey(for: keyCode, carbonModifiers: 0),
               normalizedKey(translated) == target {
                return UInt32(keyCode)
            }
        }

        for keyCode in UInt16(0)..<UInt16(128) {
            if let translated = translatedKey(for: keyCode, carbonModifiers: UInt32(shiftKey)),
               normalizedKey(translated) == target {
                return UInt32(keyCode)
            }
        }

        return nil
    }

    private static func translatedKey(for keyCode: UInt16, carbonModifiers: UInt32) -> String? {
        guard let keyboardLayout = currentKeyboardLayout() else {
            return nil
        }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            UInt32((carbonModifiers >> 8) & 0xFF),
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else {
            return nil
        }

        return String(utf16CodeUnits: chars, count: Int(length))
    }

    private static func currentKeyboardLayout() -> UnsafePointer<UCKeyboardLayout>? {
        guard let data = currentKeyboardLayoutData(),
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        return UnsafePointer<UCKeyboardLayout>(OpaquePointer(bytes))
    }

    private static func currentKeyboardLayoutData() -> CFData? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        }

        let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(fallback, kTISPropertyUnicodeKeyLayoutData) {
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        }

        return nil
    }
}
