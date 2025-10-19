import Foundation
import AppIntents
import FoundationModels

// MARK: - App Intent for Private Cloud Compute

/// App Intent for querying Apple's Private Cloud Compute AI
/// This intent can be invoked via Siri, Shortcuts, or programmatically
@available(macOS 26.0, iOS 18.0, *)
struct PCCQueryIntent: AppIntent {
    static var title: LocalizedStringResource = "Query with Private Cloud Compute"
    static var description = IntentDescription("Send a query to Apple's Private Cloud Compute AI")
    
    @Parameter(title: "Query", description: "The question or prompt to send to the AI")
    var query: String
    
    static var parameterSummary: some ParameterSummary {
        Summary("Query AI with \(\.$query)")
    }
    
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Use LanguageModelSession with system-configured PCC settings
        let session = LanguageModelSession()
        
        // Note: PCC routing is controlled by system settings (Settings → Apple Intelligence)
        // The app cannot force PCC usage; it's determined by the system
        let response = try await session.generateResponse(
            prompt: query,
            context: nil
        )
        
        return .result(value: response)
    }
}

/// App Shortcuts Provider for Berd
/// Exposes AI query capabilities to Siri and the Shortcuts app
@available(macOS 26.0, iOS 18.0, *)
struct BerdAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PCCQueryIntent(),
            phrases: [
                "Query \(.applicationName)",
                "Ask \(.applicationName)",
                "Send query to \(.applicationName)"
            ],
            shortTitle: "Query AI",
            systemImageName: "brain.head.profile"
        )
    }
}

// MARK: - PCC Service

/// Production-ready service for interacting with Apple's Private Cloud Compute
/// 
/// This service provides three methods for PCC interaction:
/// 1. **App Intents path** (preferred): Uses LanguageModelSession directly
/// 2. **iCloud file handshake**: Writes/reads files in ubiquity container for cross-platform reliability
/// 3. **macOS CLI fallback**: Uses /usr/bin/shortcuts when other methods fail
///
/// ## Usage
/// ```swift
/// // Standard query (uses App Intents)
/// let response = try await PCCService.shared.query("What is the weather?")
///
/// // File-based handshake (for large prompts or iOS compatibility)
/// let response = try await PCCService.shared.runShortcutWithFileHandshake(
///     prompt: largePrompt,
///     shortcutName: "Berd-PCC"
/// )
/// ```
@available(macOS 26.0, iOS 18.0, *)
actor PCCService {
    static let shared = PCCService()
    
    /// Errors that can occur during PCC operations
    enum PCCError: LocalizedError {
        case modelNotAvailable
        case queryFailed(String)
        case responseEmpty
        case iCloudNotAvailable
        case shortcutsNotInstalled
        
        var errorDescription: String? {
            switch self {
            case .modelNotAvailable:
                return "Private Cloud Compute is not available on this device. Please check Settings → Apple Intelligence."
            case .queryFailed(let message):
                return "Query failed: \(message)"
            case .responseEmpty:
                return "Received an empty response from the AI model."
            case .iCloudNotAvailable:
                return "iCloud Drive is not available. Enable it in Settings to use file-based handshake."
            case .shortcutsNotInstalled:
                return "The required Shortcut is not installed. Please install it from Settings."
            }
        }
    }
    
    private init() {}
    
    /// Send a query to Private Cloud Compute and receive a response
    ///
    /// This method uses the following fallback chain:
    /// 1. Try LanguageModelSession (App Intents) - fastest and most reliable
    /// 2. Fall back to Shortcuts CLI on macOS if available
    ///
    /// - Parameter prompt: The user's question or prompt
    /// - Returns: The AI's response text
    /// - Throws: PCCError if all methods fail
    func query(_ prompt: String) async throws -> String {
        guard !prompt.isEmpty else {
            throw PCCError.queryFailed("Empty prompt")
        }
        
        // First try the normal API path (LanguageModelSession). If that fails
        // or PCC isn't available, fall back to importing+running a bundled
        // Shortcuts bundle via the `/usr/bin/shortcuts` CLI.
        do {
            let session = LanguageModelSession()
            let response = try await session.generateResponse(
                prompt: prompt,
                context: nil
            )

            if !response.isEmpty {
                return response
            }
        } catch {
            // Log and continue to CLI fallback
            print("PCCService: LanguageModelSession failed: \(error.localizedDescription). Trying CLI fallback...")
        }

        // CLI fallback: require shortcuts binary
        guard isShortcutsCLIAvailable() else {
            throw PCCError.queryFailed("LanguageModelSession failed and Shortcuts CLI is not available")
        }

        // Ensure the bundled shortcut is imported into the Shortcuts library
        do {
            try await ensureBundledShortcutImportedIfNeeded(shortcutName: "Berd-PCC")
        } catch {
            print("PCCService: failed to import bundled shortcut: \(error)")
            // Continue — attempt to run even if import failed
        }

        // Run the shortcuts CLI with the prompt and capture output
        let cliOutput = try runShortcutsCLI(prompt: prompt, shortcutName: "Berd-PCC")
        if cliOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PCCError.responseEmpty
        }
        return cliOutput
    }
    
    /// Check if PCC is available on this system
    func isAvailable() async -> Bool {
        // Check if FoundationModels framework is available
        if #available(macOS 26.0, iOS 18.0, *) {
            return true
        }
        return false
    }

    // MARK: - Shortcuts CLI Helpers (macOS only)

    /// Check if the Shortcuts CLI is available on this system
    /// - Returns: true if /usr/bin/shortcuts exists, false otherwise
    private func isShortcutsCLIAvailable() -> Bool {
        let path = "/usr/bin/shortcuts"
        return FileManager.default.fileExists(atPath: path)
    }

    /// Ensure the bundled shortcut is imported into the user's Shortcuts library
    ///
    /// This method:
    /// 1. Lists all installed shortcuts
    /// 2. Checks if the target shortcut already exists
    /// 3. Locates the bundled .shortcut in app resources
    /// 4. Imports it if not found
    ///
    /// - Parameter shortcutName: Name of the shortcut to import
    /// - Throws: PCCError if import fails or shortcut not found in bundle
    func ensureBundledShortcutImportedIfNeeded(shortcutName: String) async throws {
#if os(macOS)
        // Ask the Shortcuts CLI what shortcuts exist
        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        listProcess.arguments = ["list"]
        let outPipe = Pipe()
        listProcess.standardOutput = outPipe
        listProcess.standardError = Pipe()
        try listProcess.run()
        listProcess.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if out.contains(shortcutName) {
            return
        }

        // Not found: try to locate the bundled shortcut in the app resources
        guard let bundled = findBundledShortcutURL(named: shortcutName) else {
            throw PCCError.queryFailed("Bundled shortcut \(shortcutName) not found in app resources")
        }

        // Import it
        let importProcess = Process()
        importProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        importProcess.arguments = ["import", bundled.path, "--name", shortcutName]
        let errPipe = Pipe()
        importProcess.standardError = errPipe
        try importProcess.run()
        importProcess.waitUntilExit()
        if importProcess.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "import failed"
            throw PCCError.queryFailed("shortcuts import failed: \(msg)")
        }
