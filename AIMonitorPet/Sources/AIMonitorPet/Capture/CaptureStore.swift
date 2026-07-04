import Foundation

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var recentItems: [CaptureItem] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("AI监工", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("captures.jsonl")
        loadRecentItems()
        CaptureReminderScheduler.reschedulePendingReminders(for: recentItems)
    }

    func save(text: String, kind: CaptureKind, reminderAt: Date?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let item = CaptureItem(
            kind: kind,
            text: trimmed,
            reminderAt: kind == .todo ? reminderAt : nil
        )

        recentItems.insert(item, at: 0)
        try writeRecentItems()
        CaptureReminderScheduler.scheduleReminder(for: item)
    }

    func toggleCompleted(_ item: CaptureItem) {
        guard item.kind == .todo,
              let index = recentItems.firstIndex(where: { $0.id == item.id }) else { return }

        recentItems[index].isCompleted.toggle()
        recentItems[index].completedAt = recentItems[index].isCompleted ? Date() : nil

        do {
            try writeRecentItems()
        } catch {
            print("[CaptureStore] Failed to persist completion: \(error)")
        }

        if recentItems[index].isCompleted {
            CaptureReminderScheduler.cancelReminder(for: item.id)
        } else {
            CaptureReminderScheduler.scheduleReminder(for: recentItems[index])
        }
    }

    private func writeRecentItems() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try recentItems
            .reversed()
            .map { item -> String in
                let data = try encoder.encode(item)
                return String(decoding: data, as: UTF8.self)
            }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadRecentItems() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        recentItems = Array(content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(CaptureItem.self, from: Data(line.utf8))
            }
            .reversed())
    }
}
