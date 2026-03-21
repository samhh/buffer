import AppKit
import SwiftUI

private struct MainQueuedAction: @unchecked Sendable {
    let action: () -> Void
}

private func scheduleOnMain(_ action: @escaping () -> Void) {
    let queued = MainQueuedAction(action: action)
    DispatchQueue.main.async {
        queued.action()
    }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let store: NotesStore
    private let searchState = NoteSearchState()
    private let inNoteFindState = InNoteFindState()
    private let editorState = EditorFocusState()
    private let writingModeState = WritingModeState()
    private let editorBridge = EditorBridge()
    private let window: NSPanel
    private let defaults = UserDefaults.standard
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var didResignActiveObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var inNoteFindHighlightedRange: NSRange?
    private var inNoteFindSecondaryRanges: [NSRange] = []
    private let normalDefaultFrame = NSRect(x: 0, y: 0, width: 500, height: 400)
    private let writingDefaultFrame = NSRect(x: 0, y: 0, width: 900, height: 700)

    private func hasOnlyCommandModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection(.deviceIndependentFlagsMask)
        return relevant == [.command]
    }

    private func matchesCommandKey(
        _ event: NSEvent,
        key: String,
        allowShift: Bool = false
    ) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if allowShift {
            guard modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control) else {
                return false
            }
        } else {
            guard hasOnlyCommandModifiers(modifiers) else {
                return false
            }
        }

        return KeyboardLayoutMapper.normalizedKey(from: event) == key
    }

    init(store: NotesStore) {
        self.store = store
        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        window = NotesPanel(
            contentRect: normalDefaultFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        let rootView = NoteEditorView(
            store: store,
            searchState: searchState,
            inNoteFindState: inNoteFindState,
            editorState: editorState,
            writingModeState: writingModeState,
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
            onHoverSearchResultID: { [weak self] id in
                guard let self, let id else { return }
                self.searchState.selectedResultID = id
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
        hostingView.rootView = AnyView(rootView)

        window.isReleasedWhenClosed = false
        // Keep Buffer above utility panels from other menu bar apps (for example Raycast Notes).
        window.level = .statusBar
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.delegate = self
        window.contentView = hostingView
        setWindowControlsVisible(false)
        restoreInitialFrame()

        store.cursorStateProvider = { [weak self] in
            self?.editorBridge.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        }

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

            let isCommandEnter = (event.keyCode == 36 || event.keyCode == 76)
                && modifiers.contains(.command)
                && !modifiers.contains(.shift)
                && !modifiers.contains(.option)
                && !modifiers.contains(.control)
            if isCommandEnter {
                self.toggleWritingMode()
                return nil
            }

            let isCommandN = self.matchesCommandKey(event, key: "n")
            if isCommandN {
                self.createNewNoteAndShow()
                return nil
            }

            let isCommandD = self.matchesCommandKey(event, key: "d")
            if isCommandD {
                _ = self.store.deleteCurrentNote()
                self.requestEditorFocus()
                return nil
            }

            let isCommandZ = self.matchesCommandKey(event, key: "z")
            let isCommandShiftZ = self.matchesCommandKey(event, key: "z", allowShift: true) && modifiers.contains(.shift)
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

            let isCommandP = self.matchesCommandKey(event, key: "p")
            let isCommandShiftF = self.matchesCommandKey(event, key: "f", allowShift: true) && modifiers.contains(.shift)
            if isCommandP || isCommandShiftF {
                self.showSearch()
                return nil
            }

            let isCommandF = self.matchesCommandKey(event, key: "f")
            if isCommandF {
                self.showInNoteFind()
                return nil
            }

            let isCommandG = self.matchesCommandKey(event, key: "g", allowShift: true)
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
            if self?.searchState.isPresented == true {
                self?.searchState.hoverSelectionEnabled = true
            }
            self?.updateWindowControlsVisibility()
            return event
        }

        // Hide the panel when the user clicks outside of it. Using a global
        // mouse-down monitor instead of didResignActiveNotification avoids
        // false dismissals from system panels (emoji picker, etc.) that steal
        // focus without an explicit user click away from the panel.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.window.isVisible else { return }
            if self.writingModeState.isEnabled { return }
            self.hideSearch()
            self.hideInNoteFind(refocusEditor: false)
            self.window.orderOut(nil)
            self.setWindowControlsVisible(false)
        }
    }

    @MainActor deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let didResignActiveObserver {
            NotificationCenter.default.removeObserver(didResignActiveObserver)
            self.didResignActiveObserver = nil
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

        bringToFront()
        updateWindowControlsVisibility()
    }

    func createNewNoteAndShow() {
        store.createNewNote()
        if !window.isVisible {
            bringToFront()
            updateWindowControlsVisibility()
        }
        requestEditorFocus()
    }

    func showSearch() {
        if !window.isVisible {
            bringToFront()
        }
        searchState.highlightColors = NoteSearchState.mochaAccentColors.shuffled()
        searchState.isPresented = true
        searchState.hasTypedQueryInSession = false
        searchState.hoverSelectionEnabled = true
        if let linkAwareTextView = editorBridge.textView as? LineDeleteOnCutTextView {
            linkAwareTextView.searchOverlayPresented = true
            linkAwareTextView.window?.invalidateCursorRects(for: linkAwareTextView)
        }
        searchState.query = ""
        searchState.results = store.searchNotes(query: "")
        selectCurrentNoteSearchResultOrFallback()
    }

    func windowWillClose(_ notification: Notification) {
        hideSearch()
        hideInNoteFind(refocusEditor: false)
        window.orderOut(nil)
        setWindowControlsVisible(false)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(forWritingModeEnabled: writingModeState.isEnabled)
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setWindowControlsVisible(false)
        }
    }

    private func handleSearchKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if matchesCommandKey(event, key: "p", allowShift: true), modifiers.contains(.shift) {
            togglePinnedSelectedSearchResult()
            return nil
        }
        if matchesCommandKey(event, key: "p") {
            hideSearch(refocusEditor: true)
            return nil
        }
        if matchesCommandKey(event, key: "d") {
            deleteSelectedSearchResult()
            return nil
        }
        if matchesCommandKey(event, key: "z", allowShift: true) {
            if modifiers.contains(.shift) || isEditingSearchInputField() {
                return event
            }
            undoLastDeletedNote()
            return nil
        }

        let isCommandUp = modifiers.contains(.command) && (event.keyCode == 126 || event.keyCode == 116 || event.keyCode == 115)
        if isCommandUp {
            searchState.hoverSelectionEnabled = false
            searchState.selectedResultID = searchState.results.first?.id
            return nil
        }

        let isCommandDown = modifiers.contains(.command) && (event.keyCode == 125 || event.keyCode == 121 || event.keyCode == 119)
        if isCommandDown {
            searchState.hoverSelectionEnabled = false
            searchState.selectedResultID = searchState.results.last?.id
            return nil
        }

        switch event.keyCode {
        case 53: // Escape
            hideSearch(refocusEditor: true)
            return nil
        case 125: // Down
            guard let next = relativeSearchResult(step: 1) else { return nil }
            searchState.hoverSelectionEnabled = false
            searchState.selectedResultID = next.id
            return nil
        case 126: // Up
            guard let previous = relativeSearchResult(step: -1) else { return nil }
            searchState.hoverSelectionEnabled = false
            searchState.selectedResultID = previous.id
            return nil
        case 36, 76: // Return
            guard let selected = selectedSearchResult() else { return nil }
            openSearchResult(selected)
            return nil
        default:
            return event
        }
    }

    private func isEditingSearchInputField() -> Bool {
        guard let firstResponder = window.firstResponder as? NSTextView else {
            return false
        }
        return firstResponder.isFieldEditor
    }

    private func handleInNoteFindKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if matchesCommandKey(event, key: "f") {
            hideInNoteFind(refocusEditor: true)
            return nil
        }
        if matchesCommandKey(event, key: "g", allowShift: true) {
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
        if let linkAwareTextView = editorBridge.textView as? LineDeleteOnCutTextView {
            linkAwareTextView.searchOverlayPresented = false
            linkAwareTextView.window?.invalidateCursorRects(for: linkAwareTextView)
        }
        searchState.hasTypedQueryInSession = false
        searchState.query = ""
        searchState.results = []
        searchState.selectedResultID = nil
        if refocusEditor {
            requestEditorFocus()
        }
    }

    private func showInNoteFind() {
        if !window.isVisible {
            bringToFront()
        }

        if inNoteFindState.isPresented {
            hideInNoteFind(refocusEditor: true)
            return
        }

        inNoteFindState.isPresented = true
        updateInNoteFind(query: inNoteFindState.query)
    }

    private func hideInNoteFind(refocusEditor: Bool) {
        let finalSelection = inNoteFindHighlightedRange
        clearInNoteFindHighlight()
        if let finalSelection,
           let textView = editorBridge.textView {
            textView.setSelectedRange(finalSelection)
            textView.scrollRangeToVisible(finalSelection)
        }
        inNoteFindState.isPresented = false
        inNoteFindState.query = ""
        inNoteFindState.matchCount = 0
        inNoteFindState.currentMatchIndex = 0
        if refocusEditor {
            requestEditorFocus()
        }
    }

    private func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func toggleWritingMode() {
        saveFrame(forWritingModeEnabled: writingModeState.isEnabled)
        writingModeState.isEnabled.toggle()
        let targetFrame = restoredFrame(forWritingModeEnabled: writingModeState.isEnabled)
        if !window.isVisible {
            bringToFront()
        }
        window.setFrame(targetFrame, display: true, animate: false)
        requestEditorFocus()
    }

    private func openSearchResult(_ result: NoteSearchResult) {
        store.openNote(at: result.fileURL)
        hideSearch()
        requestEditorFocus()
    }

    private func deleteSelectedSearchResult() {
        guard let selected = selectedSearchResult() else { return }
        deleteSearchResult(selected)
    }

    private func deleteSearchResult(_ result: NoteSearchResult) {
        let deletedIndex = searchState.results.firstIndex(where: { $0.id == result.id }) ?? 0
        guard store.deleteNote(at: result.fileURL) != nil else {
            return
        }

        searchState.results = store.searchNotes(query: searchState.query)
        if searchState.results.isEmpty {
            searchState.selectedResultID = nil
        } else {
            let fallbackIndex = min(deletedIndex, searchState.results.count - 1)
            searchState.selectedResultID = searchState.results[fallbackIndex].id
        }
    }

    private func togglePinnedSelectedSearchResult() {
        guard let selected = selectedSearchResult() else { return }
        togglePinnedSearchResult(selected)
    }

    private func togglePinnedSearchResult(_ result: NoteSearchResult) {
        _ = store.togglePinned(at: result.fileURL)
        searchState.results = store.searchNotes(query: searchState.query)
        if let restored = searchState.results.first(where: { $0.fileURL == result.fileURL }) {
            searchState.selectedResultID = restored.id
        } else if searchState.results.isEmpty {
            searchState.selectedResultID = nil
        } else {
            searchState.selectedResultID = searchState.results[0].id
        }
    }

    private func undoLastDeletedNote() {
        guard let restored = store.undoLastDeletedNote() else {
            return
        }
        if searchState.isPresented {
            searchState.results = store.searchNotes(query: searchState.query)
            if let restoredResult = searchState.results.first(where: { $0.fileURL == restored.fileURL }) {
                searchState.selectedResultID = restoredResult.id
            } else if searchState.results.isEmpty {
                searchState.selectedResultID = nil
            } else {
                searchState.selectedResultID = searchState.results[0].id
            }
        }
    }

    private func updateSearch(query: String) {
        let hadTypedQuery = searchState.hasTypedQueryInSession
        if !query.isEmpty {
            searchState.hasTypedQueryInSession = true
        }
        searchState.results = store.searchNotes(query: query)
        let typedThisUpdate = !hadTypedQuery && searchState.hasTypedQueryInSession
        selectCurrentNoteSearchResultOrFallback(forceFirstResult: typedThisUpdate)
    }

    private func selectCurrentNoteSearchResultOrFallback(forceFirstResult: Bool = false) {
        if searchState.results.isEmpty {
            searchState.selectedResultID = nil
            return
        }

        if forceFirstResult {
            searchState.selectedResultID = searchState.results[0].id
            return
        }

        if !searchState.hasTypedQueryInSession,
           let current = searchState.results.first(where: { $0.fileURL == store.currentNoteFileURL }) {
            searchState.selectedResultID = current.id
            return
        }

        if let selectedID = searchState.selectedResultID,
           searchState.results.contains(where: { $0.id == selectedID }) {
            return
        }
        searchState.selectedResultID = searchState.results[0].id
    }

    private func selectedSearchResult() -> NoteSearchResult? {
        guard !searchState.results.isEmpty else { return nil }
        guard let selectedID = searchState.selectedResultID else {
            return searchState.results.first
        }
        return searchState.results.first(where: { $0.id == selectedID }) ?? searchState.results.first
    }

    private func relativeSearchResult(step: Int) -> NoteSearchResult? {
        guard !searchState.results.isEmpty else { return nil }
        let currentIndex: Int
        if let selectedID = searchState.selectedResultID,
           let resolvedIndex = searchState.results.firstIndex(where: { $0.id == selectedID }) {
            currentIndex = resolvedIndex
        } else {
            currentIndex = 0
        }
        let nextIndex = min(max(currentIndex + step, 0), searchState.results.count - 1)
        return searchState.results[nextIndex]
    }

    private func updateInNoteFind(query: String) {
        guard let textView = editorBridge.textView else {
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearInNoteFindHighlight(in: textView)
            inNoteFindState.matchCount = 0
            inNoteFindState.currentMatchIndex = 0
            return
        }

        let ranges = findRanges(in: textView.string as NSString, query: trimmed)
        inNoteFindState.matchCount = ranges.count
        guard !ranges.isEmpty else {
            clearInNoteFindHighlight(in: textView)
            inNoteFindState.currentMatchIndex = 0
            return
        }

        let selection = textView.selectedRange()
        let index = ranges.firstIndex(where: { $0.location >= selection.location }) ?? 0
        highlightInNoteFindRanges(ranges, activeRange: ranges[index], in: textView)
        inNoteFindState.currentMatchIndex = index + 1
    }

    private func navigateInNoteFind(forward: Bool) {
        guard let textView = editorBridge.textView else { return }
        let trimmed = inNoteFindState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ranges = findRanges(in: textView.string as NSString, query: trimmed)
        guard !ranges.isEmpty else { return }

        let current = textView.selectedRange()
        let currentIndex = inNoteFindHighlightedRange.flatMap { highlighted in
            ranges.firstIndex(where: { NSEqualRanges($0, highlighted) })
        }
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
        highlightInNoteFindRanges(ranges, activeRange: target, in: textView)
        inNoteFindState.currentMatchIndex = targetIndex + 1
        inNoteFindState.matchCount = ranges.count
    }

    private func highlightInNoteFindRanges(_ ranges: [NSRange], activeRange: NSRange, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            return
        }
        clearInNoteFindHighlight(in: textView)
        for range in ranges where !NSEqualRanges(range, activeRange) {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemBlue.withAlphaComponent(0.22),
                forCharacterRange: range
            )
            inNoteFindSecondaryRanges.append(range)
        }
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.systemBlue.withAlphaComponent(0.9),
            forCharacterRange: activeRange
        )
        layoutManager.addTemporaryAttribute(
            .foregroundColor,
            value: NSColor.white,
            forCharacterRange: activeRange
        )
        // Keep find-field focus while anchoring navigation at the highlighted match.
        textView.setSelectedRange(NSRange(location: activeRange.location, length: 0))
        textView.scrollRangeToVisible(activeRange)
        inNoteFindHighlightedRange = activeRange
    }

    private func clearInNoteFindHighlight(in textView: NSTextView? = nil) {
        let target = textView ?? editorBridge.textView
        guard let textView = target,
              let layoutManager = textView.layoutManager else {
            inNoteFindHighlightedRange = nil
            return
        }
        if let previous = inNoteFindHighlightedRange {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: previous)
        }
        for range in inNoteFindSecondaryRanges {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        inNoteFindSecondaryRanges.removeAll(keepingCapacity: true)
        inNoteFindHighlightedRange = nil
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

    private func restoreInitialFrame() {
        let restored = restoredFrame(forWritingModeEnabled: false)
        window.setFrame(restored, display: false)
    }

    private func restoredFrame(forWritingModeEnabled isWriting: Bool) -> NSRect {
        let key = frameDefaultsKey(forWritingModeEnabled: isWriting)
        if let frameString = defaults.string(forKey: key) {
            return NSRectFromString(frameString)
        }
        return centeredDefaultFrame(forWritingModeEnabled: isWriting)
    }

    private func centeredDefaultFrame(forWritingModeEnabled isWriting: Bool) -> NSRect {
        let defaultFrame = isWriting ? writingDefaultFrame : normalDefaultFrame
        let referenceScreen = window.screen ?? NSScreen.main
        guard let screenFrame = referenceScreen?.visibleFrame else {
            return defaultFrame
        }
        return NSRect(
            x: screenFrame.midX - (defaultFrame.width / 2),
            y: screenFrame.midY - (defaultFrame.height / 2),
            width: defaultFrame.width,
            height: defaultFrame.height
        )
    }

    private func saveFrame(forWritingModeEnabled isWriting: Bool) {
        defaults.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey(forWritingModeEnabled: isWriting))
    }

    private func frameDefaultsKey(forWritingModeEnabled isWriting: Bool) -> String {
        isWriting ? "window.frame.writing" : "window.frame.normal"
    }
}

