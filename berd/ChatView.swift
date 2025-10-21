import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Chat View Model
@MainActor
class ChatViewModel: ObservableObject {
    @Published var showSidebar: Bool = false
    @Published var messages: [AIChatMessage] = []
    @Published var input: String = ""
    @Published var isSending: Bool = false
    @Published var showSettings: Bool = false
    @Published var systemPrompt: SystemPrompt = .default
    @Published var customPrompt: String = ""
    @Published var usePerplexitySearch: Bool = false
    @AppStorage("perplexityAPIKey") var perplexityAPIKey: String = ""
    @Published var usePCC: Bool = false
    @Published var usePCCFileHandshake: Bool = false
    @AppStorage("geminiAPIKey") var geminiAPIKey: String = ""
    @Published var isDictating: Bool = false
    @Published var searchText: String = ""
    @Published var currentSources: [PerplexitySource] = []
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var showCensoredAlert: Bool = false
    @Published var censoredPrompt: String = ""
    @Published var censoredSources: [PerplexitySource] = []
    @Published var regeneratingMessageID: UUID? = nil
    
    var hasInputText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var effectivePrompt: SystemPrompt {
        if !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SystemPrompt(
                id: "custom",
                name: "Custom",
                description: "Your custom prompt",
                prompt: customPrompt
            )
        }
        return systemPrompt
    }
    
    private var currentConversation: Conversation?
    private var modelContext: ModelContext?
    private var sendTask: Task<Void, Never>?
    
    var appleIntelligenceAvailable: Bool {
        AIAvailability.appleIntelligenceAvailable
    }
    
    /// Detect if a response was censored by Apple Intelligence
    private func isCensored(_ text: String) -> Bool {
        let censoredPhrases = [
            "I'm sorry",
            "I cannot assist",
            "I am unable to fulfill",
            "I cannot comply",
            "I'm not able to",
            "I can't assist"
        ]
        
        let lowercased = text.lowercased()
        return censoredPhrases.contains { lowercased.contains($0.lowercased()) }
    }
    
    /// Regenerate response using Gemini 2.5 Flash and stream into the specific message
    func regenerateWithGemini(for messageID: UUID?) {
        guard !geminiAPIKey.isEmpty else {
            errorMessage = "Please add your Gemini API key in Settings → Advanced"
            showError = true
            return
        }

        isSending = true
        regeneratingMessageID = messageID

        Task { @MainActor in
            do {
                // Find target AI message
                let targetIndex: Int?
                if let mid = messageID {
                    targetIndex = messages.firstIndex(where: { $0.id == mid && $0.sender == .ai })
                } else {
                    targetIndex = messages.lastIndex(where: { $0.sender == .ai })
                }

                guard let idx = targetIndex else {
                    throw NSError(domain: "ChatViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Target message not found for Gemini regeneration"]) 
                }

                // Prepare context
                let context = censoredSources.isEmpty ? nil : PerplexityService.shared.createAugmentedPrompt(
                    originalQuery: censoredPrompt,
                    sources: censoredSources,
                    fetchedContent: [:]
                )

                // Clear the message text to show skeleton/loading
                messages[idx].text = ""
                messages[idx].wasCensored = true

                // Call Gemini (no streaming API here), then stream locally for UX
                let fullResponse = try await GeminiService.shared.generate(
                    prompt: censoredPrompt,
                    context: context,
                    apiKey: geminiAPIKey
                )

                // Stream the response into the message by words for a nice typing effect
                let tokens = fullResponse.split(separator: " ")
                var built = ""
                for (i, token) in tokens.enumerated() {
                    built += (i == 0 ? "" : " ") + token
                    messages[idx].text = built
                    // a short delay to simulate streaming; small enough to feel fluid
                    try? await Task.sleep(nanoseconds: 18_000_000)
                }

                // Finalize
                messages[idx].sources = censoredSources.isEmpty ? nil : censoredSources
                messages[idx].wasCensored = false
                saveMessage(messages[idx])

                // Clear censor state
                censoredPrompt = ""
                censoredSources = []
            } catch {
                errorMessage = "Gemini error: \(error.localizedDescription)"
                showError = true
            }

            // Reset UI
            regeneratingMessageID = nil
            isSending = false
        }
    }
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadOrCreateConversation()
        // Listen for PCC x-callback results
        NotificationCenter.default.addObserver(forName: Notification.Name("BerdPCCResultReceived"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo, let fileURL = info["fileURL"] as? URL {
                if let data = try? Data(contentsOf: fileURL),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = obj["result"] as? String {
                    let aiMessage = AIChatMessage(sender: .ai, text: result)
                    self.messages.append(aiMessage)
                    self.saveMessage(aiMessage)
                }
            }

            // Listen for requests to show install shortcut instructions
            NotificationCenter.default.addObserver(forName: Notification.Name("BerdShowInstallShortcut"), object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    #if os(iOS)
                    self.errorMessage = "To install the shortcut: open the Shortcuts app, tap Gallery, then import the 'Berd-PCC' shortcut you downloaded from the app."
                    self.showError = true
                    #elseif os(macOS)
                    // Try CLI import and report result
                    do {
                        try await PCCService.shared.ensureBundledShortcutImportedIfNeeded(shortcutName: "Berd-PCC")
                        self.errorMessage = "Berd-PCC shortcut imported to Shortcuts.app"
                        self.showError = true
                    } catch {
                        self.errorMessage = "Failed to import shortcut: \(error.localizedDescription)"
                        self.showError = true
                    }
                    #endif
                }
            }

            NotificationCenter.default.addObserver(forName: Notification.Name("BerdShowShortcutInstructions"), object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.errorMessage = "File-handshake: enable 'Use file-based handshake' and the app will write prompts to a temporary file Shortcuts can read, then Shortcuts writes a result file which the app reads. On iOS you must install the provided 'Berd-PCC' shortcut manually."
                self.showError = true
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func loadOrCreateConversation() {
        guard let modelContext = modelContext else { return }
        
        // Try to load the most recent conversation
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        
        if let conversations = try? modelContext.fetch(descriptor),
           let latest = conversations.first {
            currentConversation = latest
            messages = latest.messages.map { $0.toAIChatMessage() }
            if let promptID = SystemPrompt.all.first(where: { $0.id == latest.systemPromptID }) {
                systemPrompt = promptID
            }
        } else {
            // Create new conversation
            let conversation = Conversation()
            modelContext.insert(conversation)
            try? modelContext.save()
            currentConversation = conversation
        }
    }
    
    func clearConversation() {
        guard let modelContext = modelContext else { return }
        
        // Cancel any ongoing send
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        
        // Don't delete the current conversation - just create a new one
        // This preserves conversation history
        let conversation = Conversation()
        conversation.systemPromptID = systemPrompt.id
        modelContext.insert(conversation)
        try? modelContext.save()
        
        currentConversation = conversation
        messages = []
        input = ""
        errorMessage = nil
        showError = false
        currentSources = []
    }
    
    private func saveMessage(_ message: AIChatMessage) {
        guard let modelContext = modelContext,
              let conversation = currentConversation else { return }
        
        let conversationMessage = ConversationMessage(
            id: message.id,
            sender: message.sender,
            text: message.text
        )
        conversation.messages.append(conversationMessage)
        conversation.updatedAt = Date()
        
        try? modelContext.save()
    }
    
    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        
        input = ""
        errorMessage = nil
        showError = false
        
        // Add user message
        let userMessage = AIChatMessage(sender: .user, text: prompt)
        messages.append(userMessage)
        saveMessage(userMessage)
        
        isSending = true
        currentSources = [] // Clear previous sources
        
        // Append empty AI message to update with streaming tokens
        let aiMessageID = UUID()
        var aiMessage = AIChatMessage(id: aiMessageID, sender: .ai, text: "")
        messages.append(aiMessage)
        
        sendTask = Task { @MainActor in
            do {
                guard let lastIndex = messages.firstIndex(where: { $0.id == aiMessageID }) else {
                    throw NSError(domain: "ChatViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Message index not found"])
                }
                
                var finalPrompt = prompt
                
                // Perform Perplexity search if enabled
                if usePerplexitySearch && !perplexityAPIKey.isEmpty {
                    do {
                        // Search for relevant information
                        let sources = try await PerplexityService.shared.search(
                            query: prompt,
                            apiKey: perplexityAPIKey,
                            maxResults: 5
                        )
                        
                        // Update UI with sources
                        currentSources = sources
                        
                        // Fetch content from top sources (limit to 3 to avoid timeout)
                        var fetchedContent: [String: String] = [:]
                        for source in sources.prefix(3) {
                            if let content = try? await PerplexityService.shared.fetchPageContent(url: source.url) {
                                fetchedContent[source.url] = content
                            }
                        }
                        
                        // Create augmented prompt with search results INCLUDING fetched content
                        finalPrompt = PerplexityService.shared.createAugmentedPrompt(
                            originalQuery: prompt,
                            sources: sources,
                            fetchedContent: fetchedContent
                        )
                        
                        // Store sources for potential censorship detection
                        if lastIndex < messages.count {
                            messages[lastIndex].sources = sources
                        }
                        
                    } catch let perplexityError as PerplexityError {
                        // Show error but continue with original prompt
                        print("Perplexity search failed: \(perplexityError.localizedDescription)")
                        // Optionally show a subtle warning to user
                    }
                }
                
                // Use PCC or on-device model
                if usePCC {
                    // If user selected file-handshake, use that path
                    if usePCCFileHandshake {
                        do {
                            let response = try await PCCService.shared.runShortcutWithFileHandshake(prompt: finalPrompt, shortcutName: "Berd-PCC")
                            if lastIndex < messages.count {
                                messages[lastIndex].text = response
                            }
                        } catch {
                            // Fall back to standard PCC query (App Intents / CLI run)
                            let response = try await PCCService.shared.query(finalPrompt)
                            if lastIndex < messages.count {
                                messages[lastIndex].text = response
                            }
                        }
                    } else {
                        // Use Private Cloud Compute via Shortcuts / App Intents
                        let response = try await PCCService.shared.query(finalPrompt)

                        // Update message with full response
                        if lastIndex < messages.count {
                            messages[lastIndex].text = response
                        }
                    }
                } else {
                    // Use on-device Apple Intelligence
                    try await AIChatService.shared.chat(
                        history: messages,
                        userInput: finalPrompt,
                        systemPrompt: effectivePrompt,
                        onToken: { [weak self] token in
                            guard let self = self else { return }
                            Task { @MainActor in
                                if lastIndex < self.messages.count {
                                    self.messages[lastIndex].text += token
                                }
                            }
                        }
                    )
                }
                
                // Save the completed AI message
                if lastIndex < messages.count {
                    let response = messages[lastIndex].text
                    
                    // Check if response was censored
                    if isCensored(response) {
                        messages[lastIndex].wasCensored = true
                        censoredPrompt = prompt
                        censoredSources = messages[lastIndex].sources ?? []
                        
                        // Show alert with options
                        showCensoredAlert = true
                    }
                    
                    saveMessage(messages[lastIndex])
                }
                
                // Don't clear sources - keep them with the message
                currentSources = []
                
            } catch {
                let errorText = "Error: \(error.localizedDescription)"
                errorMessage = errorText
                showError = true
                
                // Replace the placeholder with error message
                if let lastIndex = messages.firstIndex(where: { $0.id == aiMessageID }) {
                    messages[lastIndex].text = errorText
                    saveMessage(messages[lastIndex])
                }
                
                currentSources = [] // Clear sources on error
            }
            
            isSending = false
            sendTask = nil
        }
    }
    
    func retryLastMessage() {
        // Remove the last AI message (error message)
        if let lastMessage = messages.last, lastMessage.sender == .ai {
            messages.removeLast()
        }
        
        // Get the last user message and resend
        if let lastUserMessage = messages.last(where: { $0.sender == .user }) {
            input = lastUserMessage.text
            messages.removeLast() // Remove the user message to re-add it
            send()
        }
    }
    
    func startDictation() {
        #if os(macOS)
        isDictating = true
        Task { @MainActor in
            // Simulate dictation for now - in production use NSSpeechRecognizer
            // For macOS, we can trigger the system dictation shortcut
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true) {
                event.flags = [.maskCommand, .maskCommand] // Fn key twice
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            isDictating = false
        }
        #elseif os(iOS)
        // iOS dictation is handled automatically by the keyboard
        isDictating = false
        #endif
    }
    
    func handleVisualIntelligenceRequest() {
        Task { @MainActor in
            do {
                #if os(macOS)
                // macOS: Use NSOpenPanel for file selection
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.image, .pdf, .plainText]
                panel.message = "Select an image or document to analyze"
                
                let response = panel.runModal()
                guard response == .OK, let fileURL = panel.url else { return }
                
                // Read file and create a descriptive message
                let fileName = fileURL.lastPathComponent
                let fileType = fileURL.pathExtension.uppercased()
                
                // Add user message indicating file selection
                let fileMessage = "📎 Analyzing \(fileName) (\(fileType))"
                let userMsg = AIChatMessage(sender: .user, text: fileMessage)
                messages.append(userMsg)
                saveMessage(userMsg)
                
                // Prepare analysis request
                input = "Please analyze this \(fileType) file: \(fileName). Describe what you see and extract any relevant information."
                
                #elseif os(iOS)
                // iOS: Try to use Visual Intelligence framework if available
                if #available(iOS 18.0, *) {
                    do {
                        let helper = VisualIntelligenceHelper()
                        let result = try await helper.startVisualIntelligence(from: nil)
                        
                        // Add user message with analysis result
                        let analysisMessage = "📷 Visual Intelligence Analysis:\n\n\(result)"
                        let userMsg = AIChatMessage(sender: .user, text: analysisMessage)
                        messages.append(userMsg)
                        saveMessage(userMsg)
                        
                        // Prepare follow-up question
                        input = "Please analyze this visual intelligence result and provide insights."
                        
                    } catch VisualIntelligenceHelper.VIError.notAvailable {
                        // Fallback to document picker
                        let helper = VisualIntelligenceHelper()
                        if let data = try await helper.presentDocumentPicker() {
                            let fileMessage = "📎 File selected for analysis (\(data.count) bytes)"
                            let userMsg = AIChatMessage(sender: .user, text: fileMessage)
                            messages.append(userMsg)
                            saveMessage(userMsg)
                            
                            input = "Please analyze this file and extract any relevant information."
                        } else {
                            let userMsg = AIChatMessage(sender: .user, text: "📷 Visual Intelligence requested")
                            messages.append(userMsg)
                            saveMessage(userMsg)
                            
                            input = "I'd like to analyze an image or document using Visual Intelligence, but the framework is not available on this device."
                        }
                    } catch {
                        errorMessage = "Visual Intelligence failed: \(error.localizedDescription)"
                        showError = true
                    }
                } else {
                    // iOS version too old
                    let userMsg = AIChatMessage(sender: .user, text: "📷 Visual Intelligence requested")
                    messages.append(userMsg)
                    saveMessage(userMsg)
                    
                    input = "I'd like to analyze an image or document, but Visual Intelligence requires iOS 18.0 or later."
                }
                #endif
                
            } catch {
                errorMessage = "Failed to select file: \(error.localizedDescription)"
                showError = true
            }
        }
    }
} // End of ChatViewModel class

