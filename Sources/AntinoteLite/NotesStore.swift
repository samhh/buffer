import Foundation

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
        notesDirectoryURL = appSupportDir.appendingPathComponent("AntinoteLite", isDirectory: true)
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
        currentNoteURL = notesDirectoryURL.appendingPathComponent("\(UUID().uuidString).txt", isDirectory: false)
        text = ""
        save()
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