#else
        throw PCCError.queryFailed("Shortcuts CLI import is only available on macOS")
#endif
    }

    /// Find the bundled .shortcut directory in the app's resources
    ///
    /// - Parameter name: Shortcut name (without .shortcut extension)
    /// - Returns: URL to the .shortcut bundle, or nil if not found
    private func findBundledShortcutURL(named name: String) -> URL? {
        // Search bundle resource directory for a folder "<name>.shortcut"
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: resourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent == "\(name).shortcut" {
                return file
            }
        }
        return nil
    }

    /// Run a shortcut via CLI with input text and capture output to file
    ///
    /// - Parameters:
    ///   - prompt: The input text to pass to the shortcut
    ///   - shortcutName: Name of the shortcut to run
    /// - Returns: The output text from the shortcut
    /// - Throws: PCCError if CLI execution fails
    private func runShortcutsCLI(prompt: String, shortcutName: String) throws -> String {
#if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("pcc-output-\(UUID().uuidString).txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName, "-i", prompt, "-o", outURL.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "shortcuts run failed"
            throw PCCError.queryFailed(err)
        }

        guard FileManager.default.fileExists(atPath: outURL.path),
              let result = try? String(contentsOf: outURL, encoding: .utf8) else {
            throw PCCError.responseEmpty
        }
        try? FileManager.default.removeItem(at: outURL)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
#else
        throw PCCError.queryFailed("Shortcuts CLI is not available on this platform")
