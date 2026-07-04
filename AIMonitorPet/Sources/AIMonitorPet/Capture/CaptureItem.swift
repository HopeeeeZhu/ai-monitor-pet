import Foundation

enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case todo
    case idea

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "待办"
        case .idea: return "想法"
        }
    }
}

struct CaptureItem: Codable, Identifiable {
    let id: UUID
    let kind: CaptureKind
    let text: String
    let createdAt: Date
    let source: String
    var isCompleted: Bool
    var completedAt: Date?
    var reminderAt: Date?

    init(
        id: UUID = UUID(),
        kind: CaptureKind,
        text: String,
        createdAt: Date = Date(),
        source: String = "voice",
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        reminderAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.source = source
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.reminderAt = reminderAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case createdAt
        case source
        case isCompleted
        case completedAt
        case reminderAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(CaptureKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "voice"
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
    }
}