private final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class NoteSearchState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var hasTypedQueryInSession = false
    @Published var results: [NoteSearchResult] = []
    @Published var selectedResultID: NoteSearchResult.ID?
    @Published var hoverSelectionEnabled = true
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
private final class WritingModeState: ObservableObject {
    @Published var isEnabled = false
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
    @ObservedObject var writingModeState: WritingModeState
    @ObservedObject var editorBridge: EditorBridge
    let onUserEdit: () -> Void
    let onQueryChange: (String) -> Void
    let onInNoteFindQueryChange: (String) -> Void
    let onCloseSearch: () -> Void
    let onCloseInNoteFind: () -> Void
    let onSelectResult: (NoteSearchResult) -> Void
    let onDeleteResult: (NoteSearchResult) -> Void
    let onTogglePinResult: (NoteSearchResult) -> Void
    let onHoverSearchResultID: (NoteSearchResult.ID?) -> Void
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
                writingModeEnabled: writingModeState.isEnabled,
                editorBridge: editorBridge,
                store: store,
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
                    selectedResultID: Binding(
                        get: { searchState.selectedResultID },
                        set: { searchState.selectedResultID = $0 }
                    ),
                    hoverSelectionEnabled: searchState.hoverSelectionEnabled,
                    highlightColors: searchState.highlightColors,
                    onClose: onCloseSearch,
                    onSelect: onSelectResult,
                    onDelete: onDeleteResult,
                    onTogglePin: onTogglePinResult,
                    onHoverResultID: onHoverSearchResultID
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
    @Environment(\.colorScheme) private var colorScheme
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
                        .fill(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12))
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
                .fill(chromeMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(chromeBorderColor, lineWidth: 1)
                )
        )
    }

    private var chromeMaterial: Material {
        colorScheme == .dark ? .thinMaterial : .regularMaterial
    }

    private var chromeBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }
}

