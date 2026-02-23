import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let store: NotesStore
    private let searchState = NoteSearchState()
    private let inNoteFindState = InNoteFindState()
    private let editorState = EditorFocusState()
    private let editorBridge = EditorBridge()
    private let window: NSWindow
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var didResignActiveObserver: NSObjectProtocol?

    init(store: NotesStore) {
        self.store = store
        let contentView = NoteEditorView(
            store: store,
            searchState: searchState,
            inNoteFindState: inNoteFindState,
            editorState: editorState,
            editorBridge: editorBridge,
            onUserEdit: {},
            onQueryChange: { _ in },
            onInNoteFindQueryChange: { _ in },
            onCloseSearch: {},
            onCloseInNoteFind: {},
            onSelectResult: { _ in },
            onDeleteResult: { _ in },
            onTogglePinResult: { _ in },
            onHoverSearchResultIndex: { _ in },
            onUndoDeletedNote: {},
            onDismissDeletedToast: {}
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
            inNoteFindState: inNoteFindState,
            editorState: editorState,
            editorBridge: editorBridge,
            onUserEdit: { [weak self] in
                withAnimation(.easeOut(duration: 0.18)) {
                    self?.store.clearDeletedNoteUndo()
                }
            },
            onQueryChange: { [weak self] query in
                self?.updateSearch(query: query)
            },
            onInNoteFindQueryChange: { [weak self] query in
                self?.updateInNoteFind(query: query)
            },
            onCloseSearch: { [weak self] in
                self?.hideSearch(refocusEditor: true)
            },
            onCloseInNoteFind: { [weak self] in
                self?.hideInNoteFind(refocusEditor: true)
            },
            onSelectResult: { [weak self] result in
                self?.openSearchResult(result)
            },
            onDeleteResult: { [weak self] result in
                self?.deleteSearchResult(result)
            },
            onTogglePinResult: { [weak self] result in
                self?.togglePinnedSearchResult(result)
            },
            onHoverSearchResultIndex: { [weak self] index in
                guard let self,
                      let index,
                      self.searchState.results.indices.contains(index) else { return }
                self.searchState.selectedIndex = index
            },
            onUndoDeletedNote: { [weak self] in
                self?.undoLastDeletedNote()
            },
            onDismissDeletedToast: { [weak self] in
                withAnimation(.easeOut(duration: 0.18)) {
                    self?.store.dismissDeletedNoteToast()
                }
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
        window.setFrameAutosaveName("BufferMainWindow")
        setWindowControlsVisible(false)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window.isVisible else { return event }
            guard self.window.isKeyWindow || self.searchState.isPresented || self.inNoteFindState.isPresented else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 51, modifiers.contains(.command), self.store.deletedNoteToast != nil {
                withAnimation(.easeOut(duration: 0.18)) {
                    self.store.dismissDeletedNoteToast()
                }
                return nil
            }

            if self.searchState.isPresented {
                return self.handleSearchKey(event)
            }

            if self.inNoteFindState.isPresented {
                return self.handleInNoteFindKey(event)
            }

            let isCommandN = event.keyCode == 45 && modifiers.contains(.command)
            if isCommandN {
                self.createNewNoteAndShow()
                return nil
            }

            let isCommandD = event.keyCode == 2 && modifiers.contains(.command)
            if isCommandD {
                _ = self.store.deleteCurrentNote()
                self.requestEditorFocus()
                return nil
            }

            let isCommandZ = event.keyCode == 6 && modifiers.contains(.command) && !modifiers.contains(.shift)
            let isCommandShiftZ = event.keyCode == 6 && modifiers.contains(.command) && modifiers.contains(.shift)
            if isCommandZ, self.store.deletedNoteToast != nil {
                self.undoLastDeletedNote()
                self.requestEditorFocus()
                return nil
            }
            if isCommandShiftZ {
                if let textView = self.editorBridge.textView {
                    let preRedoLength = (textView.string as NSString).length
                    let preRedoCaret = textView.selectedRange().location
                    textView.undoManager?.redo()
                    let text = textView.string as NSString
                    let postRedoLength = (textView.string as NSString).length
                    let lengthDelta = postRedoLength - preRedoLength
                    let target = min(max(0, preRedoCaret + lengthDelta), text.length)
                    textView.setSelectedRange(NSRange(location: target, length: 0))
                }
                return nil
            }
            if isCommandZ {
                if let textView = self.editorBridge.textView {
                    let preUndoCaret = textView.selectedRange().location
                    let preUndoLength = (textView.string as NSString).length
                    textView.undoManager?.undo()
                    let postUndoLength = (textView.string as NSString).length
                    let lengthDelta = postUndoLength - preUndoLength
                    let selection = textView.selectedRange()
                    if selection.length > 0 {
                        let rangeStart = selection.location
                        let rangeEnd = selection.location + selection.length
                        let text = textView.string as NSString
                        let selectionEndsWithNewline = rangeEnd > rangeStart
                            && rangeEnd - 1 < text.length
                            && {
                                let ch = text.character(at: rangeEnd - 1)
                                return ch == 10 || ch == 13
                            }()
                        let maxCaret = selectionEndsWithNewline ? max(rangeStart, rangeEnd - 1) : rangeEnd
                        let correction: Int
                        if lengthDelta < 0 {
                            correction = -2
                        } else if lengthDelta > 0 {
                            correction = 2
                        } else {
                            correction = 0
                        }
                        let target = preUndoCaret + correction
                        let collapsed = min(max(target, rangeStart), maxCaret)
                        textView.setSelectedRange(NSRange(location: collapsed, length: 0))
                    }
                }
                return nil
            }

            let isCommandP = event.keyCode == 35 && modifiers.contains(.command)
            let isCommandShiftF = event.keyCode == 3 && modifiers.contains(.command) && modifiers.contains(.shift)
            if isCommandP || isCommandShiftF {
                self.showSearch()
                return nil
            }

            let isCommandF = event.keyCode == 3 && modifiers.contains(.command)
            if isCommandF {
                self.showInNoteFind()
                return nil
            }

            let isCommandG = event.keyCode == 5 && modifiers.contains(.command)
            if isCommandG {
                if self.inNoteFindState.isPresented {
                    self.navigateInNoteFind(forward: !modifiers.contains(.shift))
                } else {
                    self.showInNoteFind()
                }
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
            hideInNoteFind(refocusEditor: false)
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
        requestEditorFocus()
    }

    func showSearch() {
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        searchState.highlightColors = NoteSearchState.mochaAccentColors.shuffled()
        searchState.isPresented = true
        searchState.query = ""
        searchState.selectedIndex = 0
        searchState.results = store.searchNotes(query: "")
    }

    func windowWillClose(_ notification: Notification) {
        hideSearch()
        hideInNoteFind(refocusEditor: false)
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
            self.hideInNoteFind(refocusEditor: false)
            self.window.orderOut(nil)
            self.setWindowControlsVisible(false)
        }
    }

    private func handleSearchKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 35, modifiers.contains(.command), modifiers.contains(.shift) {
            togglePinnedSelectedSearchResult()
            return nil
        }
        if event.keyCode == 35, modifiers.contains(.command), !modifiers.contains(.shift) {
            hideSearch(refocusEditor: true)
            return nil
        }
        if event.keyCode == 2, modifiers.contains(.command) {
            deleteSelectedSearchResult()
            return nil
        }
        if event.keyCode == 6, modifiers.contains(.command) {
            undoLastDeletedNote()
            return nil
        }

        switch event.keyCode {
        case 53: // Escape
            hideSearch(refocusEditor: true)
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

    private func handleInNoteFindKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 3, modifiers.contains(.command) {
            hideInNoteFind(refocusEditor: true)
            return nil
        }
        if event.keyCode == 5, modifiers.contains(.command) {
            navigateInNoteFind(forward: !modifiers.contains(.shift))
            return nil
        }

        switch event.keyCode {
        case 53: // Escape
            hideInNoteFind(refocusEditor: true)
            return nil
        case 36, 76: // Return
            navigateInNoteFind(forward: !modifiers.contains(.shift))
            return nil
        default:
            return event
        }
    }

    private func hideSearch() {
        hideSearch(refocusEditor: false)
    }

    private func hideSearch(refocusEditor: Bool) {
        searchState.isPresented = false
        searchState.query = ""
        searchState.results = []
        searchState.selectedIndex = 0
        if refocusEditor {
            requestEditorFocus()
        }
    }

    private func showInNoteFind() {
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        if inNoteFindState.isPresented {
            hideInNoteFind(refocusEditor: true)
            return
        }

        inNoteFindState.isPresented = true
        updateInNoteFind(query: inNoteFindState.query)
    }

    private func hideInNoteFind(refocusEditor: Bool) {
        inNoteFindState.isPresented = false
        inNoteFindState.query = ""
        inNoteFindState.matchCount = 0
        inNoteFindState.currentMatchIndex = 0
        if refocusEditor {
            requestEditorFocus()
        }
    }

    private func openSearchResult(_ result: NoteSearchResult) {
        store.openNote(at: result.fileURL)
        hideSearch()
        requestEditorFocus()
    }

    private func deleteSelectedSearchResult() {
        guard searchState.results.indices.contains(searchState.selectedIndex) else {
            return
        }
        deleteSearchResult(searchState.results[searchState.selectedIndex])
    }

    private func deleteSearchResult(_ result: NoteSearchResult) {
        let deletedIndex = searchState.results.firstIndex(where: { $0.id == result.id }) ?? searchState.selectedIndex
        guard store.deleteNote(at: result.fileURL) != nil else {
            return
        }

        searchState.results = store.searchNotes(query: searchState.query)
        if searchState.results.isEmpty {
            searchState.selectedIndex = 0
        } else {
            searchState.selectedIndex = min(deletedIndex, searchState.results.count - 1)
        }
    }

    private func togglePinnedSelectedSearchResult() {
        guard searchState.results.indices.contains(searchState.selectedIndex) else {
            return
        }
        togglePinnedSearchResult(searchState.results[searchState.selectedIndex])
    }

    private func togglePinnedSearchResult(_ result: NoteSearchResult) {
        _ = store.togglePinned(at: result.fileURL)
        searchState.results = store.searchNotes(query: searchState.query)
        if let restoredIndex = searchState.results.firstIndex(where: { $0.fileURL == result.fileURL }) {
            searchState.selectedIndex = restoredIndex
        } else if searchState.results.isEmpty {
            searchState.selectedIndex = 0
        } else {
            searchState.selectedIndex = min(searchState.selectedIndex, searchState.results.count - 1)
        }
    }

    private func undoLastDeletedNote() {
        guard let restored = store.undoLastDeletedNote() else {
            return
        }
        if searchState.isPresented {
            searchState.results = store.searchNotes(query: searchState.query)
            if let restoredIndex = searchState.results.firstIndex(where: { $0.fileURL == restored.fileURL }) {
                searchState.selectedIndex = restoredIndex
            } else if searchState.results.isEmpty {
                searchState.selectedIndex = 0
            } else {
                searchState.selectedIndex = min(searchState.selectedIndex, searchState.results.count - 1)
            }
        }
    }

    private func updateSearch(query: String) {
        searchState.results = store.searchNotes(query: query)
        if searchState.results.isEmpty {
            searchState.selectedIndex = 0
            return
        }
        searchState.selectedIndex = min(searchState.selectedIndex, searchState.results.count - 1)
    }

    private func updateInNoteFind(query: String) {
        guard let textView = editorBridge.textView else {
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inNoteFindState.matchCount = 0
            inNoteFindState.currentMatchIndex = 0
            return
        }

        let ranges = findRanges(in: textView.string as NSString, query: trimmed)
        inNoteFindState.matchCount = ranges.count
        guard !ranges.isEmpty else {
            inNoteFindState.currentMatchIndex = 0
            return
        }

        let selection = textView.selectedRange()
        let index = ranges.firstIndex(where: { $0.location >= selection.location }) ?? 0
        // Keep focus in the inline find field while typing.
        textView.setSelectedRange(ranges[index])
        textView.scrollRangeToVisible(ranges[index])
        inNoteFindState.currentMatchIndex = index + 1
    }

    private func navigateInNoteFind(forward: Bool) {
        guard let textView = editorBridge.textView else { return }
        let trimmed = inNoteFindState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ranges = findRanges(in: textView.string as NSString, query: trimmed)
        guard !ranges.isEmpty else { return }

        let current = textView.selectedRange()
        let currentIndex = ranges.firstIndex(where: { NSEqualRanges($0, current) })
        let targetIndex: Int
        if let currentIndex {
            if forward {
                targetIndex = (currentIndex + 1) % ranges.count
            } else {
                targetIndex = (currentIndex - 1 + ranges.count) % ranges.count
            }
        } else if forward {
            targetIndex = ranges.firstIndex(where: { $0.location > current.location }) ?? 0
        } else {
            targetIndex = ranges.lastIndex(where: { $0.location < current.location }) ?? (ranges.count - 1)
        }

        let target = ranges[targetIndex]
        selectInNoteFindRange(target, in: textView)
        inNoteFindState.currentMatchIndex = targetIndex + 1
        inNoteFindState.matchCount = ranges.count
    }

    private func selectInNoteFindRange(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private func findRanges(in text: NSString, query: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: query, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound {
                break
            }
            ranges.append(found)
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= text.length {
                break
            }
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }
        return ranges
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

    private func requestEditorFocus() {
        editorState.focusToken += 1
    }

}

@MainActor
private final class NoteSearchState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var results: [NoteSearchResult] = []
    @Published var selectedIndex = 0
    @Published var highlightColors: [Color] = mochaAccentColors

    static let mochaAccentColors: [Color] = [
        Color(hex: 0xF5E0DC), // Rosewater
        Color(hex: 0xF2CDCD), // Flamingo
        Color(hex: 0xF5C2E7), // Pink
        Color(hex: 0xCBA6F7), // Mauve
        Color(hex: 0xF38BA8), // Red
        Color(hex: 0xEBA0AC), // Maroon
        Color(hex: 0xFAB387), // Peach
        Color(hex: 0xF9E2AF), // Yellow
        Color(hex: 0xA6E3A1), // Green
        Color(hex: 0x94E2D5), // Teal
        Color(hex: 0x89DCEB), // Sky
        Color(hex: 0x74C7EC), // Sapphire
        Color(hex: 0x89B4FA), // Blue
        Color(hex: 0xB4BEFE), // Lavender
    ]
}

@MainActor
private final class InNoteFindState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var matchCount = 0
    @Published var currentMatchIndex = 0
}

