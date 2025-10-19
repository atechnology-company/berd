import Foundation

// MARK: - Gemini Service
/// Service for interacting with Google's Gemini 2.5 Flash API
/// Used as a fallback when Apple Intelligence censors responses
public actor GeminiService {
    public static let shared = GeminiService()
    private init() {}
    
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    
    /// Gemini API errors
    public enum GeminiError: LocalizedError {
        case invalidAPIKey
        case networkError(String)
        case apiError(String)
        case emptyResponse
        
        public var errorDescription: String? {
            switch self {
            case .invalidAPIKey:
                return "Invalid Gemini API key. Please check your key in Settings."
            case .networkError(let message):
                return "Network error: \(message)"
            case .apiError(let message):
                return "Gemini API error: \(message)"
            case .emptyResponse:
                return "Received empty response from Gemini."
            }
        }
    }
    
    /// Generate a response using Gemini 2.5 Flash
    ///
    /// - Parameters:
    ///   - prompt: The user's question or prompt
    ///   - context: Optional context (e.g., search results)
    ///   - apiKey: Gemini API key
    /// - Returns: The AI's response text
    /// - Throws: GeminiError if the request fails
    public func generate(prompt: String, context: String? = nil, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GeminiError.invalidAPIKey
        }
        
        // Construct the full prompt
        var fullPrompt = prompt
        if let context = context, !context.isEmpty {
            fullPrompt = "\(context)\n\nBased on the above information, \(prompt)"
        }
        
        // Construct URL with API key
        guard var urlComponents = URLComponents(string: endpoint) else {
            throw GeminiError.networkError("Invalid endpoint URL")
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = urlComponents.url else {
            throw GeminiError.networkError("Failed to construct URL")
        }
        
        // Construct request body
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": fullPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 1.0,
                "topK": 40,
                "topP": 0.95,
                "maxOutputTokens": 8192
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw GeminiError.networkError("Failed to serialize request")
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorText = String(data: data, encoding: .utf8) {
                throw GeminiError.apiError("Status \(httpResponse.statusCode): \(errorText)")
            }
            throw GeminiError.apiError("Status \(httpResponse.statusCode)")
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw GeminiError.emptyResponse
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