private struct InNoteFindBarView: View {
    @Environment(\.colorScheme) private var colorScheme
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
                .fill(chromeMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(chromeBorderColor, lineWidth: 1)
                )
        )
        .onAppear {
            scheduleOnMain {
                isFocused = true
            }
        }
    }

    private var matchLabel: String {
        guard totalCount > 0 else { return "0" }
        return "\(currentIndex)/\(totalCount)"
    }

    private var chromeMaterial: Material {
        colorScheme == .dark ? .thinMaterial : .regularMaterial
    }

    private var chromeBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }
}

private struct SearchOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var query: String
    let results: [NoteSearchResult]
    @Binding var selectedResultID: NoteSearchResult.ID?
    let hoverSelectionEnabled: Bool
    let highlightColors: [Color]
    let onClose: () -> Void
    let onSelect: (NoteSearchResult) -> Void
    let onDelete: (NoteSearchResult) -> Void
    let onTogglePin: (NoteSearchResult) -> Void
    let onHoverResultID: (NoteSearchResult.ID?) -> Void
    @FocusState private var searchFocused: Bool
    @State private var hoveredResultID: NoteSearchResult.ID?
    @State private var hoveredPinResultID: NoteSearchResult.ID?
    @State private var hoveredTrashResultID: NoteSearchResult.ID?
    @State private var suppressNextSelectionAutoScroll = false

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
                    .fill(chromeMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(chromeBorderColor, lineWidth: 1)
                    )
            )

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            resultRow(result: result)
                                .id(result.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .onAppear {
                    scrollSelectionIntoView(using: proxy)
                }
                .onChange(of: selectedResultID) { _, _ in
                    if suppressNextSelectionAutoScroll {
                        suppressNextSelectionAutoScroll = false
                        return
                    }
                    scrollSelectionIntoView(using: proxy)
                }
                .onChange(of: results.map(\.id)) { _, _ in
                    scrollSelectionIntoView(using: proxy)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(chromeMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(chromeBorderColor, lineWidth: 1)
                )
        )
        .onAppear {
            scheduleOnMain {
                searchFocused = true
            }
        }
    }

    private func scrollSelectionIntoView(using proxy: ScrollViewProxy) {
        guard let selectedResultID,
              results.contains(where: { $0.id == selectedResultID }) else { return }
        scheduleOnMain {
            proxy.scrollTo(selectedResultID, anchor: .center)
        }
    }

    private func resultRow(result: NoteSearchResult) -> some View {
        let effectiveHoveredResultID = hoverSelectionEnabled ? hoveredResultID : nil
        let isActive = result.id == selectedResultID || result.id == effectiveHoveredResultID
        let showsActions = result.id == effectiveHoveredResultID

        return HStack(alignment: .center, spacing: 8) {
            TitlePatternIcon(title: result.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !result.snippet.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(result.matchCount >= 10 ? "∞" : "\(result.matchCount)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.leading, result.matchCount >= 10 ? 0 : 1.5)
                            .frame(width: 14, alignment: .leading)
                        Text(highlightedSnippet(line: result.snippet, query: query))
                            .font(.system(size: 12))
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButtons(for: result, visible: showsActions)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground(isActive: isActive))
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(result)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
                hoveredResultID = result.id
                if hoverSelectionEnabled {
                    suppressNextSelectionAutoScroll = true
                    selectedResultID = result.id
                    onHoverResultID(result.id)
                }
            case .ended:
                if hoveredResultID == result.id {
                    hoveredResultID = nil
                    hoveredPinResultID = nil
                    hoveredTrashResultID = nil
                    onHoverResultID(nil)
                }
                NSCursor.arrow.set()
            }
        }
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isActive ? AnyShapeStyle(chromeMaterial) : AnyShapeStyle(.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isActive ? activeRowBorderColor : .clear, lineWidth: 1)
            )
    }

    private var chromeMaterial: Material {
        colorScheme == .dark ? .thinMaterial : .regularMaterial
    }

    private var chromeBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }

    private var activeRowBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.18)
    }

    private func actionButtons(for result: NoteSearchResult, visible: Bool) -> some View {
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
                                    .fill(hoveredPinResultID == result.id ? (colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.10)) : .clear)
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .onHover { hovering in
                        hoveredPinResultID = hovering ? result.id : nil
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
                                        .fill(hoveredTrashResultID == result.id ? (colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.10)) : .clear)
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .onHover { hovering in
                            hoveredTrashResultID = hovering ? result.id : nil
                        }
                        .buttonStyle(.plain)
                        .help("Delete note (Cmd+D)")
                    }
                }
            }
        }
        .frame(width: 40, height: 16, alignment: .trailing)
    }

    private func highlightedSnippet(line: String, query: String) -> AttributedString {
        let excerpt = snippetExcerpt(line: line, query: query)
        let snippet = excerpt.text
        var attributed = AttributedString(snippet)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return attributed
        }

        let lowerLine = snippet.lowercased()
        let lowerQuery = trimmedQuery.lowercased()
        let highlightStart = lowerLine.index(lowerLine.startIndex, offsetBy: excerpt.highlightableLowerBoundOffset)
        let highlightEnd = lowerLine.index(lowerLine.startIndex, offsetBy: excerpt.highlightableUpperBoundOffset)
        var searchStart = highlightStart
        var highlightedAny = false

        while searchStart < highlightEnd,
              let foundRange = lowerLine.range(of: lowerQuery, options: [], range: searchStart..<highlightEnd) {
            if let lower = AttributedString.Index(foundRange.lowerBound, within: attributed),
               let upper = AttributedString.Index(foundRange.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .primary
                attributed[lower..<upper].backgroundColor = .init(Color(nsColor: .selectedTextBackgroundColor))
                highlightedAny = true
            }
            searchStart = foundRange.upperBound
        }

        if !highlightedAny,
           let fallbackLowerOffset = excerpt.firstMatchLowerBoundOffset,
           let fallbackUpperOffset = excerpt.firstMatchUpperBoundOffset,
           fallbackUpperOffset > fallbackLowerOffset {
            let lower = lowerLine.index(lowerLine.startIndex, offsetBy: fallbackLowerOffset)
            let upper = lowerLine.index(lowerLine.startIndex, offsetBy: fallbackUpperOffset)
            if let attributedLower = AttributedString.Index(lower, within: attributed),
               let attributedUpper = AttributedString.Index(upper, within: attributed) {
                attributed[attributedLower..<attributedUpper].foregroundColor = .primary
                attributed[attributedLower..<attributedUpper].backgroundColor = .init(Color(nsColor: .selectedTextBackgroundColor))
            }
        }
        return attributed
    }

    private func snippetExcerpt(line: String, query: String, maxLength: Int = 64, leftContext: Int = 6) -> SnippetExcerpt {
        let trimmedLine = line.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        guard trimmedLine.count > maxLength else {
            return SnippetExcerpt(
                text: trimmedLine,
                highlightableLowerBoundOffset: 0,
                highlightableUpperBoundOffset: trimmedLine.count,
                firstMatchLowerBoundOffset: nil,
                firstMatchUpperBoundOffset: nil
            )
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let matchRange = trimmedLine.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else {
            let end = trimmedLine.index(trimmedLine.startIndex, offsetBy: max(0, maxLength - 3), limitedBy: trimmedLine.endIndex) ?? trimmedLine.endIndex
            let text = String(trimmedLine[..<end]) + "..."
            return SnippetExcerpt(
                text: text,
                highlightableLowerBoundOffset: 0,
                highlightableUpperBoundOffset: max(0, text.count - 3),
                firstMatchLowerBoundOffset: nil,
                firstMatchUpperBoundOffset: nil
            )
        }

        let lineLength = trimmedLine.count
        let matchStartOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: matchRange.lowerBound)
        let matchEndOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: matchRange.upperBound)

        // Start with the strictest budget (both-side ellipses) and then expand if one side hits an edge.
        let minimumCoreBudget = max(1, maxLength - 6)
        let maxStartForCore = max(0, lineLength - minimumCoreBudget)
        var startOffset = min(max(0, matchStartOffset - leftContext), maxStartForCore)
        var endOffset = min(lineLength, startOffset + minimumCoreBudget)

        if matchEndOffset > endOffset {
            endOffset = min(lineLength, matchEndOffset)
            startOffset = max(0, endOffset - minimumCoreBudget)
        }

        var hasLeftTrim = startOffset > 0
        var hasRightTrim = endOffset < lineLength
        var coreBudget = maxLength - (hasLeftTrim ? 3 : 0) - (hasRightTrim ? 3 : 0)
        coreBudget = max(1, coreBudget)

        var currentLength = endOffset - startOffset
        if currentLength < coreBudget {
            var remaining = coreBudget - currentLength
            let rightRoom = lineLength - endOffset
            let addRight = min(remaining, rightRoom)
            endOffset += addRight
            remaining -= addRight

            if remaining > 0 {
                let addLeft = min(remaining, startOffset)
                startOffset -= addLeft
            }

            hasLeftTrim = startOffset > 0
            hasRightTrim = endOffset < lineLength
            coreBudget = maxLength - (hasLeftTrim ? 3 : 0) - (hasRightTrim ? 3 : 0)
            coreBudget = max(1, coreBudget)
            currentLength = endOffset - startOffset
            if currentLength < coreBudget {
                let trailingFill = min(coreBudget - currentLength, lineLength - endOffset)
                endOffset += trailingFill
            }
        }

        let start = trimmedLine.index(trimmedLine.startIndex, offsetBy: startOffset)
        let end = trimmedLine.index(trimmedLine.startIndex, offsetBy: endOffset)
        var excerpt = String(trimmedLine[start..<end])
        if hasLeftTrim {
            excerpt = "..." + excerpt
        }
        if hasRightTrim {
            excerpt += "..."
        }
        let highlightStart = hasLeftTrim ? 3 : 0
        let highlightEnd = excerpt.count - (hasRightTrim ? 3 : 0)
        let visibleMatchStart = max(matchStartOffset, startOffset)
        let visibleMatchEnd = min(matchEndOffset, endOffset)
        let firstMatchLowerBoundOffset: Int? = visibleMatchStart < visibleMatchEnd ? highlightStart + (visibleMatchStart - startOffset) : nil
        let firstMatchUpperBoundOffset: Int? = visibleMatchStart < visibleMatchEnd ? highlightStart + (visibleMatchEnd - startOffset) : nil
        return SnippetExcerpt(
            text: excerpt,
            highlightableLowerBoundOffset: highlightStart,
            highlightableUpperBoundOffset: highlightEnd,
            firstMatchLowerBoundOffset: firstMatchLowerBoundOffset,
            firstMatchUpperBoundOffset: firstMatchUpperBoundOffset
        )
    }
}

