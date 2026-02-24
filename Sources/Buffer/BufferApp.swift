import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct BufferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notesStore: NotesStore?
    private var preferences: PreferencesStore?
    private var statusBarController: StatusBarController?
    private var notesWindowController: NotesWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var hotKeyManager: HotKeyManager?
    private var launchAtLoginManager: LaunchAtLoginManager?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = NotesStore()
        let preferences = PreferencesStore()
        self.notesStore = store
        self.preferences = preferences
        let windowController = NotesWindowController(store: store)
        notesWindowController = windowController
        settingsWindowController = SettingsWindowController(preferences: preferences)
        launchAtLoginManager = LaunchAtLoginManager()

        statusBarController = StatusBarController(
            onToggle: { [weak self] in
                self?.notesWindowController?.toggleWindow()
            },
            onSearch: { [weak self] in
                self?.notesWindowController?.showSearch()
            },
            onNewNote: { [weak self] in
                self?.notesWindowController?.createNewNoteAndShow()
            },
            onOpenSettings: { [weak self] in
                self?.settingsWindowController?.show()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        bindPreferences(preferences)
    }

    private func bindPreferences(_ preferences: PreferencesStore) {
        preferences.$hotKeyKeyCode
            .combineLatest(preferences.$hotKeyModifiers)
            .sink { [weak self] keyCode, modifiers in
                self?.registerHotKey(keyCode: keyCode, modifiers: modifiers)
            }
            .store(in: &cancellables)

        preferences.$launchAtLoginEnabled
            .sink { [weak self] enabled in
                self?.launchAtLoginManager?.setEnabled(enabled)
            }
            .store(in: &cancellables)

        preferences.$appearanceMode
            .sink { [weak self] mode in
                self?.applyAppearance(mode)
            }
            .store(in: &cancellables)
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        hotKeyManager = nil
        hotKeyManager = HotKeyManager(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            Task { @MainActor in
                self?.notesWindowController?.toggleWindow()
            }
        }

        if hotKeyManager == nil {
            print("Failed to register hotkey: keyCode=\(keyCode), modifiers=\(modifiers)")
        }
    }

    func openSettingsWindow() {
        settingsWindowController?.show()
    }
}

@MainActor
final class LaunchAtLoginManager {
    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Can fail when running from an unbundled binary (e.g. swift run).
                print("Launch-at-login registration failed: \(error)")
            }
            return
        }

        do {
            try SMAppService.mainApp.unregister()
        } catch {
            // Can fail when running from an unbundled binary (e.g. swift run).
            print("Launch-at-login unregistration failed: \(error)")
        }
    }
}
