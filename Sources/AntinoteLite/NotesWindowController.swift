import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let store: NotesStore
    private let window: NSWindow
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var didResignActiveObserver: NSObjectProtocol?

    init(store: NotesStore) {
        self.store = store
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
            guard self.window.isVisible else { return event }

            let isCommandN = event.keyCode == 45 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            if isCommandN {
                self.store.createNewNote()
                return nil
            }

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
                self?.window.orderOut(nil)
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

    func windowDidResignKey(_ notification: Notification) {
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

            PlainTextEditor(
                text: Binding(
                    get: { store.text },
                    set: { store.text = $0 }
                )
            )
            .padding(EdgeInsets(top: 4, leading: 22, bottom: 24, trailing: 22))
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }
    }
}
