import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let store: NotesStore
    private let searchState = NoteSearchState()
    private let window: NSWindow
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var didResignActiveObserver: NSObjectProtocol?

    init(store: NotesStore) {
        self.store = store
        let contentView = NoteEditorView(
            store: store,
            searchState: searchState,
            onQueryChange: { _ in },
            onSelectResult: { _ in }
        )
        let hostingView = NSHostingView(rootView: contentView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        let rootView = NoteEditorView(
            store: store,
            searchState: searchState,
            onQueryChange: { [weak self] query in
                self?.updateSearch(query: query)
            },
            onSelectResult: { [weak self] result in
                self?.openSearchResult(result)
            }
        )
        hostingView.rootView = rootView

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
        window.setFrameAutosaveName("QuickieMainWindow")
        setWindowControlsVisible(false)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window.isVisible else { return event }
            guard self.window.isKeyWindow || self.searchState.isPresented else { return event }

            if self.searchState.isPresented {
                return self.handleSearchKey(event)
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandN = event.keyCode == 45 && modifiers.contains(.command)
            if isCommandN {
                self.store.createNewNote()
                return nil
            }

            let isCommandF = event.keyCode == 3 && modifiers.contains(.command)
            if isCommandF {
                self.showSearch()
                return nil
            }

            if event.keyCode == 53 {
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
            hideSearch()
            window.orderOut(nil)
            setWindowControlsVisible(false)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateWindowControlsVisibility()
    }

    func createNewNoteAndShow() {
        store.createNewNote()
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            updateWindowControlsVisibility()
        }
    }

    func showSearch() {
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        searchState.isPresented = true
        searchState.query = ""
        searchState.selectedIndex = 0
        searchState.results = store.searchNotes(query: "")
    }

    func windowWillClose(_ notification: Notification) {
        hideSearch()
        window.orderOut(nil)
        setWindowControlsVisible(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if NSApp.isActive, NSApp.keyWindow != nil {
                self.setWindowControlsVisible(false)
                return
            }

            self.hideSearch()
            self.window.orderOut(nil)
            self.setWindowControlsVisible(false)
        }
    }

    private func handleSearchKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 3, modifiers.contains(.command) {
            hideSearch()
            return nil
        }

        switch event.keyCode {
        case 53: // Escape
            hideSearch()
            return nil
        case 125: // Down
            guard !searchState.results.isEmpty else { return nil }
            searchState.selectedIndex = min(searchState.selectedIndex + 1, searchState.results.count - 1)
            return nil
        case 126: // Up
            guard !searchState.results.isEmpty else { return nil }
            searchState.selectedIndex = max(searchState.selectedIndex - 1, 0)
            return nil
        case 36, 76: // Return
            guard searchState.results.indices.contains(searchState.selectedIndex) else { return nil }
            openSearchResult(searchState.results[searchState.selectedIndex])
            return nil
        default:
            return event
        }
    }

    private func hideSearch() {
        searchState.isPresented = false
        searchState.query = ""
        searchState.results = []
        searchState.selectedIndex = 0
    }

    private func openSearchResult(_ result: NoteSearchResult) {
        store.openNote(at: result.fileURL)
        hideSearch()
    }

    private func updateSearch(query: String) {
        searchState.results = store.searchNotes(query: query)
        if searchState.results.isEmpty {
            searchState.selectedIndex = 0
            return
        }
        searchState.selectedIndex = min(searchState.selectedIndex, searchState.results.count - 1)
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

@MainActor
private final class NoteSearchState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var results: [NoteSearchResult] = []
    @Published var selectedIndex = 0
}

private struct NoteEditorView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var searchState: NoteSearchState
    let onQueryChange: (String) -> Void
    let onSelectResult: (NoteSearchResult) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            DottedPaperOverlay()
                .ignoresSafeArea()

            PlainTextEditor(
                text: Binding(
                    get: { store.text },
                    set: { store.text = $0 }
                )
            )
            .padding(EdgeInsets(top: 4, leading: 22, bottom: 24, trailing: 22))

            if searchState.isPresented {
                SearchOverlayView(
                    query: Binding(
                        get: { searchState.query },
                        set: { searchState.query = $0 }
                    ),
                    results: searchState.results,
                    selectedIndex: searchState.selectedIndex,
                    onSelect: onSelectResult
                )
                .padding(.top, 8)
                .padding(.horizontal, 14)
                .zIndex(2)
            }
        }
        .onChange(of: searchState.query) { _, newValue in
            onQueryChange(newValue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }
}

private struct SearchOverlayView: View {
    @Binding var query: String
    let results: [NoteSearchResult]
    let selectedIndex: Int
    let onSelect: (NoteSearchResult) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search notes...", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.black.opacity(0.22))
                )

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            onSelect(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if !result.snippet.isEmpty {
                                    Text(highlightedSnippet(line: result.snippet, query: query))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(index == selectedIndex ? .white.opacity(0.05) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
        )
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    private func highlightedSnippet(line: String, query: String) -> AttributedString {
        var attributed = AttributedString(line)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return attributed
        }

        let lowerLine = line.lowercased()
        let lowerQuery = trimmedQuery.lowercased()
        var searchStart = lowerLine.startIndex

        while searchStart < lowerLine.endIndex,
              let foundRange = lowerLine.range(of: lowerQuery, options: [], range: searchStart..<lowerLine.endIndex) {
            if let lower = AttributedString.Index(foundRange.lowerBound, within: attributed),
               let upper = AttributedString.Index(foundRange.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .primary
                attributed[lower..<upper].backgroundColor = .init(Color.accentColor.opacity(0.3))
            }
            searchStart = foundRange.upperBound
        }
        return attributed
    }
}

private struct DottedPaperOverlay: View {
    private let spacing: CGFloat = 18
    private let dotSize: CGFloat = 1.6

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let columns = Int(ceil(size.width / spacing))
                let rows = Int(ceil(size.height / spacing))

                for row in 0...rows {
                    for column in 0...columns {
                        let x = CGFloat(column) * spacing
                        let y = CGFloat(row) * spacing
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.09)))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
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
        textView.allowsUndo = true
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
