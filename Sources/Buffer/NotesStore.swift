import Foundation
import Darwin

struct NoteSearchResult: Identifiable {
    let id: URL
    let fileURL: URL
    let title: String
    let snippet: String
    let matchCount: Int
    let modifiedAt: Date
    let isPinned: Bool
}

struct DeletedNote {
    let fileURL: URL
    let contents: String
    let wasPinned: Bool
}

struct DeletedNoteToast: Identifiable {
    let id = UUID()
    let deleted: DeletedNote
}

final class NotesStore: ObservableObject {
    private static let pinnedXAttrName = "com.buffer.pinned"
    private static let pinnedXAttrValue = "1".data(using: .utf8) ?? Data([49])
    private static let cursorXAttrName = "com.buffer.cursorPosition"

    @Published var text: String = "" {
        didSet {
            save()
        }
    }
    @Published var deletedNoteToast: DeletedNoteToast?
    @Published var pendingCursorRestore: NSRange?

    var cursorStateProvider: (() -> NSRange)?

    private(set) var lastDeletedNote: DeletedNote?
    var currentNoteFileURL: URL { currentNoteURL }

    private let fileManager: FileManager
    private let notesDirectoryURL: URL
    private var currentNoteURL: URL
    private var lastSavedCursor: NSRange?

    init(fileManager: FileManager = .default, notesDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let notesDirectoryURL {
            self.notesDirectoryURL = notesDirectoryURL
        } else {
            let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.notesDirectoryURL = appSupportDir.appendingPathComponent("Buffer", isDirectory: true)
        }
        currentNoteURL = self.notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)

        do {
            try fileManager.createDirectory(at: self.notesDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to create application support directory: \(error)")
        }

        migrateLegacySingleNoteIfNeeded()
        load()
    }