#endif
    }

    // MARK: - File-based handshake (Production-ready)

    /// Execute a PCC query using iCloud file handshake for reliability
    ///
    /// This method is ideal for:
    /// - Large prompts that exceed URL length limits
    /// - Cross-platform compatibility (iOS + macOS)
    /// - Scenarios where shortcuts need persistent file access
    ///
    /// **How it works:**
    /// 1. Writes prompt to iCloud Documents/BerdPCC folder
    /// 2. Posts notification for shortcuts to detect new input
    /// 3. Polls for output file with 60-second timeout
    /// 4. Returns result and cleans up temp files
    ///
    /// **Requirements:**
    /// - iCloud Drive enabled
    /// - Berd-PCC shortcut installed in Shortcuts app
    /// - App must have iCloud ubiquity container entitlement
    ///
    /// - Parameters:
    ///   - prompt: The user's question or prompt
    ///   - shortcutName: Name of the shortcut to invoke (default: "Berd-PCC")
    /// - Returns: The AI's response text
    /// - Throws: PCCError if iCloud unavailable, timeout occurs, or CLI fallback fails
    func runShortcutWithFileHandshake(prompt: String, shortcutName: String) async throws -> String {
        // Prefer iCloud ubiquity document handshake when available
        if let ubiquityRoot = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            // Create an app-specific directory under Documents
            let docs = ubiquityRoot.appendingPathComponent("Documents/BerdPCC", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

            let inURL = docs.appendingPathComponent("pcc-input-\(UUID().uuidString).txt")
            let outURL = docs.appendingPathComponent("pcc-output-\(UUID().uuidString).txt")

            // Write prompt to iCloud file
            try prompt.write(to: inURL, atomically: true, encoding: .utf8)

            // Notify observers that a new input file is ready
            // Shortcuts can watch this notification or poll the folder
            NotificationCenter.default.post(
                name: Notification.Name("BerdPCCInputFileWritten"),
                object: nil,
                userInfo: ["inputURL": inURL, "outputURL": outURL]
            )

            // Poll for the output file with timeout
            let timeoutSeconds: TimeInterval = 60
            let checkInterval: UInt64 = 500_000_000 // 0.5s
            var elapsed: TimeInterval = 0
            
            while elapsed < timeoutSeconds {
                if FileManager.default.fileExists(atPath: outURL.path) {
                    let result = try String(contentsOf: outURL, encoding: .utf8)
                    
                    // Clean up temp files
                    try? FileManager.default.removeItem(at: inURL)
                    try? FileManager.default.removeItem(at: outURL)
                    
                    if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw PCCError.responseEmpty
                    }
                    
                    return result.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try await Task.sleep(nanoseconds: checkInterval)
                elapsed += Double(checkInterval) / 1_000_000_000.0
            }

            // Timeout occurred - clean up input file
            try? FileManager.default.removeItem(at: inURL)
            throw PCCError.queryFailed("Timed out waiting for Shortcut result. Please ensure the '\(shortcutName)' shortcut is installed and running.")
        }

        // If iCloud not available, fallback to macOS Shortcuts CLI if available
        #if os(macOS)
        if isShortcutsCLIAvailable() {
            return try runShortcutsCLI(prompt: prompt, shortcutName: shortcutName)
        }
        throw PCCError.iCloudNotAvailable
        #else
        throw PCCError.iCloudNotAvailable
        #endif
    }
}

// MARK: - LanguageModelSession Extension

/// Extension to LanguageModelSession for PCC response generation
///
/// This extension provides a simplified interface for generating responses
/// and handles the complex reflection-based extraction of response text from
/// the opaque response object returned by the system.
@available(macOS 26.0, iOS 18.0, *)
extension LanguageModelSession {
    /// Generate a response from the language model using PCC when available
    ///
    /// **Important:** PCC routing is determined by system settings, not this API.
    /// Check Settings → Apple Intelligence → Compute Environment to configure PCC.
    ///
    /// - Parameters:
    ///   - prompt: The user's question or prompt
    ///   - context: Optional context to prepend to the prompt
    /// - Returns: The AI's response text
    /// - Throws: Any error from the underlying model session
    func generateResponse(prompt: String, context: String?) async throws -> String {
        var fullPrompt = prompt
        if let context = context {
            fullPrompt = "\(context)\n\n\(prompt)"
        }
        
        // Create a temporary storage for the response
        var responseText = ""
        
        // Use the system language model
        // Note: PCC preference is controlled by system settings, not API
        do {
            let response = try await self.respond(to: fullPrompt)
            
            // Extract text using mirror inspection (same pattern as AIChatService)
            func extractText(_ any: Any, depth: Int = 0) -> String? {
                if depth > 2 { return nil }
                if let s = any as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                let m = Mirror(reflecting: any)
                for child in m.children {
                    if let val = extractText(child.value, depth: depth + 1) { return val }
                }
                return nil
            }
            
            let mirror = Mirror(reflecting: response)
            
            // Try known property names
            for candidate in ["text", "value", "output", "result", "content"] {
                if let v = mirror.children.first(where: { $0.label == candidate })?.value as? String, !v.isEmpty {
                    return v
                }
            }
            
            // Try deep scan
            if let deep = extractText(response) {
                return deep
            }
            
            // Try pattern extraction from description
            var desc = String(describing: response)
            if let range = desc.range(of: "text:") {
                let tail = desc[range.upperBound...]
                if let quoteStart = tail.firstIndex(of: "\"") {
                    let afterStart = tail.index(after: quoteStart)
                    if let quoteEnd = tail[afterStart...].firstIndex(of: "\"") {
                        let extracted = String(tail[afterStart..<quoteEnd])
                        if extracted.count > 3 {
                            return extracted
                        }
                    }
                }
            }
            
            // Fallback to description
            if desc.count > 4000 { desc = String(desc.prefix(4000)) + "…" }
            return desc
            
        } catch {
            throw error
        }
    }
}
