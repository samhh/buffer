import XCTest
@testable import Buffer

final class PreferencesStoreTests: XCTestCase {
    @MainActor
    func testAppearanceModeDefaultsToSystemWhenMissing() {
        Self.clearPreferenceKeys()
        let preferences = PreferencesStore()
        XCTAssertEqual(preferences.appearanceMode, .system)
        Self.clearPreferenceKeys()
    }

    @MainActor
    func testAppearanceModeLoadsValidStoredValue() {
        Self.clearPreferenceKeys()
        UserDefaults.standard.set("dark", forKey: "preferences.appearanceMode")

        let preferences = PreferencesStore()
        XCTAssertEqual(preferences.appearanceMode, .dark)
        Self.clearPreferenceKeys()
    }

    @MainActor
    func testAppearanceModeFallsBackToSystemForInvalidStoredValue() {
        Self.clearPreferenceKeys()
        UserDefaults.standard.set("sepia", forKey: "preferences.appearanceMode")

        let preferences = PreferencesStore()
        XCTAssertEqual(preferences.appearanceMode, .system)
        Self.clearPreferenceKeys()
    }

    @MainActor
    func testAppearanceModePersistsRawValue() {
        Self.clearPreferenceKeys()
        let preferences = PreferencesStore()
        preferences.appearanceMode = .light

        XCTAssertEqual(UserDefaults.standard.string(forKey: "preferences.appearanceMode"), "light")
        Self.clearPreferenceKeys()
    }

    private static func clearPreferenceKeys() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "preferences.hotkey.keycode")
        defaults.removeObject(forKey: "preferences.hotkey.modifiers")
        defaults.removeObject(forKey: "preferences.launchAtLoginEnabled")
        defaults.removeObject(forKey: "preferences.appearanceMode")
    }
}
