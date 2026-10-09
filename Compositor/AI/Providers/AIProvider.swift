import Foundation

/// One round of the conversation the provider sees. A picture rides in `images` as a small JPEG. The text
/// sample does not repeat that picture.
struct AITurn: Sendable, Equatable, Codable {
    enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    var role: Role
    var text: String
    var toolCallID: String?
    var toolCalls: [AIToolCall] = []
    /// JPEG bytes the model should look at. Empty for ordinary text.
    var images: [Data] = []
}

struct AIToolCall: Sendable, Equatable, Identifiable, Codable {
    var id: String
    var name: String
    var arguments: String
}

/// A tool the model is allowed to call. An empty list is omitted from the request.
struct AIToolSpec: Sendable, Equatable, Codable {
    var name: String
    var description: String
    /// A JSON Schema object.
    var parameters: String
}

struct AICompletion: Sendable, Equatable {
    var text: String?
    var toolCalls: [AIToolCall]
}

protocol AIProvider: Sendable {
    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion
}

enum AIProviderError: LocalizedError, Equatable {
    case missingKey, badURL, status(Int, String), empty, decode
    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Add an API key in Connection.")
        case .badURL: "The endpoint is not a valid URL."
        case .status(let code, let message): "The request failed (\(code)). \(message)"
        case .empty: "The model returned nothing."
        case .decode: "The response could not be read."
        }
    }
}
