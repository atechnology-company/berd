//
//  berdTests.swift
//  berdTests
//
//  Created by Max Lee Abdurrahman Carter on 5/10/2025.
//

import Testing
import Foundation
@testable import berd

struct berdTests {

    @Test func testSystemPromptPresets() async throws {
        // Verify all system prompts are available
        #expect(SystemPrompt.all.count == 4)
        #expect(SystemPrompt.all.contains(SystemPrompt.default))
        #expect(SystemPrompt.all.contains(SystemPrompt.creative))
        #expect(SystemPrompt.all.contains(SystemPrompt.coder))
        #expect(SystemPrompt.all.contains(SystemPrompt.friendly))
    }
    
    @Test func testAIChatMessageCreation() async throws {
        let userMessage = AIChatMessage(sender: .user, text: "Hello")
        #expect(userMessage.sender == .user)
        #expect(userMessage.text == "Hello")
        #expect(userMessage.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        
        let aiMessage = AIChatMessage(sender: .ai, text: "Hi there!")
        #expect(aiMessage.sender == .ai)
        #expect(aiMessage.text == "Hi there!")
    }
    
    @Test func testAIChatMessageMutability() async throws {
        var message = AIChatMessage(sender: .ai, text: "Hello")
        #expect(message.text == "Hello")
        
        // Test that we can update text (needed for streaming)
        message.text += " world"
        #expect(message.text == "Hello world")
    }
    
    @Test func testComposePromptBasic() async throws {
        let history: [AIChatMessage] = []
        let userInput = "What is 2+2?"
        let systemPrompt = SystemPrompt.default
        
        let prompt = AIChatService.composePrompt(
            history: history,
            userInput: userInput,
            systemPrompt: systemPrompt
        )
        
        #expect(prompt.contains("SYSTEM: \(systemPrompt.prompt)"))
        #expect(prompt.contains("USER: \(userInput)"))
        #expect(prompt.contains("ASSISTANT:"))
    }
    
    @Test func testComposePromptWithHistory() async throws {
        let history = [
            AIChatMessage(sender: .user, text: "Hello"),
            AIChatMessage(sender: .ai, text: "Hi there!"),
            AIChatMessage(sender: .user, text: "How are you?")
        ]
        let userInput = "What's the weather?"
        let systemPrompt = SystemPrompt.friendly
        
        let prompt = AIChatService.composePrompt(
            history: history,
            userInput: userInput,
            systemPrompt: systemPrompt
        )
        
        #expect(prompt.contains("SYSTEM: \(systemPrompt.prompt)"))
        #expect(prompt.contains("USER: Hello"))
        #expect(prompt.contains("ASSISTANT: Hi there!"))
        #expect(prompt.contains("USER: How are you?"))
        #expect(prompt.contains("USER: \(userInput)"))
        #expect(prompt.hasSuffix("ASSISTANT: "))
    }
    
    @Test func testComposePromptLimitsHistory() async throws {
        // Create 15 messages (more than the 10 message limit)
        var history: [AIChatMessage] = []
        for i in 0..<15 {
            history.append(AIChatMessage(sender: .user, text: "Message \(i)"))
            history.append(AIChatMessage(sender: .ai, text: "Response \(i)"))
        }
        
        let userInput = "Final question"
        let systemPrompt = SystemPrompt.default
        
        let prompt = AIChatService.composePrompt(
            history: history,
            userInput: userInput,
            systemPrompt: systemPrompt
        )
        
        // Should only include last 10 messages
        #expect(!prompt.contains("Message 0"))
        #expect(!prompt.contains("Message 1"))
        #expect(!prompt.contains("Message 2"))
        #expect(!prompt.contains("Message 3"))
        #expect(!prompt.contains("Message 4"))
        
        // Should include the more recent messages
        #expect(prompt.contains("Message 14"))
        #expect(prompt.contains("Response 14"))
    }
    
    @Test func testSystemPromptCodable() async throws {
        let original = SystemPrompt.coder
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SystemPrompt.self, from: data)
        
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.description == original.description)
        #expect(decoded.prompt == original.prompt)
    }
    
    @Test func testAIChatMessageCodable() async throws {
        let original = AIChatMessage(sender: .user, text: "Test message")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AIChatMessage.self, from: data)
        
        #expect(decoded.id == original.id)
        #expect(decoded.sender == original.sender)
        #expect(decoded.text == original.text)
    }
    
    @Test func testAIAvailabilityExists() async throws {
        // Just verify the type exists and has the expected property
        let available = AIAvailability.appleIntelligenceAvailable
        // The actual value depends on the platform, but it should be a Bool
        #expect(available == true || available == false)
    }

}
