import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
// Temporarily disable VisualIntelligence import due to API incompatibility
// #if canImport(VisualIntelligence)
// import VisualIntelligence
// #endif

// MARK: - Visual Intelligence Helper
@available(iOS 18.0, macOS 15.0, *)
public actor VisualIntelligenceHelper {
    
    public enum VIError: Error {
        case notAvailable
        case noImageSelected
        case analysisFailed(String)
    }
    
    public init() {}
    
    #if canImport(VisualIntelligence) && false // Temporarily disabled due to API incompatibility
    /// Start Visual Intelligence interaction
    @MainActor
    public func startVisualIntelligence(from viewController: Any? = nil) async throws -> String {
        // Check if Visual Intelligence is available
        guard VisualIntelligence.isAvailable else {
            throw VIError.notAvailable
        }
        
        // Create interaction
        let interaction = VisualIntelligence.Interaction()
        
        // Present Visual Intelligence interface
        // This will allow the user to select an image/document or use camera
        try await interaction.present(from: viewController)
        
        // Get the analysis result
        if let result = interaction.result {
            return formatVisualIntelligenceResult(result)
        }
        
        throw VIError.noImageSelected
    }
    
    private func formatVisualIntelligenceResult(_ result: Any) -> String {
        // Since VisualIntelligence.Result type is not available, we'll return a generic message
        // This can be updated when the proper API is available
        return "Visual Intelligence analysis completed. (Detailed result formatting not yet implemented)"
    }
    #else
    @MainActor
    public func startVisualIntelligence(from viewController: Any? = nil) async throws -> String {
        throw VIError.notAvailable
    }
    #endif
    
    /// Fallback: Present document picker for manual selection
    @MainActor
    public func presentDocumentPicker() async throws -> Data? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf, .text]
        
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            return try Data(contentsOf: url)
        }
        return nil
        #elseif os(iOS)
        // On iOS, we'd use UIDocumentPickerViewController
        // For now, return nil as a placeholder
        return nil
        #else
        return nil
        #endif
    }
}

// MARK: - Visual Intelligence Result (Placeholder structure)
#if !canImport(VisualIntelligence)
@available(iOS 18.0, macOS 15.0, *)
public enum VisualIntelligence {
    public static var isAvailable: Bool { false }
    
    public class Interaction {
        public var result: Any?
        
        public init() {}
        
        @MainActor
        public func present(from: Any?) async throws {
            throw VisualIntelligenceHelper.VIError.notAvailable
        }
    }
    
    // Note: Actual Result type not available in current SDK
    // This is a placeholder for when the API becomes available
}
#endif
