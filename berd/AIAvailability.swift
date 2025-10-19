import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Utility to check Apple Intelligence availability
public struct AIAvailability {
    public static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 18.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
    
    public static var statusMessage: String {
        #if canImport(FoundationModels)
        if #available(iOS 18.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable ? "Ready" : "Model not available"
        }
        return "Requires macOS 26+ / iOS 18+"
        #else
        return "Framework not available"
        #endif
    }
}
