import XCTest

final class berdUITests: XCTestCase {
    
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testAppLaunches() throws {
        // Verify the app launches successfully
        XCTAssertTrue(app.state == .runningForeground)
    }
    
    @MainActor
    func testChatInterfaceElements() throws {
        // Check if main navigation title exists
        let chatTitle = app.staticTexts["Chat"]
        XCTAssertTrue(chatTitle.exists || app.navigationBars["Chat"].exists, "Chat navigation should exist")
        
        // Check for settings button (gear icon)
        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.exists, "Settings button should exist")
        
        // Check for send button (paperplane icon)
        let sendButton = app.buttons["paperplane.fill"]
        XCTAssertTrue(sendButton.exists, "Send button should exist")
        
        // Check for text field
        let textField = app.textFields["Type your question…"]
        XCTAssertTrue(textField.exists, "Input text field should exist")
    }
    
    @MainActor
    func testSendButtonDisabledWhenEmpty() throws {
        let sendButton = app.buttons["paperplane.fill"]
        
        // Send button should be disabled initially (empty input)
        XCTAssertFalse(sendButton.isEnabled, "Send button should be disabled when input is empty")
    }
    
    @MainActor
    func testTextInputEnablesSendButton() throws {
        let textField = app.textFields["Type your question…"]
        let sendButton = app.buttons["paperplane.fill"]
        
        // Tap the text field and type
        textField.tap()
        textField.typeText("Hello")
        
        // Send button should now be enabled
        XCTAssertTrue(sendButton.isEnabled, "Send button should be enabled when input has text")
    }
    
    @MainActor
    func testSettingsSheet() throws {
        let settingsButton = app.buttons["gearshape"]
        
        // Tap settings button
        settingsButton.tap()
        
        // Wait for settings sheet to appear
        let systemPromptTitle = app.staticTexts["System Prompt"]
        XCTAssertTrue(systemPromptTitle.waitForExistence(timeout: 2), "Settings sheet should appear")
        
        // Check for system prompt options
        let defaultPrompt = app.staticTexts["Default"]
        let creativePrompt = app.staticTexts["Creative"]
        let coderPrompt = app.staticTexts["Code Helper"]
        let friendlyPrompt = app.staticTexts["Friendly"]
        
        XCTAssertTrue(defaultPrompt.exists, "Default prompt should exist")
        XCTAssertTrue(creativePrompt.exists, "Creative prompt should exist")
        XCTAssertTrue(coderPrompt.exists, "Code Helper prompt should exist")
        XCTAssertTrue(friendlyPrompt.exists, "Friendly prompt should exist")
        
        // Close settings
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }
    }
    
    @MainActor
    func testClearConversationButton() throws {
        // Check for trash button in toolbar
        let trashButton = app.buttons["trash"]
        XCTAssertTrue(trashButton.exists, "Clear conversation button should exist")
        
        // Initially it should be disabled (no messages)
        XCTAssertFalse(trashButton.isEnabled, "Clear button should be disabled when no messages exist")
    }
    
    @MainActor
    func testAppleIntelligenceAvailabilityMessage() throws {
        // This test checks if the availability message appears
        // On systems without Apple Intelligence, we should see the warning
        let warningIcon = app.images["exclamationmark.triangle.fill"]
        let warningTitle = app.staticTexts["Apple Intelligence Required"]
        
        // Either the chat interface or the warning should exist
        let chatElements = app.buttons["gearshape"].exists
        let warningExists = warningIcon.exists && warningTitle.exists
        
        XCTAssertTrue(chatElements || warningExists, "Either chat interface or availability warning should be visible")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