private struct SnippetExcerpt {
    let text: String
    let highlightableLowerBoundOffset: Int
    let highlightableUpperBoundOffset: Int
    let firstMatchLowerBoundOffset: Int?
    let firstMatchUpperBoundOffset: Int?
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
    let writingModeEnabled: Bool
    @ObservedObject var editorBridge: EditorBridge
    @ObservedObject var store: NotesStore
    let onUserEdit: () -> Void
    private static let editorParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            writingModeEnabled: writingModeEnabled,
            store: store,
            onUserEdit: onUserEdit,
            applyParagraphStyle: { textView, isWritingModeEnabled in
                applyParagraphStyle(in: textView, writingModeEnabled: isWritingModeEnabled)
            }
        )
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
        applyParagraphStyle(in: textView, writingModeEnabled: writingModeEnabled)
        Coordinator.applyCodeStyling(in: textView)
        textView.refreshLinkSpans()
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
        context.coordinator.writingModeEnabled = writingModeEnabled
        if textView.string != text {
            textView.string = text
            applyParagraphStyle(in: textView, writingModeEnabled: writingModeEnabled)
            Coordinator.applyCodeStyling(in: textView)
            if let linkAwareTextView = textView as? LineDeleteOnCutTextView {
                linkAwareTextView.refreshLinkSpans()
            }

            if let saved = store.pendingCursorRestore {
                store.pendingCursorRestore = nil
                let textLength = (textView.string as NSString).length
                let clampedLocation = min(saved.location, textLength)
                let clampedLength = min(saved.length, textLength - clampedLocation)
                let range = NSRange(location: clampedLocation, length: clampedLength)
                textView.setSelectedRange(range)
                scheduleOnMain {
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        if context.coordinator.lastAppliedWritingModeEnabled != writingModeEnabled {
            context.coordinator.lastAppliedWritingModeEnabled = writingModeEnabled
            applyParagraphStyle(in: textView, writingModeEnabled: writingModeEnabled)
            Coordinator.applyCodeStyling(in: textView)
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
            textView.setNeedsDisplay(textView.bounds)
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            scheduleOnMain {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var writingModeEnabled: Bool
        let store: NotesStore
        let onUserEdit: () -> Void
        let applyParagraphStyle: (NSTextView, Bool) -> Void
        var lastFocusToken: Int = -1
        var lastAppliedWritingModeEnabled: Bool?

        init(
            text: Binding<String>,
            writingModeEnabled: Bool,
            store: NotesStore,
            onUserEdit: @escaping () -> Void,
            applyParagraphStyle: @escaping (NSTextView, Bool) -> Void
        ) {
            _text = text
            self.writingModeEnabled = writingModeEnabled
            self.store = store
            self.onUserEdit = onUserEdit
            self.applyParagraphStyle = applyParagraphStyle
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            applyParagraphStyle(textView, writingModeEnabled)
            Self.applyCodeStyling(in: textView)
            if let linkAwareTextView = textView as? LineDeleteOnCutTextView {
                linkAwareTextView.refreshLinkSpans()
            }
            text = textView.string
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
            textView.setNeedsDisplay(textView.bounds)
            onUserEdit()
        }

        @MainActor static func applyCodeStyling(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let nsText = textView.string as NSString
            let codeSpans = CodeStyling.detectSpans(in: nsText)
            let linkSpans = LinkShrink.detectLinks(in: nsText, excluding: codeSpans)
            CodeStyling.applyAttributes(to: textStorage, spans: codeSpans, linkSpans: linkSpans)
            if let layoutManager = textView.layoutManager as? ListBulletLayoutManager {
                layoutManager.codeSpans = codeSpans
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            if let linkAwareTextView = textView as? LineDeleteOnCutTextView {
                linkAwareTextView.refreshSelectionLinkState()
            }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
            textView.setNeedsDisplay(textView.bounds)

            let range = textView.selectedRange()
            store.saveCursorPosition(location: range.location, length: range.length, for: store.currentNoteFileURL)
        }
    }

    private static let indentUnitWidth: CGFloat = {
        (SmartListEditing.indentUnit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
    }()

    private static let listMarkerWidth: CGFloat = {
        (SmartListEditing.listMarker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
    }()

    private func applyParagraphStyle(in textView: NSTextView, writingModeEnabled: Bool) {
        guard let textStorage = textView.textStorage else { return }
        let nsText = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if writingModeEnabled {
            textStorage.beginEditing()
            if fullRange.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: Self.editorParagraphStyle, range: fullRange)
            }
            textStorage.endEditing()
            textView.typingAttributes[.paragraphStyle] = Self.editorParagraphStyle
            return
        }

        guard fullRange.length > 0 else {
            textView.typingAttributes[.paragraphStyle] = Self.editorParagraphStyle
            return
        }

        textStorage.beginEditing()
        var location = 0
        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = Self.contentRangeOfLine(in: nsText, lineRange: lineRange)
            let lineContent = contentRange.length > 0 ? nsText.substring(with: contentRange) : ""
            let wrappingIndent = Self.wrappingHeadIndent(in: lineContent)
            textStorage.addAttribute(.paragraphStyle, value: Self.paragraphStyle(forHeadIndent: wrappingIndent), range: lineRange)
            location = NSMaxRange(lineRange)
        }
        textStorage.endEditing()

        let selectedLocation = min(textView.selectedRange().location, nsText.length)
        let currentLineRange = nsText.lineRange(for: NSRange(location: selectedLocation, length: 0))
        let currentContentRange = Self.contentRangeOfLine(in: nsText, lineRange: currentLineRange)
        let currentLine = currentContentRange.length > 0 ? nsText.substring(with: currentContentRange) : ""
        let currentIndent = Self.wrappingHeadIndent(in: currentLine)
        textView.typingAttributes[.paragraphStyle] = Self.paragraphStyle(forHeadIndent: currentIndent)
    }

    private static func wrappingHeadIndent(in line: String) -> CGFloat {
        let (indent, hasMarker, _) = SmartListEditing.lineComponents(line)
        let depth = indent / SmartListEditing.indentUnit.count
        let base = CGFloat(depth) * indentUnitWidth
        return hasMarker ? base + listMarkerWidth : base
    }

    private static func paragraphStyle(forHeadIndent headIndent: CGFloat) -> NSParagraphStyle {
        guard headIndent > 0 else { return editorParagraphStyle }
        let style = editorParagraphStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = headIndent
        return style
    }

    private static func contentRangeOfLine(in text: NSString, lineRange: NSRange) -> NSRange {
        var length = lineRange.length
        while length > 0 {
            let char = text.character(at: lineRange.location + length - 1)
            if char == 10 || char == 13 {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: length)
    }
}

private final class LineDeleteOnCutTextView: NSTextView {
    private(set) var linkSpans: [ShrunkLinkSpan] = []
    nonisolated(unsafe) private(set) var linkSpansForDisplay: [ShrunkLinkSpan] = []
    nonisolated(unsafe) private(set) var activeLinkRangesForDisplay: [NSRange] = []
    private var linkTrackingArea: NSTrackingArea?
    private var rememberedLinkRangeForVerticalNavigation: NSRange?
    private var expandRememberedLinkForCurrentVerticalMove = false
    var searchOverlayPresented = false {
        didSet {
            guard searchOverlayPresented != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
    }

    func refreshLinkSpans() {
        let codeSpans = CodeStyling.detectSpans(in: string as NSString)
        linkSpans = LinkShrink.detectLinks(in: string as NSString, excluding: codeSpans)
        if let remembered = rememberedLinkRangeForVerticalNavigation,
           LinkShrink.span(containing: remembered.location, in: linkSpans) == nil {
            rememberedLinkRangeForVerticalNavigation = nil
        }
        syncLinkDisplayState()
        invalidateShrinkDisplay()
        updateCursorForCurrentLocation()
    }

    func refreshSelectionLinkState() {
        let currentSelection = selectedRange()
        if currentSelection.length == 0,
           let currentActiveRange = LinkShrink.activeLinkRange(in: linkSpans, selection: currentSelection) {
            rememberedLinkRangeForVerticalNavigation = currentActiveRange
        }
        expandRememberedLinkForCurrentVerticalMove = false
        syncLinkDisplayState()
        updateCursorForCurrentLocation()
    }

    func activeLinkRangesForSelection() -> [NSRange] {
        let currentSelection = selectedRange()
        if currentSelection.length > 0 {
            return LinkShrink.activeLinkRanges(in: linkSpans, selection: currentSelection)
        }
        if let active = LinkShrink.activeLinkRange(in: linkSpans, selection: selectedRange()) {
            return [active]
        }
        guard expandRememberedLinkForCurrentVerticalMove else {
            return []
        }
        guard let rememberedLinkRangeForVerticalNavigation else {
            return []
        }
        return [rememberedLinkRangeForVerticalNavigation]
    }

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

        let isVerticalArrow = (event.keyCode == 125 || event.keyCode == 126)
            && !modifiers.contains(.command)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
        let isHorizontalArrow = (event.keyCode == 123 || event.keyCode == 124)
            && !modifiers.contains(.command)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)

        if isHorizontalArrow {
            rememberedLinkRangeForVerticalNavigation = nil
            expandRememberedLinkForCurrentVerticalMove = false
        } else if isVerticalArrow {
            if let active = LinkShrink.activeLinkRange(in: linkSpans, selection: selectedRange()) {
                rememberedLinkRangeForVerticalNavigation = active
            }
            expandRememberedLinkForCurrentVerticalMove = rememberedLinkRangeForVerticalNavigation != nil
            syncLinkDisplayState()
        } else {
            expandRememberedLinkForCurrentVerticalMove = false
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

        // Backtick with selection: toggle code span
        if event.characters == "`", selectedRange().length > 0 {
            let sel = selectedRange()
            let nsText = string as NSString
            let selected = nsText.substring(with: sel)
            if selected.hasPrefix("`"), selected.hasSuffix("`"), selected.count >= 2 {
                // Unwrap: remove surrounding backticks
                let inner = String(selected.dropFirst().dropLast())
                if shouldChangeText(in: sel, replacementString: inner) {
                    textStorage?.replaceCharacters(in: sel, with: inner)
                    didChangeText()
                    setSelectedRange(NSRange(location: sel.location, length: inner.count))
                }
            } else {
                // Wrap in backticks
                let wrapped = "`\(selected)`"
                if shouldChangeText(in: sel, replacementString: wrapped) {
                    textStorage?.replaceCharacters(in: sel, with: wrapped)
                    didChangeText()
                    setSelectedRange(NSRange(location: sel.location, length: wrapped.count))
                }
            }
            return
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
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: selection.location)
        guard shouldChangeText(in: range, replacementString: "") else {
            return
        }

        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(range.location, (string as NSString).length), length: 0))
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

    // MARK: - Indent-aware cursor navigation

    /// Returns the character index just past the normalized indent on the line containing `location`.
    private func indentEndOfLine(at location: Int) -> Int {
        let nsText = string as NSString
        guard nsText.length > 0 else { return 0 }
        let safeLoc: Int
        if location >= nsText.length {
            let lastChar = nsText.character(at: nsText.length - 1)
            if lastChar == 10 || lastChar == 13 { return location }
            safeLoc = nsText.length - 1
        } else {
            safeLoc = location
        }
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        var offset = 0
        while offset < lineRange.length {
            let pos = lineRange.location + offset
            guard pos < nsText.length else { break }
            let ch = nsText.character(at: pos)
            guard ch == 0x20 else { break } // space
            offset += 1
        }
        let indentSize = SmartListEditing.indentUnit.count
        let normalized = (offset / indentSize) * indentSize
        var end = lineRange.location + normalized
        // Check for list marker "- " after indent spaces
        if end + 1 < nsText.length,
           nsText.character(at: end) == 0x2D, // '-'
           nsText.character(at: end + 1) == 0x20 { // ' '
            end += 2
        }
        return end
    }

    private func lineStartLocation(at location: Int) -> Int {
        let nsText = string as NSString
        guard nsText.length > 0 else { return 0 }
        if location >= nsText.length {
            let lastChar = nsText.character(at: nsText.length - 1)
            if lastChar == 10 || lastChar == 13 { return location }
            return nsText.lineRange(for: NSRange(location: nsText.length - 1, length: 0)).location
        }
        return nsText.lineRange(for: NSRange(location: location, length: 0)).location
    }

    /// Whether `location` is strictly inside the indent zone (between line start and indent end, exclusive).
    private func isInIndentZone(_ location: Int) -> Bool {
        let ls = lineStartLocation(at: location)
        let ie = indentEndOfLine(at: location)
        return ie > ls && location > ls && location < ie
    }

    private func snapCursorOutOfIndent(movingLeft: Bool) {
        let sel = selectedRange()
        guard sel.length == 0, isInIndentZone(sel.location) else { return }
        let target = movingLeft ? lineStartLocation(at: sel.location) : indentEndOfLine(at: sel.location)
        setSelectedRange(NSRange(location: target, length: 0))
    }

    private func snapSelectionOutOfIndent(before: NSRange, movingLeft: Bool) {
        let after = selectedRange()
        let afterLeft = after.location
        let afterRight = after.location + after.length
        let beforeRight = before.location + before.length

        if afterLeft != before.location, isInIndentZone(afterLeft) {
            let target = movingLeft ? lineStartLocation(at: afterLeft) : indentEndOfLine(at: afterLeft)
            setSelectedRange(NSRange(location: target, length: afterRight - target))
        } else if afterRight != beforeRight, isInIndentZone(afterRight) {
            let target = movingLeft ? lineStartLocation(at: afterRight) : indentEndOfLine(at: afterRight)
            setSelectedRange(NSRange(location: afterLeft, length: target - afterLeft))
        }
    }

    // Home key / Cmd+Left: toggle between indent end and line start
    override func moveToBeginningOfLine(_ sender: Any?) {
        let sel = selectedRange()
        let ie = indentEndOfLine(at: sel.location)
        let ls = lineStartLocation(at: sel.location)
        guard ie > ls else {
            super.moveToBeginningOfLine(sender)
            return
        }
        let target = (sel.location != ie) ? ie : ls
        setSelectedRange(NSRange(location: target, length: 0))
    }

    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let ie = indentEndOfLine(at: sel.location)
        let ls = lineStartLocation(at: sel.location)
        guard ie > ls else {
            super.moveToBeginningOfLineAndModifySelection(sender)
            return
        }
        let target = (sel.location != ie) ? ie : ls
        let right = sel.location + sel.length
        if target < right {
            setSelectedRange(NSRange(location: target, length: right - target))
        } else {
            setSelectedRange(NSRange(location: target, length: 0))
        }
    }

    // Ctrl+A
    override func moveToBeginningOfParagraph(_ sender: Any?) {
        let sel = selectedRange()
        let ie = indentEndOfLine(at: sel.location)
        let ls = lineStartLocation(at: sel.location)
        guard ie > ls else {
            super.moveToBeginningOfParagraph(sender)
            return
        }
        let target = (sel.location != ie) ? ie : ls
        setSelectedRange(NSRange(location: target, length: 0))
    }

    override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let ie = indentEndOfLine(at: sel.location)
        let ls = lineStartLocation(at: sel.location)
        guard ie > ls else {
            super.moveToBeginningOfParagraphAndModifySelection(sender)
            return
        }
        let target = (sel.location != ie) ? ie : ls
        let right = sel.location + sel.length
        if target < right {
            setSelectedRange(NSRange(location: target, length: right - target))
        } else {
            setSelectedRange(NSRange(location: target, length: 0))
        }
    }

    // Arrow keys
    override func moveLeft(_ sender: Any?) {
        super.moveLeft(sender)
        snapCursorOutOfIndent(movingLeft: true)
    }

    override func moveRight(_ sender: Any?) {
        super.moveRight(sender)
        snapCursorOutOfIndent(movingLeft: false)
    }

    override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        snapCursorOutOfIndent(movingLeft: false)
    }

    override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        snapCursorOutOfIndent(movingLeft: false)
    }

    override func moveWordLeft(_ sender: Any?) {
        super.moveWordLeft(sender)
        snapCursorOutOfIndent(movingLeft: true)
    }

    override func moveWordRight(_ sender: Any?) {
        super.moveWordRight(sender)
        snapCursorOutOfIndent(movingLeft: false)
    }

    // Arrow keys with selection
    override func moveLeftAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveLeftAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: true)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveRightAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: false)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveUpAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: false)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveDownAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: false)
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveWordLeftAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: true)
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        let before = selectedRange()
        super.moveWordRightAndModifySelection(sender)
        snapSelectionOutOfIndent(before: before, movingLeft: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateShrinkDisplay()
    }

    override func updateTrackingAreas() {
        if let linkTrackingArea {
            removeTrackingArea(linkTrackingArea)
        }
        linkTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        if let linkTrackingArea {
            addTrackingArea(linkTrackingArea)
        }
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        if searchOverlayPresented {
            discardCursorRects()
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        super.resetCursorRects()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !searchOverlayPresented else {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
        updateCursor(for: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !searchOverlayPresented else {
            NSCursor.arrow.set()
            return
        }
        super.flagsChanged(with: event)
        updateCursorForCurrentLocation(with: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        expandRememberedLinkForCurrentVerticalMove = false
        rememberedLinkRangeForVerticalNavigation = nil
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), openLinkAtMouseLocation(event) {
            return
        }
        super.mouseDown(with: event)
        // Snap cursor out of indent zone after click (not during drag selections)
        let sel = selectedRange()
        if sel.length == 0, isInIndentZone(sel.location) {
            setSelectedRange(NSRange(location: indentEndOfLine(at: sel.location), length: 0))
        }
    }

    private func applySmartListEdit(action: SmartListAction) -> Bool {
        let currentText = string
        let nsText = currentText as NSString
        if SmartListEditing.isInsideCodeFence(text: nsText, location: selectedRange().location) {
            return false
        }
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

    private func invalidateShrinkDisplay() {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
        setNeedsDisplay(bounds)
    }

    private func syncLinkDisplayState() {
        linkSpansForDisplay = linkSpans
        activeLinkRangesForDisplay = activeLinkRangesForSelection()
        if let linkLayoutManager = layoutManager as? ListBulletLayoutManager {
            linkLayoutManager.updateLinkCompression(
                spans: linkSpansForDisplay,
                activeRanges: activeLinkRangesForDisplay
            )
        }
    }

    private func openLinkAtMouseLocation(_ event: NSEvent) -> Bool {
        let pointInTextView = convert(event.locationInWindow, from: nil)
        guard let span = linkSpan(at: pointInTextView),
              let url = URL(string: span.urlString) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func linkSpan(at pointInTextView: NSPoint) -> ShrunkLinkSpan? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let containerOrigin = textContainerOrigin
        let pointInContainer = NSPoint(
            x: pointInTextView.x - containerOrigin.x,
            y: pointInTextView.y - containerOrigin.y
        )

        for span in linkSpans {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
                continue
            }
            let linkRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).insetBy(dx: -1.5, dy: -1.5)
            if linkRect.contains(pointInContainer) {
                return span
            }
        }

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: pointInContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex != NSNotFound else {
            return nil
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return LinkShrink.span(containing: charIndex, in: linkSpans)
    }

    private func updateCursor(for event: NSEvent) {
        guard !searchOverlayPresented else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let shouldShowPointer = modifiers.contains(.command) && linkSpan(at: point) != nil
        (shouldShowPointer ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    private func updateCursorForCurrentLocation(with modifiers: NSEvent.ModifierFlags? = nil) {
        guard !searchOverlayPresented else { return }
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let effectiveModifiers = modifiers?.intersection(.deviceIndependentFlagsMask) ?? NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldShowPointer = effectiveModifiers.contains(.command) && linkSpan(at: point) != nil
        (shouldShowPointer ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }
}

final class ListBulletLayoutManager: NSLayoutManager {
    private var compressedLinkRanges: [NSRange] = []
    /// Spans whose display text should be drawn in place of the compressed originals.
    private(set) var displaySpans: [ShrunkLinkSpan] = []
    var showsStructuralFormatting = true
    var codeSpans: [CodeSpan] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawCodeBackgrounds(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawShrunkLinks(forGlyphRange: glyphsToShow, at: origin)
    }

    func updateLinkCompression(spans: [ShrunkLinkSpan], activeRanges: [NSRange]) {
        guard let textStorage else {
            compressedLinkRanges = []
            displaySpans = []
            return
        }
        let fullLength = (textStorage.string as NSString).length
        clearCompressedLinkAttributes(in: textStorage, currentTextLength: fullLength)
        guard fullLength > 0 else {
            return
        }

        let baseFont = NSFont.systemFont(ofSize: 14)

        // Collect spans that need compression.
        var inactiveSpans: [ShrunkLinkSpan] = []
        for span in spans {
            guard span.range.location != NSNotFound,
                  span.range.length > 0,
                  NSMaxRange(span.range) <= fullLength else {
                continue
            }
            if intersectsAnyActiveRange(span.range, activeRanges: activeRanges) {
                continue
            }
            inactiveSpans.append(span)
        }

        // Get per-glyph advances so we can apply proportional kern.
        // Uniform kern breaks down when narrow glyphs (`.`, `/`, `i`)
        // can't absorb enough negative spacing.
        let ctFont = baseFont as CTFont

        textStorage.beginEditing()
        for span in inactiveSpans {
            let originalText = (textStorage.string as NSString).substring(with: span.range)
            let displayWidth = (span.displayText as NSString).size(withAttributes: [.font: baseFont]).width

            // Measure per-character advances via CTFont.
            let characters = Array(originalText.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count)
            var advances = [CGSize](repeating: .zero, count: characters.count)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, characters.count)

            let originalWidth = advances.reduce(CGFloat(0)) { $0 + $1.width }
            guard originalWidth > 0, characters.count > 1 else {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
                compressedLinkRanges.append(span.range)
                continue
            }

            // Proportional compression: each character's kern scales with its advance.
            // kern_i = (factor - 1) * advance_i  where factor = displayWidth / originalWidth
            let factor = displayWidth / originalWidth
            for i in 0 ..< (characters.count - 1) {
                let charKern = (factor - 1.0) * advances[i].width
                let charRange = NSRange(location: span.range.location + i, length: 1)
                textStorage.addAttribute(.kern, value: charKern, range: charRange)
            }

            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
            compressedLinkRanges.append(span.range)
        }
        textStorage.endEditing()

        displaySpans = inactiveSpans

        let fullRange = NSRange(location: 0, length: fullLength)
        invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: fullRange)
    }

    private func clearCompressedLinkAttributes(in textStorage: NSTextStorage, currentTextLength: Int) {
        textStorage.beginEditing()
        for range in compressedLinkRanges {
            guard range.location != NSNotFound, range.location < currentTextLength else {
                continue
            }
            let safeLength = min(range.length, currentTextLength - range.location)
            guard safeLength > 0 else { continue }
            let safeRange = NSRange(location: range.location, length: safeLength)
            textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: safeRange)
            textStorage.removeAttribute(.kern, range: safeRange)
        }
        textStorage.endEditing()
        compressedLinkRanges.removeAll(keepingCapacity: true)
        displaySpans.removeAll(keepingCapacity: true)
    }

    /// The expected line fragment height for a non-terminal line. The last line
    /// of the document gets a shorter fragment rect from NSLayoutManager because
    /// there is no following newline. We measure the first line of a two-line
    /// string to capture the full height including lineSpacing.
    private static let referenceLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 14)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        let storage = NSTextStorage(string: "X\nX", attributes: [.font: font, .paragraphStyle: style])
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    }()

    private func drawCodeBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !codeSpans.isEmpty else { return }
        guard let textContainer = textContainers.first else { return }
        let bgColor = CodeStyling.codeBackgroundColor
        let minLineHeight = Self.referenceLineHeight
        let vInset: CGFloat = 1  // 1pt top + 1pt bottom = 2pt gap between adjacent lines

        for span in codeSpans {
            let charRange: NSRange
            if span.kind == .block {
                charRange = span.fullRange
            } else {
                charRange = span.contentRange
            }
            guard charRange.length > 0 else { continue }
            let spanGlyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            guard spanGlyphRange.location != NSNotFound,
                  NSIntersectionRange(spanGlyphRange, glyphsToShow).length > 0 else {
                continue
            }

            if span.kind == .block {
                // Draw one continuous rect covering all line fragments in the block.
                var unionRect = NSRect.zero
                var glyphIndex = spanGlyphRange.location
                let glyphEnd = NSMaxRange(spanGlyphRange)
                while glyphIndex < glyphEnd {
                    var fragmentRange = NSRange(location: 0, length: 0)
                    let lineRect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentRange)
                    guard fragmentRange.length > 0 else {
                        glyphIndex += 1
                        continue
                    }
                    let height = max(lineRect.height, minLineHeight)
                    let fragRect = NSRect(
                        x: origin.x + lineRect.minX,
                        y: origin.y + lineRect.minY,
                        width: lineRect.width,
                        height: height
                    )
                    unionRect = unionRect == .zero ? fragRect : unionRect.union(fragRect)
                    glyphIndex = NSMaxRange(fragmentRange)
                }
                if unionRect != .zero {
                    let rect = NSRect(
                        x: unionRect.minX,
                        y: unionRect.minY + vInset,
                        width: unionRect.width,
                        height: unionRect.height - vInset * 2
                    )
                    bgColor.setFill()
                    rect.fill()
                }
            } else {
                // Inline: draw a rect bounded by the glyph positions but using
                // the full line fragment height for consistent vertical sizing.
                let boundingRect = boundingRect(forGlyphRange: spanGlyphRange, in: textContainer)
                let firstGlyph = spanGlyphRange.location
                let lineRect = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                let height = max(lineRect.height, minLineHeight)
                let rect = NSRect(
                    x: origin.x + boundingRect.minX,
                    y: origin.y + lineRect.minY + vInset,
                    width: boundingRect.width,
                    height: height - vInset * 2
                )
                bgColor.setFill()
                rect.fill()
            }
        }
    }

    private func drawShrunkLinks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !displaySpans.isEmpty else { return }
        guard let textContainer = textContainers.first else { return }
        let spans = displaySpans
        let font = NSFont.systemFont(ofSize: 14)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.linkColor
        ]

        for span in spans {
            let glyphRange = glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            if glyphRange.location == NSNotFound || NSIntersectionRange(glyphRange, glyphsToShow).length == 0 {
                continue
            }

            let glyphIndex = glyphRange.location
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = location(forGlyphAt: glyphIndex)
            let baselineY = origin.y + lineRect.minY + glyphLocation.y
            let drawPoint = NSPoint(
                x: origin.x + lineRect.minX + glyphLocation.x,
                y: baselineY - font.ascender
            )

            // Keep replacement text inside the same visual line to avoid bleeding into neighbors.
            let clipRect = NSRect(
                x: origin.x + lineRect.minX,
                y: origin.y + lineRect.minY,
                width: lineRect.width,
                height: lineRect.height
            )

            // Stretch display text with tiny kern to fill residual gap from
            // compression rounding (~0-5pt spread across all display chars).
            var drawAttributes = baseAttributes
            let compressedWidth = boundingRect(forGlyphRange: glyphRange, in: textContainer).width
            let displayWidth = (span.displayText as NSString).size(withAttributes: baseAttributes).width
            let displayCharCount = span.displayText.count
            if displayCharCount > 1, compressedWidth > displayWidth {
                let fillKern = (compressedWidth - displayWidth) / CGFloat(displayCharCount - 1)
                drawAttributes[.kern] = fillKern
            }

            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: clipRect).addClip()
            (span.displayText as NSString).draw(at: drawPoint, withAttributes: drawAttributes)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    private func inactiveSpansForDisplay(spans: [ShrunkLinkSpan], activeRanges: [NSRange]) -> [ShrunkLinkSpan] {
        guard !activeRanges.isEmpty else {
            return spans
        }
        return spans.filter { !intersectsAnyActiveRange($0.range, activeRanges: activeRanges) }
    }

    private func intersectsAnyActiveRange(_ range: NSRange, activeRanges: [NSRange]) -> Bool {
        activeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private var primaryTextView: NSTextView? {
        textContainers.compactMap(\.textView).first
    }
}
