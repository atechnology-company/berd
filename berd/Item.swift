import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

// MARK: - Conversation Model for SwiftData
@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var systemPromptID: String
    @Relationship(deleteRule: .cascade) var messages: [ConversationMessage]
    
    init(id: UUID = UUID(), title: String = "New Conversation", systemPromptID: String = "default") {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.systemPromptID = systemPromptID
        self.messages = []
    }
}

@Model
final class ConversationMessage {
    var id: UUID
    var senderRaw: String // "user" or "ai"
    var text: String
    var timestamp: Date
    
    init(id: UUID = UUID(), sender: AIChatMessage.Sender, text: String) {
        self.id = id
        self.senderRaw = sender.rawValue
        self.text = text
        self.timestamp = Date()
    }
    
    var sender: AIChatMessage.Sender {
        AIChatMessage.Sender(rawValue: senderRaw) ?? .user
    }
    
    func toAIChatMessage() -> AIChatMessage {
        AIChatMessage(id: id, sender: sender, text: text)
    }
}