    func createNewNote() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        deleteCurrentNoteFileIfEmpty()
        currentNoteURL = notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)
        text = ""
    }

    private func load() {
        guard let latestURL = latestNoteFileURL() else {
            createNewNote()
            return
        }

        currentNoteURL = latestURL

        guard let data = try? Data(contentsOf: latestURL),
              let saved = String(data: data, encoding: .utf8) else {
            return
        }

        text = saved
    }

    private func save() {
        let wasPinned = isPinned(fileURL: currentNoteURL)
        let cursor = lastSavedCursor
        do {
            try text.data(using: .utf8)?.write(to: currentNoteURL, options: .atomic)
            if wasPinned {
                _ = setPinned(true, for: currentNoteURL)
            }
            if let cursor {
                saveCursorPosition(location: cursor.location, length: cursor.length, for: currentNoteURL)
            }
        } catch {
            print("Failed to save notes: \(error)")
        }
    }

    func searchNotes(query: String) -> [NoteSearchResult] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteFiles = urls.filter { $0.pathExtension == "txt" && $0.lastPathComponent != "note.txt" }

        var results: [NoteSearchResult] = []
        for fileURL in noteFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = contents.components(separatedBy: .newlines)
            let modifiedAt = (try? fileURL.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let pinned = isPinned(fileURL: fileURL)

            if normalizedQuery.isEmpty {
                let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Untitled"
                results.append(
                    NoteSearchResult(
                        id: fileURL,
                        fileURL: fileURL,
                        title: firstLine,
                        snippet: "",
                        matchCount: 0,
                        modifiedAt: modifiedAt,
                        isPinned: pinned
                    )
                )
                continue
            }

            var firstMatchLine: String?
            var matchCount = 0
            for line in lines {
                let occurrences = line.caseInsensitiveOccurrences(of: normalizedQuery)
                guard occurrences > 0 else { continue }
                if firstMatchLine == nil {
                    firstMatchLine = line
                }
                matchCount += occurrences
                if matchCount >= 10 {
                    matchCount = 10
                    break
                }
            }

            guard let matchLine = firstMatchLine else {
                continue
            }

            let title = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? fileURL.deletingPathExtension().lastPathComponent
            results.append(
                NoteSearchResult(
                    id: fileURL,
                    fileURL: fileURL,
                    title: title,
                    snippet: matchLine,
                    matchCount: matchCount,
                    modifiedAt: modifiedAt,
                    isPinned: pinned
                )
            )
        }

        let isSearching = !normalizedQuery.isEmpty
        return results.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if isSearching, lhs.matchCount != rhs.matchCount {
                return lhs.matchCount > rhs.matchCount
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent
        }
    }

    func isPinned(_ fileURL: URL) -> Bool {
        isPinned(fileURL: fileURL)
    }

    @discardableResult
    func togglePinned(at fileURL: URL) -> Bool {
        let next = !isPinned(fileURL: fileURL)
        _ = setPinned(next, for: fileURL)
        return next
    }

    func openNote(at fileURL: URL) {
        if fileURL == currentNoteURL {
            return
        }

        if let range = cursorStateProvider?() {
            saveCursorPosition(location: range.location, length: range.length, for: currentNoteURL)
        }

        deleteCurrentNoteFileIfEmpty()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        currentNoteURL = fileURL
        lastSavedCursor = nil
        let savedCursor = loadCursorPosition(for: fileURL)
        guard let data = try? Data(contentsOf: fileURL),
              let saved = String(data: data, encoding: .utf8) else {
            text = ""
            pendingCursorRestore = nil
            return
        }

        text = saved
        pendingCursorRestore = savedCursor
    }

    @discardableResult
    func deleteCurrentNote() -> DeletedNote? {
        let existingURL = currentNoteURL
        let existingContents = text
        let existsOnDisk = fileManager.fileExists(atPath: existingURL.path)
        let hasMeaningfulContent = !existingContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let wasPinned = existsOnDisk ? isPinned(fileURL: existingURL) : false

        guard existsOnDisk || hasMeaningfulContent else {
            return nil
        }

        if existsOnDisk {
            do {
                try fileManager.removeItem(at: existingURL)
            } catch {
                print("Failed to delete note: \(error)")
                return nil
            }
        }

        if let latestURL = latestNoteFileURL() {
            currentNoteURL = latestURL
            if let data = try? Data(contentsOf: latestURL),
               let saved = String(data: data, encoding: .utf8) {
                text = saved
            } else {
                text = ""
            }
        } else {
            currentNoteURL = notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)
            text = ""
        }

        let deleted = DeletedNote(fileURL: existingURL, contents: existingContents, wasPinned: wasPinned)
        registerDeletion(deleted)
        return deleted
    }

    @discardableResult
    func deleteNote(at fileURL: URL) -> DeletedNote? {
        if fileURL == currentNoteURL {
            return deleteCurrentNote()
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let wasPinned = isPinned(fileURL: fileURL)
        do {
            try fileManager.removeItem(at: fileURL)
            let deleted = DeletedNote(fileURL: fileURL, contents: contents, wasPinned: wasPinned)
            registerDeletion(deleted)
            return deleted
        } catch {
            print("Failed to delete note: \(error)")
            return nil
        }
    }

    func restoreDeletedNote(_ deleted: DeletedNote) {
        do {
            try deleted.contents.data(using: .utf8)?.write(to: deleted.fileURL, options: .atomic)
            if deleted.wasPinned {
                _ = setPinned(true, for: deleted.fileURL)
            }
            currentNoteURL = deleted.fileURL
            text = deleted.contents
        } catch {
            print("Failed to restore deleted note: \(error)")
        }
    }

    @discardableResult
    func undoLastDeletedNote() -> DeletedNote? {
        guard let deleted = lastDeletedNote else {
            return nil
        }
        restoreDeletedNote(deleted)
        lastDeletedNote = nil
        deletedNoteToast = nil
        return deleted
    }

    func dismissDeletedNoteToast() {
        deletedNoteToast = nil
    }

    func clearDeletedNoteUndo() {
        lastDeletedNote = nil
        deletedNoteToast = nil
    }

    private func deleteCurrentNoteFileIfEmpty() {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEmpty else {
            return
        }

        guard fileManager.fileExists(atPath: currentNoteURL.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: currentNoteURL)
        } catch {
            print("Failed to delete empty note: \(error)")
        }
    }

    private func registerDeletion(_ deleted: DeletedNote) {
        let hasMeaningfulContent = !deleted.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasMeaningfulContent else {
            return
        }
        lastDeletedNote = deleted
        deletedNoteToast = DeletedNoteToast(deleted: deleted)
    }

    private func latestNoteFileURL() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: keys
        ) else {
            return nil
        }

        let noteFiles = urls.filter { $0.pathExtension == "txt" && $0.lastPathComponent != "note.txt" }
        return noteFiles.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        })
    }

    private func migrateLegacySingleNoteIfNeeded() {
        let legacyURL = notesDirectoryURL.appendingPathComponent("note.txt", isDirectory: false)
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        guard latestNoteFileURL() == nil else {
            return
        }

        guard let data = try? Data(contentsOf: legacyURL),
              let saved = String(data: data, encoding: .utf8) else {
            return
        }

        currentNoteURL = notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)
        text = saved
        save()
    }

    private func isPinned(fileURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        return fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let size = getxattr(path, Self.pinnedXAttrName, nil, 0, 0, 0)
            guard size > 0 else {
                return false
            }
            var buffer = [UInt8](repeating: 0, count: Int(size))
            let readSize = getxattr(path, Self.pinnedXAttrName, &buffer, buffer.count, 0, 0)
            guard readSize > 0 else {
                return false
            }
            return Data(buffer.prefix(Int(readSize))) == Self.pinnedXAttrValue
        }
    }

    @discardableResult
    private func setPinned(_ pinned: Bool, for fileURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        return fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            if pinned {
                return Self.pinnedXAttrValue.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return false
                    }
                    return setxattr(path, Self.pinnedXAttrName, baseAddress, bytes.count, 0, 0) == 0
                }
            }
            let result = removexattr(path, Self.pinnedXAttrName, 0)
            return result == 0 || errno == ENOATTR
        }
    }

    func saveCursorPosition(location: Int, length: Int, for fileURL: URL) {
        if fileURL == currentNoteURL {
            lastSavedCursor = NSRange(location: location, length: length)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let value = "\(location),\(length)"
        guard let data = value.data(using: .utf8) else { return }
        fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = setxattr(path, Self.cursorXAttrName, baseAddress, bytes.count, 0, 0)
            }
        }
    }

    func loadCursorPosition(for fileURL: URL) -> NSRange? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL.withUnsafeFileSystemRepresentation { path -> NSRange? in
            guard let path else { return nil }
            let size = getxattr(path, Self.cursorXAttrName, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(size))
            let readSize = getxattr(path, Self.cursorXAttrName, &buffer, buffer.count, 0, 0)
            guard readSize > 0,
                  let str = String(data: Data(buffer.prefix(Int(readSize))), encoding: .utf8) else {
                return nil
            }
            let parts = str.split(separator: ",")
            guard parts.count == 2,
                  let location = Int(parts[0]),
                  let length = Int(parts[1]) else {
                return nil
            }
            return NSRange(location: location, length: length)
        }
    }
}

private extension String {
    func caseInsensitiveOccurrences(of query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex

        while let found = range(of: query, options: [.caseInsensitive], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<endIndex
        }
        return count
    }
}
