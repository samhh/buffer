import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var didResignActiveObserver: NSObjectProtocol?

    init(store: NotesStore) {
        let contentView = NoteEditorView(store: store)
        let hostingView = NSHostingView(rootView: contentView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.contentView = hostingView
        window.setFrameAutosaveName("AntinoteLiteMainWindow")
        setWindowControlsVisible(false)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.window.isVisible {
                self.window.orderOut(nil)
                return nil
            }
            return event
        }

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateWindowControlsVisibility()
            return event
        }

        didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setWindowControlsVisible(false)
            }
        }
    }

    func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            setWindowControlsVisible(false)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateWindowControlsVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        window.orderOut(nil)
        setWindowControlsVisible(false)
    }

    private func updateWindowControlsVisibility() {
        let isHoveringWindow = window.isVisible && NSApp.isActive && window.frame.contains(NSEvent.mouseLocation)
        setWindowControlsVisible(isHoveringWindow)
    }

    private func setWindowControlsVisible(_ visible: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for button in buttons {
            window.standardWindowButton(button)?.isHidden = !visible
        }
    }
}

private struct NoteEditorView: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            TextEditor(
                text: Binding(
                    get: { store.text },
                    set: { store.text = $0 }
                )
            )
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .background(.clear)
            .padding(EdgeInsets(top: 22, leading: 22, bottom: 24, trailing: 22))
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .background(.clear)
    }
}
