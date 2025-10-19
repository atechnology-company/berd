import Foundation

// MARK: - Perplexity Source Model
public struct PerplexitySource: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let url: String
    public let snippet: String?
    
    public init(id: String = UUID().uuidString, title: String, url: String, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - Perplexity API Models
public struct PerplexitySearchRequest: Codable, Sendable {
    let query: String
    let max_results: Int
    let max_tokens_per_page: Int
    
    init(query: String, maxResults: Int = 5, maxTokensPerPage: Int = 1024) {
        self.query = query
        self.max_results = maxResults
        self.max_tokens_per_page = maxTokensPerPage
    }
}

public struct PerplexitySearchResponse: Codable, Sendable {
    let id: String
    let results: [SearchResult]
    let max_results: Int?
    let max_tokens_per_page: Int?
    
    public struct SearchResult: Codable, Sendable {
        let title: String
        let url: String
        let snippet: String
        let score: Double?
        let date: String?
    }
}

// MARK: - Perplexity Service
public actor PerplexityService {
    public static let shared = PerplexityService()
    private init() {}
    
    private let searchEndpoint = "https://api.perplexity.ai/search"
    
    public func search(
        query: String,
        apiKey: String,
        maxResults: Int = 5
    ) async throws -> [PerplexitySource] {
        guard !apiKey.isEmpty else {
            throw PerplexityError.missingAPIKey
        }
        
        // Create request
        let requestBody = PerplexitySearchRequest(
            query: query,
            maxResults: maxResults,
            maxTokensPerPage: 1024
        )
        
        guard let url = URL(string: searchEndpoint) else {
            throw PerplexityError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30
        
        // Make request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerplexityError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw PerplexityError.invalidAPIKey
            }
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PerplexityError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        let searchResponse = try JSONDecoder().decode(PerplexitySearchResponse.self, from: data)
        
        // Convert to PerplexitySource
        return searchResponse.results.map { result in
            PerplexitySource(
                id: UUID().uuidString,
                title: result.title,
                url: result.url,
                snippet: result.snippet
            )
        }
    }
    
    public func fetchPageContent(url: String) async throws -> String {
        guard let pageURL = URL(string: url) else {
            throw PerplexityError.invalidURL
        }
        
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PerplexityError.fetchFailed
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw PerplexityError.decodingFailed
        }
        
        // Basic HTML stripping - extract text content
        return stripHTML(content)
    }
    
    nonisolated public func createAugmentedPrompt(
        originalQuery: String,
        sources: [PerplexitySource],
        fetchedContent: [String: String] = [:]
    ) -> String {
        var augmentedPrompt = originalQuery + "\n\n"
        augmentedPrompt += "---\n"
        augmentedPrompt += "CONTEXT FROM WEB SEARCH:\n\n"
        
        for (index, source) in sources.enumerated() {
            augmentedPrompt += "[\(index + 1)] \(source.title)\n"
            augmentedPrompt += "URL: \(source.url)\n"
            
            if let content = fetchedContent[source.url] {
                let truncated = String(content.prefix(800))
                augmentedPrompt += "Content: \(truncated)\n"
            } else if let snippet = source.snippet {
                augmentedPrompt += "Snippet: \(snippet)\n"
            }
            
            augmentedPrompt += "\n"
        }
        
        augmentedPrompt += "---\n\n"
        augmentedPrompt += "Please provide a comprehensive answer using the above sources. Include relevant citations using [1], [2], etc."
        
        return augmentedPrompt
    }
    
    private func stripHTML(_ html: String) -> String {
        // Remove script and style tags with their content
        var cleaned = html
        let scriptPattern = "<script[^>]*>[\\s\\S]*?</script>"
        let stylePattern = "<style[^>]*>[\\s\\S]*?</style>"
        
        if let scriptRegex = try? NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive) {
            cleaned = scriptRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        
        if let styleRegex = try? NSRegularExpression(pattern: stylePattern, options: .caseInsensitive) {
            cleaned = styleRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        
        // Remove all HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            cleaned = tagRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        
        // Decode HTML entities
        cleaned = cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        
        // Clean up whitespace
        let lines = cleaned.components(separatedBy: .newlines)
        let nonEmptyLines = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        return nonEmptyLines.joined(separator: "\n")
    }
}

// MARK: - Errors
public enum PerplexityError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case fetchFailed
    case decodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Perplexity API key is required. Please add it in Settings."
        case .invalidAPIKey:
            return "Invalid Perplexity API key. Please check your key in Settings."
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .fetchFailed:
            return "Failed to fetch webpage content"
        case .decodingFailed:
            return "Failed to decode content"
        }
    }
}