// MARK: - Chat SwiftUI View
struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model = ChatViewModel()
    @FocusState private var inputFocused: Bool
    @State private var showClearConfirmation = false
    
    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()
            
            if !model.appleIntelligenceAvailable {
                // Error state - centered message
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    Text("Apple Intelligence Required")
                        .font(.title3)
                        .bold()
                        .foregroundColor(.white)
                    Text(AIAvailability.statusMessage)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                }
                .padding()
            } else {
                HStack(spacing: 0) {
                    // Sidebar slides from left
                    if model.showSidebar {
                        ConversationSidebarView(
                            isPresented: $model.showSidebar,
                            onNewChat: {
                                model.clearConversation()
                                model.showSidebar = false
                            },
                            onShowSettings: {
                                model.showSettings = true
                                model.showSidebar = false
                            }
                        )
                        .frame(width: 280)
                        .transition(.move(edge: .leading))
                    }
                    
                    // Main content area - slides right when sidebar is shown
                    VStack(spacing: 0) {
                    // Top bar with hamburger menu
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                model.showSidebar.toggle()
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 2)
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 2)
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 2)
                            }
                            .padding()
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                    .frame(height: 60)
                    
                    // Main content area
                    ZStack {
                        if model.messages.isEmpty {
                            // Centered logo when no messages
                            VStack(spacing: 24) {
                                Spacer()
                                
                                // Signature-style logo
                                Text("berd")
                                    .font(.custom("Bradley Hand", size: 72))
                                    .foregroundColor(.white)
                                    .italic()
                                
                                // Disclaimer about Apple Intelligence limitations
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(.blue.opacity(0.8))
                                            .font(.system(size: 12))
                                        Text("Apple Intelligence has content restrictions")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))
                                    }
                                    
                                    Text("When blocked, web results and Gemini fallback are available.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.7))
                                        .multilineTextAlignment(.center)
                                }
                                .padding(12)
                                .frame(maxWidth: 350)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                Spacer()
                            }
                            .padding(.horizontal, 40)
                        } else {
                            // Message list
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 20) {
                                        ForEach(model.messages) { msg in
                                            MessageBubbleView(
                                                message: msg,
                                                isGenerating: model.isSending && msg.id == model.messages.last?.id && msg.sender == .ai,
                                                sources: msg.sources ?? []
                                            )
                                            .id(msg.id)
                                        }
                                        
                                        // Show search indicator if searching
                                        if model.isSending && model.usePerplexitySearch && !model.perplexityAPIKey.isEmpty && model.currentSources.isEmpty {
                                            HStack(alignment: .top) {
                                                Spacer(minLength: 40)
                                                VStack(alignment: .leading, spacing: 8) {
                                                    HStack(spacing: 8) {
                                                        ProgressView()
                                                            .progressViewStyle(.circular)
                                                            .scaleEffect(0.8)
                                                            .tint(.blue)
                                                        Text("Searching the web...")
                                                            .font(.system(size: 14))
                                                            .foregroundColor(.white.opacity(0.7))
                                                    }
                                                }
                                                .padding(12)
                                                .background(Color.blue.opacity(0.15))
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                }
                                .onChange(of: model.messages.count) { _ in
                                    if let last = model.messages.last?.id {
                                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Bottom input area
                    HStack(spacing: 12) {
                        Button {
                            model.handleVisualIntelligenceRequest()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        
                        ZStack(alignment: .trailing) {
                            TextField("", text: $model.input, axis: .vertical)
                                .focused($inputFocused)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .lineLimit(1...5)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .overlay(
                                    Group {
                                        if model.input.isEmpty && !model.isDictating {
                                            Text("ask (almost) anything")
                                                .foregroundColor(.white.opacity(0.4))
                                                .padding(.leading, 16)
                                        } else if model.isDictating {
                                            HStack {
                                                Image(systemName: "mic.fill")
                                                    .foregroundColor(.red)
                                                Text("Listening...")
                                                    .foregroundColor(.white.opacity(0.6))
                                            }
                                            .padding(.leading, 16)
                                        }
                                    },
                                    alignment: .leading
                                )
                        }
                        
                        HStack(spacing: 12) {
                            if model.hasInputText {
                                Button {
                                    model.send()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isSending)
                                .transition(.scale.combined(with: .opacity))
                            }
                            
                            if !model.hasInputText {
                                Button {
                                    model.startDictation()
                                } label: {
                                    Image(systemName: model.isDictating ? "mic.fill" : "mic")
                                        .font(.system(size: 20))
                                        .foregroundColor(model.isDictating ? .red : .white.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: model.hasInputText)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.black)
                    }
                    .offset(x: model.showSidebar ? 280 : 0)
                    .animation(.easeInOut(duration: 0.3), value: model.showSidebar)
                }
                .alert("Clear Conversation", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        model.clearConversation()
                    }
                } message: {
                    Text("Are you sure you want to clear this conversation? This action cannot be undone.")
                }
                .alert("Error", isPresented: $model.showError) {
                    Button("OK", role: .cancel) { }
                    Button("Retry") {
                        model.retryLastMessage()
                    }
                } message: {
                    Text(model.errorMessage ?? "An unknown error occurred.")
                }
                // Inline censorship UI is rendered within MessageBubbleView now
                .onAppear {
                    model.configure(modelContext: modelContext)
                }
                .sheet(isPresented: $model.showSettings) {
                    SettingsView(
                        systemPrompt: $model.systemPrompt,
                        customPrompt: $model.customPrompt,
                        usePerplexitySearch: $model.usePerplexitySearch,
                        perplexityAPIKey: $model.perplexityAPIKey,
                        usePCC: $model.usePCC,
                        usePCCFileHandshake: $model.usePCCFileHandshake,
                        geminiAPIKey: $model.geminiAPIKey,
                        isPresented: $model.showSettings
                    )
                }
            }
        }
        .environmentObject(model)
    }
}

// MARK: - Conversation Sidebar
struct ConversationSidebarView: View {
    @Binding var isPresented: Bool
    let onNewChat: () -> Void
    let onShowSettings: () -> Void
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var searchText: String = ""
    
    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversations
        }
        return conversations.filter { conv in
            conv.title.localizedCaseInsensitiveContains(searchText) ||
            conv.messages.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with search and new chat
            VStack(spacing: 12) {
                HStack {
                    Text("Conversations")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button {
                        onNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                
                // Full-width search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.system(size: 14))
                    
                    TextField("Search conversations...", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.5))
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
            }
            .padding()
            .background(Color.black)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Conversation list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredConversations) { conversation in
                        ConversationRowView(conversation: conversation)
                    }
                }
                
                if filteredConversations.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.3))
                        Text("No conversations found")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 14))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            
            Spacer()
            
            // Bottom buttons
            Divider()
                .background(Color.white.opacity(0.1))
            
            VStack(spacing: 0) {
                Button {
                    // Clear all conversations
                    if let modelContext = conversations.first?.modelContext {
                        for conversation in conversations {
                            modelContext.delete(conversation)
                        }
                        try? modelContext.save()
                    }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                        Text("Clear All")
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding()
                }
                .buttonStyle(.plain)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                Button {
                    onShowSettings()
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16))
                        Text("Settings")
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .foregroundColor(.white.opacity(0.8))
                    .padding()
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black)
    }
}

