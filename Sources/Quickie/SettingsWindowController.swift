import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(preferences: PreferencesStore) {
        let rootView = SettingsView(preferences: preferences)
        let hostingView = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Quickie Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.contentView = hostingView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Toggle Hotkey")
                    .font(.headline)

                ShortcutRecorderField(preferences: preferences)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Startup")
                    .font(.headline)

                Toggle("Launch at login", isOn: $preferences.launchAtLoginEnabled)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 380, height: 220)
    }
}

private struct ShortcutRecorderField: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            HStack {
                Text(isRecording ? "Type shortcut..." : preferences.hotKeyDisplayGlyphs)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(isRecording ? "Recording" : "Edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonModifiers = PreferencesStore.carbonModifiers(from: modifiers)
            guard carbonModifiers != 0 else {
                return nil
            }

            preferences.updateHotKey(keyCode: UInt32(event.keyCode), eventModifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
