import Foundation

// MARK: - Supporting Types
private class GenerationContext {
    weak var service: LocalModelService?
    var appendToken: (String) -> Void
    
    init(service: LocalModelService, appendToken: @escaping (String) -> Void) {
        self.service = service
        self.appendToken = appendToken
    }
}

public struct ChatMessage: Codable {
    public let role: String
    public let content: String
    
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Error Types
public enum LocalModelError: LocalizedError {
    case modelNotLoaded
    case initializationFailed(String)
    case generationFailed(String)
    case searchFailed(String)
    case invalidModelPath
    
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded. Please load a model first."
        case .initializationFailed(let message):
            return "Failed to initialize model: \(message)"
        case .generationFailed(let message):
            return "Text generation failed: \(message)"
        case .searchFailed(let message):
            return "Search failed: \(message)"
        case .invalidModelPath:
            return "Invalid model file path"
        }
    }
}

// MARK: - Model Configuration
public enum LocalModel: String, CaseIterable, Identifiable {
    case gemma3_1b_q4 = "gemma-3-1b-q4"
    case qwen_4b_q4 = "qwen-4b-q4"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .gemma3_1b_q4: return "Gemma 3 1B (Q4)"
        case .qwen_4b_q4: return "Qwen 4B (Q4)"
        }
    }
    
    public var modelPath: String {
        switch self {
        case .gemma3_1b_q4: return "gemma-3-1b-q4"
        case .qwen_4b_q4: return "qwen-4b-q4"
        }
    }
    
    public var coreType: berdcore_model_type_t {
        switch self {
        case .gemma3_1b_q4: return BERDCORE_MODEL_GEMMA3_1B_Q4
        case .qwen_4b_q4: return BERDCORE_MODEL_QWEN_4B_Q4
        }
    }
    
    public var description: String {
        switch self {
        case .gemma3_1b_q4: return "Fast and efficient 1B model via Cactus"
        case .qwen_4b_q4: return "Powerful 4B model with better reasoning via Cactus"
        }
    }
}

// MARK: - Service Implementation
@Observable
public class LocalModelService {
    // MARK: - Singleton
    public static let shared = LocalModelService()
    
    // MARK: - Properties
    private var model: berdcore_model_t?
    private var currentModel: LocalModel?
    
    public var currentModelName: String? {
        return currentModel?.displayName
    }
    
    // Callbacks
    public var onProgress: ((Float, String) -> Void)?
    public var onToken: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    
    // MARK: - Initialization
    private init() {}
    
    deinit {
        unloadModel()
    }
    
    // MARK: - Model Management
    public func loadModel(_ model: LocalModel, onProgress: ((Float) -> Void)? = nil) async throws {
        #if os(macOS)
        // Unload existing model first
        unloadModel()
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Progress callback wrapper (C API: void progress(float, void*))
            let progressCallback: @convention(c) (Float, UnsafeMutableRawPointer?) -> Void = { progress, userdata in
                guard let userdata = userdata else { return }
                let service = Unmanaged<LocalModelService>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onProgress?(progress, "")
                }
            }

