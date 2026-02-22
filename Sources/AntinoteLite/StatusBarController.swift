import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let onToggle: () -> Void
    private let onNewNote: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onNewNote: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onNewNote = onNewNote
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu(title: "AntinoteLite")
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Toggle Notes")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let newItem = NSMenuItem(title: "New Note", action: #selector(newNoteFromMenu), keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command]
        menu.addItem(newItem)
        menu.addItem(NSMenuItem(title: "Toggle Notes", action: #selector(toggleFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        menu.items.forEach { $0.target = self }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            onToggle()
            return
        }

        if event.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onToggle()
        }
    }

    @objc private func toggleFromMenu() {
        onToggle()
    }

    @objc private func newNoteFromMenu() {
        onNewNote()
    }

    @objc private func openSettingsFromMenu() {
        onOpenSettings()
    }

    @objc private func quitApp() {
        onQuit()
    }
}
