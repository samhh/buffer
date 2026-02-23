import XCTest
import Darwin
@testable import Buffer

final class NotesStorePinningTests: XCTestCase {
    private let fileManager = FileManager.default

    func testTogglePinUpdatesSearchOrderingAndPinnedFlag() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.txt")
        try "older".write(to: older, atomically: true, encoding: .utf8)
        try "newer".write(to: newer, atomically: true, encoding: .utf8)
        try setModifiedDate(Date(timeIntervalSinceNow: -120), for: older)
        try setModifiedDate(Date(timeIntervalSinceNow: -60), for: newer)

        let initial = store.searchNotes(query: "")
        XCTAssertEqual(canonical(initial.first?.fileURL), canonical(newer))
        XCTAssertFalse(initial.contains(where: \.isPinned))

        _ = store.togglePinned(at: older)
        let updated = store.searchNotes(query: "")

        XCTAssertEqual(canonical(updated.first?.fileURL), canonical(older))
        XCTAssertTrue(updated.first?.isPinned ?? false)
        XCTAssertFalse(updated.dropFirst().contains(where: \.isPinned))
    }

    func testPinnedNoteRemainsPinnedAfterAtomicSave() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "alpha"
        guard let noteURL = store.searchNotes(query: "").first?.fileURL else {
            XCTFail("Expected a saved note")
            return
        }

        _ = store.togglePinned(at: noteURL)
        XCTAssertTrue(store.isPinned(noteURL))

        store.text = "alpha updated"

        XCTAssertTrue(store.isPinned(noteURL))
        let refreshed = store.searchNotes(query: "").first(where: { canonical($0.fileURL) == canonical(noteURL) })
        XCTAssertTrue(refreshed?.isPinned ?? false)
    }

    func testUndoDeleteRestoresPinnedState() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "pinned note"
        guard let noteURL = store.searchNotes(query: "").first?.fileURL else {
            XCTFail("Expected a saved note")
            return
        }
        _ = store.togglePinned(at: noteURL)

        _ = store.deleteNote(at: noteURL)
        XCTAssertFalse(fileManager.fileExists(atPath: noteURL.path))

        _ = store.undoLastDeletedNote()
        XCTAssertTrue(fileManager.fileExists(atPath: noteURL.path))
        XCTAssertTrue(store.isPinned(noteURL))
    }

    func testUndoDeleteRestoresUnpinnedState() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)

        store.text = "plain note"
        guard let noteURL = store.searchNotes(query: "").first?.fileURL else {
            XCTFail("Expected a saved note")
            return
        }

        _ = store.deleteNote(at: noteURL)
        _ = store.undoLastDeletedNote()

        XCTAssertTrue(fileManager.fileExists(atPath: noteURL.path))
        XCTAssertFalse(store.isPinned(noteURL))
    }

    func testInvalidPinnedAttributeIsTreatedAsUnpinned() throws {
        let directory = try makeTempDirectory()
        let store = NotesStore(notesDirectoryURL: directory)
        let noteURL = directory.appendingPathComponent("invalid.txt")
        try "invalid".write(to: noteURL, atomically: true, encoding: .utf8)

        let invalid = "not-pinned".data(using: .utf8) ?? Data()
        let setResult = noteURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return invalid.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return -1
                }
                return setxattr(path, "com.buffer.pinned", baseAddress, bytes.count, 0, 0)
            }
        }
        XCTAssertEqual(setResult, 0)

        let result = store.searchNotes(query: "").first(where: { canonical($0.fileURL) == canonical(noteURL) })
        XCTAssertFalse(result?.isPinned ?? true)
        XCTAssertFalse(store.isPinned(noteURL))
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setModifiedDate(_ date: Date, for fileURL: URL) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    private func canonical(_ fileURL: URL?) -> URL? {
        fileURL?.resolvingSymlinksInPath().standardizedFileURL
    }
}
