import Foundation

final class NotesStore: ObservableObject {
    @Published var text: String = "" {
        didSet {
            save()
        }
    }

    private let fileURL: URL

    init() {
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = appSupportDir.appendingPathComponent("AntinoteLite", isDirectory: true)
        fileURL = directory.appendingPathComponent("note.txt", isDirectory: false)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create application support directory: \(error)")
        }

        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = String(data: data, encoding: .utf8) else {
            return
        }
        text = saved
    }

    private func save() {
        do {
            try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save notes: \(error)")
        }
    }
}