            // Initialize model on background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: LocalModelError.modelNotLoaded)
                    return
                }

                let userdata = Unmanaged.passUnretained(self).toOpaque()

                // Call C API: berdcore_init_model(model_type, model_path, context_size, progress_callback, user_data)
                let result: berdcore_model_t = model.modelPath.withCString { cstr in
                    return berdcore_init_model(model.coreType, cstr, 8192, progressCallback, userdata)
                }

                if result != nil {
                    DispatchQueue.main.async {
                        self.model = result
                        self.currentModel = model
                        continuation.resume()
                    }
                } else {
                    let errPtr = berdcore_get_last_error()
                    let error = errPtr != nil ? String(cString: errPtr!) : "Unknown error"
                    continuation.resume(throwing: LocalModelError.initializationFailed(error))
                }
            }
        }
        #else
        throw LocalModelError.initializationFailed("Local models are not available on iOS")
        #endif
    }
    
    public func unloadModel() {
        #if os(macOS)
        if let model = model {
            berdcore_free_model(model)
            self.model = nil
            self.currentModel = nil
        }
        #else
        self.model = nil
        self.currentModel = nil
        #endif
    }
    
    // MARK: - Text Generation
    public func generate(
        prompt: String,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        topK: Int32 = 40,
        maxTokens: Int32 = 2048
    ) async throws -> String {
        #if os(macOS)
        guard let model = model else {
            throw LocalModelError.modelNotLoaded
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            generateInternal(prompt: prompt, temperature: temperature, topP: topP, topK: topK, maxTokens: maxTokens) { result in
                continuation.resume(with: result)
            }
        }
        #else
        throw LocalModelError.generationFailed("Local models are not available on iOS")
        #endif
    }
    
    private func generateInternal(
        prompt: String,
        temperature: Float,
        topP: Float,
        topK: Int32,
        maxTokens: Int32,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if os(macOS)
        guard self.model != nil else {
            completion(.failure(LocalModelError.modelNotLoaded))
            return
        }
        
        var fullResponse = ""
        var hasResumed = false
        
        // Token callback wrapper
        let tokenCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { (token: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) in
            guard let token = token, let userdata = userdata else { return }
            
            let context = Unmanaged<GenerationContext>.fromOpaque(userdata).takeUnretainedValue()
            let tokenStr = String(cString: token)
            
            context.appendToken(tokenStr)
            
            DispatchQueue.main.async {
                context.service?.onToken?(tokenStr)
            }
        }
        
        // Create context for callbacks
        let context = GenerationContext(service: self, appendToken: { token in
            fullResponse += token
        })
        let userdata = Unmanaged.passRetained(context).toOpaque()
        
        // Prepare inference options
        var options = berdcore_inference_options_t()
        options.temperature = temperature
        options.top_p = topP
        options.top_k = Int32(topK)
        options.max_tokens = Int32(maxTokens)
        options.stop_sequences = nil
        
        // Run generation on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.performGeneration(prompt: prompt, temperature: temperature, topP: topP, topK: topK, maxTokens: maxTokens, completion: completion)
        }
        #else
        completion(.failure(LocalModelError.generationFailed("Local models are not available on iOS")))
        #endif
    }
    
    // MARK: - Chat Generation (with conversation history)
    public func chat(
        messages: [ChatMessage],
        temperature: Float = 0.7,
        topP: Float = 0.9,
        topK: Int32 = 40,
        maxTokens: Int32 = 2048
    ) async -> String {
        #if os(macOS)
        guard model != nil else {
            return ""
        }
        
        // Convert messages to JSON format
        guard let messagesJSON = try? messagesToJSON(messages) else {
            return ""
        }
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            chatInternal(messagesJSON: messagesJSON, temperature: temperature, topP: topP, topK: topK, maxTokens: maxTokens) { result in
                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure:
                    continuation.resume(returning: "") // Return empty on error for non-throwing method
                }
            }
        }
        #else
        return ""
        #endif
    }
    
    private func chatInternal(
        messagesJSON: String,
        temperature: Float,
        topP: Float,
        topK: Int32,
        maxTokens: Int32,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if os(macOS)
        guard self.model != nil else {
            completion(.failure(LocalModelError.modelNotLoaded))
            return
        }
        
        var fullResponse = ""
        var hasResumed = false
        
        // Token callback wrapper
        let tokenCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { (token: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) in
            guard let token = token, let userdata = userdata else { return }
            
            let context = Unmanaged<GenerationContext>.fromOpaque(userdata).takeUnretainedValue()
            let tokenStr = String(cString: token)
            
            context.appendToken(tokenStr)
            
            DispatchQueue.main.async {
                context.service?.onToken?(tokenStr)
            }
        }
        
        // Create context for callbacks
        let context = GenerationContext(service: self, appendToken: { token in
            fullResponse += token
        })
        let userdata = Unmanaged.passRetained(context).toOpaque()
        
        // Prepare inference options
        var options = berdcore_inference_options_t()
        options.temperature = temperature
        options.top_p = topP
        options.top_k = Int32(topK)
        options.max_tokens = Int32(maxTokens)
        options.stop_sequences = nil

        // Run chat generation on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.performChatGeneration(messagesJSON: messagesJSON, temperature: temperature, topP: topP, topK: topK, maxTokens: maxTokens, completion: completion)
        }
        #else
        completion(.failure(LocalModelError.generationFailed("Local models are not available on iOS")))
        #endif
    }
    
    // MARK: - Web Search
    public func search(query: String, maxResults: Int32 = 5) async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                query.withCString { queryPtr in
                    // Note: This requires a Perplexity API key - for now return an error
                    // since the app uses PerplexityService directly for search.
                    // If you want to use berdcore for search, you'll need to add API key storage.
                    continuation.resume(throwing: LocalModelError.searchFailed("Search via berdcore requires Perplexity API key configuration"))
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func messagesToJSON(_ messages: [ChatMessage]) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(messages.map { ["role": $0.role, "content": $0.content] })
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    private func performGeneration(
        prompt: String,
        temperature: Float,
        topP: Float,
        topK: Int32,
        maxTokens: Int32,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if os(macOS)
        guard let model = self.model else {
            completion(.failure(LocalModelError.modelNotLoaded))
            return
        }
        
        var fullResponse = ""
        var hasResumed = false
        
        // Token callback wrapper
        let tokenCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { (token: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) in
            guard let token = token, let userdata = userdata else { return }
            
            let context = Unmanaged<GenerationContext>.fromOpaque(userdata).takeUnretainedValue()
            let tokenStr = String(cString: token)
            
            context.appendToken(tokenStr)
            
            DispatchQueue.main.async {
                context.service?.onToken?(tokenStr)
            }
        }
        
        // Create context for callbacks
        let context = GenerationContext(service: self, appendToken: { token in
            fullResponse += token
        })
        let userdata = Unmanaged.passRetained(context).toOpaque()
        
        // Prepare inference options
        var options = berdcore_inference_options_t()
        options.temperature = temperature
        options.top_p = topP
        options.top_k = Int32(topK)
        options.max_tokens = Int32(maxTokens)
        options.stop_sequences = nil
        
        // Call C API with C string prompt
        let result: berdcore_error_t = prompt.withCString { cstr in
            return berdcore_generate(model, cstr, &options, tokenCallback, userdata)
        }
        
        // Clean up context
        Unmanaged<GenerationContext>.fromOpaque(userdata).release()

        DispatchQueue.main.async {
            if result == BERDCORE_SUCCESS {
                if !hasResumed {
                    hasResumed = true
                    completion(.success(fullResponse))
                }
            } else {
                let errPtr = berdcore_get_last_error()
                let error = errPtr != nil ? String(cString: errPtr!) : "Unknown error"
                if !hasResumed {
                    hasResumed = true
                    completion(.failure(LocalModelError.generationFailed(error)))
                }
            }
        }
        #else
        completion(.failure(LocalModelError.generationFailed("Local models are not available on iOS")))
        #endif
    }
    
    private func performChatGeneration(
        messagesJSON: String,
        temperature: Float,
        topP: Float,
        topK: Int32,
        maxTokens: Int32,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if os(macOS)
        guard let model = self.model else {
            completion(.failure(LocalModelError.modelNotLoaded))
            return
        }
        
        var fullResponse = ""
        var hasResumed = false
        
        // Token callback wrapper
        let tokenCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { (token: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) in
            guard let token = token, let userdata = userdata else { return }
            
            let context = Unmanaged<GenerationContext>.fromOpaque(userdata).takeUnretainedValue()
            let tokenStr = String(cString: token)
            
            context.appendToken(tokenStr)
            
            DispatchQueue.main.async {
                context.service?.onToken?(tokenStr)
            }
        }
        
        // Create context for callbacks
        let context = GenerationContext(service: self, appendToken: { token in
            fullResponse += token
        })
        let userdata = Unmanaged.passRetained(context).toOpaque()
        
        // Prepare inference options
        var options = berdcore_inference_options_t()
        options.temperature = temperature
        options.top_p = topP
        options.top_k = Int32(topK)
        options.max_tokens = Int32(maxTokens)
        options.stop_sequences = nil

        // Call unified generate API with messages JSON
        let result: berdcore_error_t = messagesJSON.withCString { cstr in
            return berdcore_generate(model, cstr, &options, tokenCallback, userdata)
        }
        
        // Clean up context
        Unmanaged<GenerationContext>.fromOpaque(userdata).release()

        DispatchQueue.main.async {
            if result == BERDCORE_SUCCESS {
                if !hasResumed {
                    hasResumed = true
                    completion(.success(fullResponse))
                }
            } else {
                let errPtr = berdcore_get_last_error()
                let error = errPtr != nil ? String(cString: errPtr!) : "Unknown error"
                if !hasResumed {
                    hasResumed = true
                    completion(.failure(LocalModelError.generationFailed(error)))
                }
            }
        }
        #else
        completion(.failure(LocalModelError.generationFailed("Local models are not available on iOS")))
        #endif
    }
    
    // MARK: - Public Query Methods (for compatibility)
    public func isModelLoaded() -> Bool {
        return model != nil
    }
    
    public func getCurrentModel() -> String? {
        return currentModel?.rawValue
    }
}