@MainActor
private final class EditorFocusState: ObservableObject {
    @Published var focusToken: Int = 0
}

@MainActor
private final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
}

private struct NoteEditorView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var searchState: NoteSearchState
    @ObservedObject var inNoteFindState: InNoteFindState
    @ObservedObject var editorState: EditorFocusState
    @ObservedObject var editorBridge: EditorBridge
    let onUserEdit: () -> Void
    let onQueryChange: (String) -> Void
    let onInNoteFindQueryChange: (String) -> Void
    let onCloseSearch: () -> Void
    let onCloseInNoteFind: () -> Void
    let onSelectResult: (NoteSearchResult) -> Void
    let onDeleteResult: (NoteSearchResult) -> Void
    let onTogglePinResult: (NoteSearchResult) -> Void
    let onHoverSearchResultIndex: (Int?) -> Void
    let onUndoDeletedNote: () -> Void
    let onDismissDeletedToast: () -> Void
    @State private var toastDismissWorkItem: DispatchWorkItem?
    @State private var toastRemovalWorkItem: DispatchWorkItem?
    @State private var renderedToast: DeletedNoteToast?
    @State private var isToastVisible = false
    private let toastAnimationDuration: TimeInterval = 0.18
    private let toastAutoDismissDelay: TimeInterval = 5

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()
            DottedPaperOverlay()
                .ignoresSafeArea()

            PlainTextEditor(
                text: Binding(
                    get: { store.text },
                    set: { store.text = $0 }
                ),
                focusToken: editorState.focusToken,
                editorBridge: editorBridge,
                onUserEdit: onUserEdit
            )
            .padding(EdgeInsets(top: 4, leading: 22, bottom: 24, trailing: 22))

            if searchState.isPresented {
                SearchOverlayView(
                    query: Binding(
                        get: { searchState.query },
                        set: { searchState.query = $0 }
                    ),
                    results: searchState.results,
                    selectedIndex: Binding(
                        get: { searchState.selectedIndex },
                        set: { searchState.selectedIndex = $0 }
                    ),
                    highlightColors: searchState.highlightColors,
                    onClose: onCloseSearch,
                    onSelect: onSelectResult,
                    onDelete: onDeleteResult,
                    onTogglePin: onTogglePinResult,
                    onHoverResultIndex: onHoverSearchResultIndex
                )
                .padding(.top, 6)
                .padding(.horizontal, 14)
                .zIndex(2)
            }

            VStack {
                Spacer()
                if inNoteFindState.isPresented {
                    InNoteFindBarView(
                        query: Binding(
                            get: { inNoteFindState.query },
                            set: { inNoteFindState.query = $0 }
                        ),
                        currentIndex: inNoteFindState.currentMatchIndex,
                        totalCount: inNoteFindState.matchCount,
                        onClose: onCloseInNoteFind
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .zIndex(3)
                }
            }

            if let toast = renderedToast {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        DeletedNoteToastView(
                            onUndo: onUndoDeletedNote,
                            onDismiss: dismissToastFromUI
                        )
                    }
                }
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .opacity(isToastVisible ? 1 : 0)
                .offset(y: isToastVisible ? 0 : 12)
                .zIndex(4)
                .id(toast.id)
            }
        }
        .onChange(of: searchState.query) { _, newValue in
            onQueryChange(newValue)
        }
        .onChange(of: inNoteFindState.query) { _, newValue in
            onInNoteFindQueryChange(newValue)
        }
        .onChange(of: store.deletedNoteToast?.id) { _, newToastID in
            toastDismissWorkItem?.cancel()
            toastRemovalWorkItem?.cancel()

            if newToastID == nil {
                guard renderedToast != nil else {
                    isToastVisible = false
                    return
                }
                animateToastOutAndRemove(clearStoreOnCompletion: false)
                return
            }

            renderedToast = store.deletedNoteToast
            isToastVisible = false
            withAnimation(.easeOut(duration: toastAnimationDuration)) {
                isToastVisible = true
            }

            let workItem = DispatchWorkItem {
                dismissToastFromUI()
            }
            toastDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + toastAutoDismissDelay, execute: workItem)
        }
        .onDisappear {
            toastDismissWorkItem?.cancel()
            toastRemovalWorkItem?.cancel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }

    private func dismissToastFromUI() {
        toastDismissWorkItem?.cancel()
        toastRemovalWorkItem?.cancel()
        guard renderedToast != nil else {
            onDismissDeletedToast()
            return
        }
        animateToastOutAndRemove(clearStoreOnCompletion: true)
    }

    private func animateToastOutAndRemove(clearStoreOnCompletion: Bool) {
        withAnimation(.easeOut(duration: toastAnimationDuration)) {
            isToastVisible = false
        }
        let removal = DispatchWorkItem {
            renderedToast = nil
            if clearStoreOnCompletion {
                onDismissDeletedToast()
            }
        }
        toastRemovalWorkItem = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + toastAnimationDuration, execute: removal)
    }
}

