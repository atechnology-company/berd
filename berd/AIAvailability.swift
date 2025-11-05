import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

import Foundation

/// Cactus model types available for local inference
public enum CactusModel {
    case gemma3_1B_Q4
    case qwen_4B_Q4
    
    public var folderName: String {
        switch self {
        case .gemma3_1B_Q4: return "gemma3-1b-q4"
        case .qwen_4B_Q4: return "qwen-4b-q4"
        }
    }
    
    public var displayName: String {
        switch self {
        case .gemma3_1B_Q4: return "Gemma 3 1B (Q4)"
        case .qwen_4B_Q4: return "Qwen 4B (Q4)"
        }
    }
}

/// Convenience helpers for checking that the Cactus runtime is installed correctly.
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
