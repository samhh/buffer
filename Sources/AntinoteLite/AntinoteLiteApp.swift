import AppKit
import Carbon
import ServiceManagement
import SwiftUI

@main
struct AntinoteLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var notesWindowController: NotesWindowController?
    private var hotKeyManager: HotKeyManager?
    private var launchAtLoginManager: LaunchAtLoginManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = NotesStore()
        let windowController = NotesWindowController(store: store)
        notesWindowController = windowController
        launchAtLoginManager = LaunchAtLoginManager()
        launchAtLoginManager?.enable()

        statusBarController = StatusBarController(
            onToggle: { [weak self] in
                self?.notesWindowController?.toggleWindow()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        hotKeyManager = HotKeyManager(keyCode: 45, modifiers: UInt32(optionKey)) { [weak self] in
            Task { @MainActor in
                self?.notesWindowController?.toggleWindow()
            }
        }
    }
}

@MainActor
final class LaunchAtLoginManager {
    func enable() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Can fail when running from an unbundled binary (e.g. swift run).
            print("Launch-at-login registration failed: \(error)")
        }
    }
}
