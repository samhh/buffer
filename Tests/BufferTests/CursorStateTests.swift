import XCTest
@testable import Buffer

final class CursorStateTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSaveAndLoadCursorPositionRoundTrip() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "hello world"
        let noteURL = store.currentNoteFileURL

        store.saveCursorPosition(location: 5, length: 3, for: noteURL)
        let loaded = store.loadCursorPosition(for: noteURL)

        XCTAssertEqual(loaded, NSRange(location: 5, length: 3))
    }

    func testLoadCursorPositionReturnsNilWhenNotSet() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "hello"
        let noteURL = store.currentNoteFileURL

        XCTAssertNil(store.loadCursorPosition(for: noteURL))
    }

    func testLoadCursorPositionReturnsNilForMissingFile() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)
        let bogus = directory.appendingPathComponent("nonexistent.txt")

        XCTAssertNil(store.loadCursorPosition(for: bogus))
    }

    func testSaveCursorPositionZeroLengthSelection() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "some text"
        let noteURL = store.currentNoteFileURL

        store.saveCursorPosition(location: 4, length: 0, for: noteURL)
        let loaded = store.loadCursorPosition(for: noteURL)

        XCTAssertEqual(loaded, NSRange(location: 4, length: 0))
    }

    func testOpenNoteSetsPendingCursorRestore() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "note A"
        let noteA = store.currentNoteFileURL
        store.saveCursorPosition(location: 3, length: 0, for: noteA)

        store.createNewNote()
        store.text = "note B"

        store.openNote(at: noteA)
        XCTAssertEqual(store.pendingCursorRestore, NSRange(location: 3, length: 0))
    }

    func testOpenNoteWithNoCursorSetsPendingToNil() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "note A"
        let noteA = store.currentNoteFileURL

        store.createNewNote()
        store.text = "note B"

        store.openNote(at: noteA)
        XCTAssertNil(store.pendingCursorRestore)
    }

    func testOpenNoteSavesCurrentCursorBeforeSwitching() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "note A"
        let noteA = store.currentNoteFileURL

        store.createNewNote()
        store.text = "note B"
        let noteB = store.currentNoteFileURL

        store.cursorStateProvider = { NSRange(location: 2, length: 1) }
        store.openNote(at: noteA)

        let savedForB = store.loadCursorPosition(for: noteB)
        XCTAssertEqual(savedForB, NSRange(location: 2, length: 1))
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