// MARK: - Conversation Row
struct ConversationRowView: View {
    let conversation: Conversation
    
    private var previewText: String {
        conversation.messages.last?.text ?? "New conversation"
    }
    
    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "message")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                
                Text(conversation.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                Text(timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            Text(previewText)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.02))
        .contentShape(Rectangle())
        .onTapGesture {
            // TODO: Load this conversation
        }
    }
}

// MARK: - Settings View with Tabs
struct SettingsView: View {
    @Binding var systemPrompt: SystemPrompt
    @Binding var customPrompt: String
    @Binding var usePerplexitySearch: Bool
    @Binding var perplexityAPIKey: String
    @Binding var usePCC: Bool
    @Binding var usePCCFileHandshake: Bool
    @Binding var geminiAPIKey: String
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                Picker("Settings", selection: $selectedTab) {
                    Text("Prompts").tag(0)
                    Text("Search").tag(1)
                    Text("Advanced").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Tab content
                TabView(selection: $selectedTab) {
                    // Prompts Tab
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // System prompts
                            VStack(alignment: .leading, spacing: 12) {
                                Text("System Prompts")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                ForEach(SystemPrompt.all) { prompt in
                                    Button {
                                        systemPrompt = prompt
                                        customPrompt = ""
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(prompt.name)
                                                    .font(.body)
                                                    .foregroundColor(.white)
                                                Text(prompt.description)
                                                    .font(.caption)
                                                    .foregroundColor(.white.opacity(0.6))
                                            }
                                            Spacer()
                                            if systemPrompt == prompt && customPrompt.isEmpty {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                        .padding()
                                        .background(systemPrompt == prompt && customPrompt.isEmpty ? Color.blue.opacity(0.2) : Color.white.opacity(0.1))
                                        .cornerRadius(10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            
                            Divider()
                            
                            // Custom prompt
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Custom Prompt")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    if !customPrompt.isEmpty {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                
                                Text("Write your own system prompt to customize the AI's behavior")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TextEditor(text: $customPrompt)
                                    .frame(height: 120)
                                    .padding(8)
                                    .foregroundColor(.white)
                                    .scrollContentBackground(.hidden)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                                
                                if !customPrompt.isEmpty {
                                    Button {
                                        customPrompt = ""
                                    } label: {
                                        Text("Clear Custom Prompt")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .tag(0)
                    
                    // Search Tab
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Search Integration")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Toggle(isOn: $usePerplexitySearch) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Perplexity Search")
                                            .font(.body)
                                            .foregroundColor(.white)
                                        Text("Augment responses with real-time web search results")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                                .toggleStyle(.switch)
                                .padding()
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(10)
                                
                                if usePerplexitySearch {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("Search is enabled", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                        
                                        Text("When enabled, the AI will use Perplexity to search the web and provide up-to-date information with citations.")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                            .padding(.top, 4)
                                        
                                        Divider()
                                            .background(Color.white.opacity(0.2))
                                            .padding(.vertical, 4)
                                        
                                        Text("API Key")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        
                                        Text("Enter your Perplexity API key to enable search functionality")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        SecureField("pplx-xxxxxxxxxxxxxxxxx", text: $perplexityAPIKey)
                                            .textFieldStyle(.plain)
                                            .foregroundColor(.white)
                                            .padding(12)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                            )
                                        
                                        if !perplexityAPIKey.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                    .font(.caption)
                                                Text("API key saved")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }
                                    .padding()
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .padding()
                    }
                    .tag(1)
                    
                    // Advanced Tab
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Advanced Settings")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                // Private Cloud Compute Toggle
                                Toggle(isOn: $usePCC) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Private Cloud Compute")
                                            .font(.body)
                                            .foregroundColor(.white.opacity(0.5))
                                        Text("Use Apple's cloud-based AI for enhanced capabilities")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }
                                .toggleStyle(.switch)
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(10)
                                .disabled(true)
                                
                                if usePCC {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label("PCC Enabled", systemImage: "cloud.fill")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                        
                                        Text("Private Cloud Compute routes queries through Apple's secure cloud infrastructure. Responses may be slower but offer enhanced capabilities.")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        Text("• Privacy-preserving cloud processing")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                                        Text("• No data retention or training")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                                        Text("• Comparable to 8B parameter models")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                    
                                    // File-based handshake option
                                    VStack(alignment: .leading, spacing: 8) {
                                        Toggle(isOn: $usePCCFileHandshake) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Use file-based handshake")
                                                    .font(.subheadline)
                                                    .foregroundColor(.white)
                                                Text("Write the prompt to a file and let Shortcuts read/write result files. Safer for large payloads.")
                                                    .font(.caption)
                                                    .foregroundColor(.white.opacity(0.6))
                                            }
                                        }
                                        .toggleStyle(.switch)
                                        .padding()
                                        .background(Color.white.opacity(0.04))
                                        .cornerRadius(8)

                                        HStack {
                                            Button {
                                                // Trigger install or show instructions
                                                Task { @MainActor in
                                                    #if os(macOS)
                                                    // Try CLI import helper
                                                    _ = try? await PCCService.shared.ensureBundledShortcutImportedIfNeeded(shortcutName: "Berd-PCC")
                                                    #else
                                                    // On iOS we cannot import silently; show share sheet instead
                                                    NotificationCenter.default.post(name: Notification.Name("BerdShowInstallShortcut"), object: nil)
                                                    #endif
                                                }
                                            } label: {
                                                Text("Install Shortcut")
                                            }
                                            .buttonStyle(.borderedProminent)

                                            Button {
                                                // Show quick instructions via a notification for the app to present
                                                NotificationCenter.default.post(name: Notification.Name("BerdShowShortcutInstructions"), object: nil)
                                            } label: {
                                                Text("How it works")
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label("On-Device AI", systemImage: "cpu")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                        
                                        Text("Using on-device Apple Intelligence for fast, private responses.")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                    .padding()
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                
                                Divider()
                                    .background(Color.white.opacity(0.2))
                                    .padding(.vertical, 8)
                                
                                // Gemini API Key Section
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Uncensored AI Fallback")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                    
                                    Text("When Apple Intelligence blocks a response, you can optionally regenerate using Google Gemini 2.5 Flash. This requires an API key from Google AI Studio.")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Gemini API Key")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.7))
                                        
                                        SecureField("Enter your Gemini API key", text: $geminiAPIKey)
                                            .textFieldStyle(.plain)
                                            .foregroundColor(.white)
                                            .padding(12)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                            )
                                        
                                        if !geminiAPIKey.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                    .font(.caption)
                                                Text("API key saved")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                            }
                                        }
                                        
                                        Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "key.fill")
                                                    .font(.caption)
                                                Text("Get API key from Google AI Studio")
                                                    .font(.caption)
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.caption2)
                                            }
                                            .foregroundColor(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(8)
                                }
                                
                                Divider()
                                    .background(Color.white.opacity(0.2))
                                    .padding(.vertical, 8)
                                
                                Text("Apple Intelligence Status: \\(AIAvailability.statusMessage)")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                
                                Text(usePCC ? "Model: Private Cloud Compute" : "Model: SystemLanguageModel.default")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                    .tag(2)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Message Bubble View
struct MessageBubbleView: View {
    let message: AIChatMessage
    let isGenerating: Bool
    let sources: [PerplexitySource]
    @EnvironmentObject var model: ChatViewModel
    
    var body: some View {
        HStack(alignment: .top) {
            if message.sender == .ai { Spacer(minLength: 40) }
            
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 8) {
                // Message content
                if model.regeneratingMessageID == message.id {
                    // Fancy skeleton / streaming placeholder while regenerating
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
                                .frame(height: 18)
                                .shimmer()
                        }
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
                            .frame(height: 14)
                            .shimmer()
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if message.text.isEmpty && isGenerating {
                    // Show generating indicator
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                            .tint(.white.opacity(0.7))
                        Text("Generating...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    MarkdownText(message.text)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(message.sender == .user ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                // Inline censorship banner and actions
                if message.sender == .ai && (message.wasCensored ?? false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Response blocked by Apple Intelligence")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Web results are shown below. You can regenerate with Gemini for an alternative answer.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            Spacer()
                        }
                        
                        HStack(spacing: 8) {
                            Button {
                                // Just dismiss inline banner and keep web results visible
                                if let idx = model.messages.firstIndex(where: { $0.id == message.id }) {
                                    model.messages[idx].wasCensored = false
                                }
                            } label: {
                                Text("View Web Results")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            if !model.geminiAPIKey.isEmpty {
                                Button {
                                    model.regenerateWithGemini(for: message.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "sparkles")
                                        Text("Regenerate")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.yellow.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
                }

                // Show sources if available (for AI messages only)
                if message.sender == .ai && !sources.isEmpty && model.usePerplexitySearch {
                    ProductionSourcesView(sources: sources)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            
            if message.sender == .user { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Production Sources View
struct ProductionSourcesView: View {
    let sources: [PerplexitySource]
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact header with source count
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            
            // Expanded sources list
            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.blue)
                                    .frame(width: 20, height: 20)
                                    .background(Color.blue.opacity(0.2))
                                    .clipShape(Circle())
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                    
                                    if let snippet = source.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.7))
                                            .lineLimit(2)
                                    }
                                    
                                    if let url = URL(string: source.url) {
                                        Link(destination: url) {
                                            HStack(spacing: 4) {
                                                Text(url.host ?? source.url)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.blue.opacity(0.8))
                                                    .lineLimit(1)
                                                Image(systemName: "arrow.up.forward")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(.blue.opacity(0.6))
                                            }
                                        }
                                    }
                                }
                            }
                            
                            if index < sources.count - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                        .padding(8)
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Markdown Text View
struct MarkdownText: View {
    let text: String
    
    var body: some View {
        if let attributedString = try? AttributedString(markdown: text) {
            Text(attributedString)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
    
    init(_ text: String) {
        self.text = text
    }
}

// MARK: - Shimmer Modifier
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let gradient = LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02), Color.white.opacity(0.06)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    Rectangle()
                        .fill(gradient)
                        .rotationEffect(.degrees(20))
                        .offset(x: -geo.size.width * 1.5 + phase * geo.size.width * 3)
                }
                .clipped()
                .blendMode(.overlay)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(Shimmer())
    }
}

#Preview {
    NavigationStack {
        ChatView()
    }
}
