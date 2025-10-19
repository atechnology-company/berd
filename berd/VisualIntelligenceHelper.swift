import Foundation
import UniformTypeIdentifiers
#if canImport(VisualIntelligence)
import VisualIntelligence
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Visual Intelligence Helper
@available(iOS 18.0, macOS 15.0, *)
public actor VisualIntelligenceHelper {
    
    public enum VIError: Error {
        case notAvailable
        case noImageSelected
        case analysisFailed(String)
    }
    
    public init() {}
    
    #if canImport(VisualIntelligence)
    /// Start Visual Intelligence interaction
    @MainActor
    public func startVisualIntelligence(from viewController: UIViewController? = nil) async throws -> String {
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
    
    private func formatVisualIntelligenceResult(_ result: VisualIntelligence.Result) -> String {
        var output = ""
        
        // Extract text if available
        if let text = result.text, !text.isEmpty {
            output += "Text: \(text)\n\n"
        }
        
        // Extract objects if available
        if let objects = result.detectedObjects, !objects.isEmpty {
            output += "Detected Objects:\n"
            for object in objects {
                output += "- \(object.label) (\(Int(object.confidence * 100))%)\n"
            }
            output += "\n"
        }
        
        // Extract scene classification
        if let scene = result.sceneClassification {
            output += "Scene: \(scene)\n\n"
        }
        
        return output.isEmpty ? "No information extracted from image" : output
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
        public var result: Result?
        
        public init() {}
        
        @MainActor
        public func present(from: Any?) async throws {
            throw VisualIntelligenceHelper.VIError.notAvailable
        }
    }
    
    public struct Result {
        public let text: String?
        public let detectedObjects: [DetectedObject]?
        public let sceneClassification: String?
        
        public struct DetectedObject {
            public let label: String
            public let confidence: Double
        }
    }
}
#endif
