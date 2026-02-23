import Foundation

struct NoteSearchResult: Identifiable {
    let id: URL
    let fileURL: URL
    let title: String
    let snippet: String
    let modifiedAt: Date
}

struct DeletedNote {
    let fileURL: URL
    let contents: String
}

final class NotesStore: ObservableObject {
    @Published var text: String = "" {
        didSet {
            save()
        }
    }

    private let fileManager = FileManager.default
    private let notesDirectoryURL: URL
    private var currentNoteURL: URL

    init() {
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        notesDirectoryURL = appSupportDir.appendingPathComponent("Buffer", isDirectory: true)
        currentNoteURL = notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)

        do {
            try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
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
        do {
            try text.data(using: .utf8)?.write(to: currentNoteURL, options: .atomic)
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

            if normalizedQuery.isEmpty {
                let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Untitled"
                results.append(
                    NoteSearchResult(
                        id: fileURL,
                        fileURL: fileURL,
                        title: firstLine,
                        snippet: "",
                        modifiedAt: modifiedAt
                    )
                )
                continue
            }

            guard let matchLine = lines.first(where: { $0.localizedCaseInsensitiveContains(normalizedQuery) }) else {
                continue
            }

            let title = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? fileURL.deletingPathExtension().lastPathComponent
            results.append(
                NoteSearchResult(
                    id: fileURL,
                    fileURL: fileURL,
                    title: title,
                    snippet: matchLine,
                    modifiedAt: modifiedAt
                )
            )
        }

        return results.sorted(by: { $0.modifiedAt > $1.modifiedAt })
    }

    func openNote(at fileURL: URL) {
        if fileURL == currentNoteURL {
            return
        }

        deleteCurrentNoteFileIfEmpty()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        currentNoteURL = fileURL
        guard let data = try? Data(contentsOf: fileURL),
              let saved = String(data: data, encoding: .utf8) else {
            text = ""
            return
        }

        text = saved
    }

    @discardableResult
    func deleteCurrentNote() -> DeletedNote? {
        let existingURL = currentNoteURL
        let existingContents = text
        let existsOnDisk = fileManager.fileExists(atPath: existingURL.path)
        let hasMeaningfulContent = !existingContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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

        return DeletedNote(fileURL: existingURL, contents: existingContents)
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
        do {
            try fileManager.removeItem(at: fileURL)
            return DeletedNote(fileURL: fileURL, contents: contents)
        } catch {
            print("Failed to delete note: \(error)")
            return nil
        }
    }

    func restoreDeletedNote(_ deleted: DeletedNote) {
        do {
            try deleted.contents.data(using: .utf8)?.write(to: deleted.fileURL, options: .atomic)
            currentNoteURL = deleted.fileURL
            text = deleted.contents
        } catch {
            print("Failed to restore deleted note: \(error)")
        }
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
}