private struct DeletedNoteToastView: View {
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Note deleted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Button(action: onUndo) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Undo")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.14))
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.pointingHand.set()
                    DispatchQueue.main.async {
                        NSCursor.pointingHand.set()
                    }
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.17), lineWidth: 1)
                )
        )
    }
}

private struct InNoteFindBarView: View {
    @Binding var query: String
    let currentIndex: Int
    let totalCount: Int
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in note", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
            Text(matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.17), lineWidth: 1)
                )
        )
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }

    private var matchLabel: String {
        guard totalCount > 0 else { return "0" }
        return "\(currentIndex)/\(totalCount)"
    }
}

private struct SearchOverlayView: View {
    @Binding var query: String
    let results: [NoteSearchResult]
    @Binding var selectedIndex: Int
    let highlightColors: [Color]
    let onClose: () -> Void
    let onSelect: (NoteSearchResult) -> Void
    let onDelete: (NoteSearchResult) -> Void
    let onTogglePin: (NoteSearchResult) -> Void
    let onHoverResultIndex: (Int?) -> Void
    @FocusState private var searchFocused: Bool
    @State private var hoveredIndex: Int?
    @State private var hoveredPinIndex: Int?
    @State private var hoveredTrashIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                Text("\(results.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.17), lineWidth: 1)
                    )
            )

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultRow(index: index, result: result)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func resultRow(index: Int, result: NoteSearchResult) -> some View {
        let isActive = index == selectedIndex || index == hoveredIndex
        let showsActions = index == hoveredIndex

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !result.snippet.isEmpty {
                    Text(highlightedSnippet(line: result.snippet, query: query, colors: highlightColors))
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButtons(for: result, at: index, visible: showsActions)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground(isActive: isActive))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(result)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
                hoveredIndex = index
                selectedIndex = index
                onHoverResultIndex(index)
            case .ended:
                if hoveredIndex == index {
                    hoveredIndex = nil
                    hoveredPinIndex = nil
                    hoveredTrashIndex = nil
                    onHoverResultIndex(nil)
                }
                NSCursor.arrow.set()
            }
        }
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? .black.opacity(0.07) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isActive ? .white.opacity(0.30) : .clear, lineWidth: 1)
            )
    }

    private func actionButtons(for result: NoteSearchResult, at index: Int, visible: Bool) -> some View {
        ZStack {
            if visible || result.isPinned {
                HStack(spacing: 4) {
                    Button {
                        onTogglePin(result)
                    } label: {
                        Image(systemName: result.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                            .offset(y: 1)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .padding(2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(hoveredPinIndex == index ? .white.opacity(0.10) : .clear)
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .onHover { hovering in
                        hoveredPinIndex = hovering ? index : nil
                    }
                    .buttonStyle(.plain)
                    .help(result.isPinned ? "Unpin note (Cmd+Shift+P)" : "Pin note (Cmd+Shift+P)")

                    if visible {
                        Button {
                            onDelete(result)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .padding(2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(hoveredTrashIndex == index ? .white.opacity(0.10) : .clear)
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .onHover { hovering in
                            hoveredTrashIndex = hovering ? index : nil
                        }
                        .buttonStyle(.plain)
                        .help("Delete note (Cmd+D)")
                    }
                }
            }
        }
        .frame(width: 40, height: 16, alignment: .trailing)
    }

    private func highlightedSnippet(line: String, query: String, colors: [Color]) -> AttributedString {
        var attributed = AttributedString(line)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return attributed
        }

        let lowerLine = line.lowercased()
        let lowerQuery = trimmedQuery.lowercased()
        var searchStart = lowerLine.startIndex
        var matchIndex = 0

        while searchStart < lowerLine.endIndex,
              let foundRange = lowerLine.range(of: lowerQuery, options: [], range: searchStart..<lowerLine.endIndex) {
            if let lower = AttributedString.Index(foundRange.lowerBound, within: attributed),
               let upper = AttributedString.Index(foundRange.upperBound, within: attributed) {
                let color = colors[matchIndex % colors.count]
                attributed[lower..<upper].foregroundColor = .primary
                attributed[lower..<upper].backgroundColor = .init(color.opacity(0.78))
            }
            searchStart = foundRange.upperBound
            matchIndex += 1
        }
        return attributed
    }
}

private extension Color {
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

private struct DottedPaperOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    private let spacing: CGFloat = 18
    private let dotSize: CGFloat = 1.6
    private var dotColor: Color {
        colorScheme == .dark ? .white.opacity(0.09) : .black.opacity(0.10)
    }

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
                        context.fill(Path(ellipseIn: rect), with: .color(dotColor))
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
    let focusToken: Int
    @ObservedObject var editorBridge: EditorBridge
    let onUserEdit: () -> Void
    private static let editorParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUserEdit: onUserEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = ListBulletLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = LineDeleteOnCutTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 16, height: 8)
        textView.defaultParagraphStyle = Self.editorParagraphStyle
        textView.typingAttributes[.paragraphStyle] = Self.editorParagraphStyle
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.string = text
        applyParagraphStyle(in: textView)
        editorBridge.textView = textView

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
        editorBridge.textView = textView

        if textView.string != text {
            textView.string = text
            applyParagraphStyle(in: textView)
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onUserEdit: () -> Void
        var lastFocusToken: Int = -1

        init(text: Binding<String>, onUserEdit: @escaping () -> Void) {
            _text = text
            self.onUserEdit = onUserEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
            textView.setNeedsDisplay(textView.bounds)
            onUserEdit()
        }
    }

    private func applyParagraphStyle(in textView: NSTextView) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        guard fullRange.length > 0 else { return }
        textView.textStorage?.addAttribute(.paragraphStyle, value: Self.editorParagraphStyle, range: fullRange)
    }
}

private final class LineDeleteOnCutTextView: NSTextView {
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(cut(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isOptionArrow = modifiers.contains(.option) && !modifiers.contains(.command) && !modifiers.contains(.control)
        if isOptionArrow {
            if event.keyCode == 126, applySmartListEdit(action: .moveLineUp) {
                return
            }
            if event.keyCode == 125, applySmartListEdit(action: .moveLineDown) {
                return
            }
        }

        let isPlainTab = event.keyCode == 48 && !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option)
        if isPlainTab {
            if modifiers.contains(.shift) {
                if applySmartListEdit(action: .unindent) {
                    return
                }
            } else {
                if applySmartListEdit(action: .indent) {
                    return
                }
            }
        }

        let isPlainEnter = (event.keyCode == 36 || event.keyCode == 76) && !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option)
        if isPlainEnter {
            insertNewline(self)
            return
        }

        super.keyDown(with: event)
    }

    override func cut(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 {
            super.cut(sender)
            return
        }

        let nsText = string as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        guard shouldChangeText(in: lineRange, replacementString: "") else {
            return
        }

        textStorage?.replaceCharacters(in: lineRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(lineRange.location, (string as NSString).length), length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        if applySmartListEdit(action: .backspace) {
            return
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if applySmartListEdit(action: .enter) {
            return
        }

        super.insertNewline(sender)
    }

    private func applySmartListEdit(action: SmartListAction) -> Bool {
        let currentText = string
        let edit = SmartListEditing.makeEdit(text: currentText, selection: selectedRange(), action: action)
        guard edit.handled else {
            return false
        }

        guard shouldChangeText(in: edit.replacementRange, replacementString: edit.replacement) else {
            return false
        }

        textStorage?.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        setSelectedRange(edit.selection)
        didChangeText()
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
        setNeedsDisplay(bounds)
        scrollRangeToVisible(edit.selection)
        return true
    }
}

private final class ListBulletLayoutManager: NSLayoutManager {
    private let indentWidth = (SmartListEditing.indentUnit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
    private let markerCenterYOffset: CGFloat = 10

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawIndentMarkers(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawIndentMarkers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        let lines = RootGroupStyling.parseLines(in: text)
        guard !lines.isEmpty else { return }

        let markerColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.50, green: 0.50, blue: 0.54, alpha: 1)
            }
            return NSColor(srgbRed: 0.68, green: 0.68, blue: 0.72, alpha: 1)
        }
        markerColor.setStroke()

        for line in lines where line.depth > 0 {
            let glyphIndex = glyphIndexForCharacter(at: line.contentRange.location)
            guard glyphIndex != NSNotFound else { continue }
            if NSIntersectionRange(glyphsToShow, NSRange(location: glyphIndex, length: 1)).length == 0 {
                continue
            }
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let lineOriginX = origin.x + lineRect.minX
            let markerCenterY = origin.y + lineRect.minY + markerCenterYOffset
            for level in 0..<line.depth {
                let markerCenterX = lineOriginX + (CGFloat(level) * indentWidth) + (indentWidth * 0.5) + 3
                drawTabMarker(at: NSPoint(x: markerCenterX, y: markerCenterY))
            }
        }
    }

    private func drawTabMarker(at point: NSPoint) {
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: point.x - 2.4, y: point.y - 1.8))
        marker.line(to: NSPoint(x: point.x - 2.4, y: point.y + 1.8))
        marker.move(to: NSPoint(x: point.x - 2.4, y: point.y))
        marker.line(to: NSPoint(x: point.x + 2.4, y: point.y))
        marker.line(to: NSPoint(x: point.x + 1.1, y: point.y + 1.0))
        marker.move(to: NSPoint(x: point.x + 2.4, y: point.y))
        marker.line(to: NSPoint(x: point.x + 1.1, y: point.y - 1.0))
        marker.lineWidth = 1.0
        marker.lineCapStyle = .round
        marker.lineJoinStyle = .round
        marker.stroke()
    }

}
