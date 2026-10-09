import Foundation

/// One request to the helper process. The API key travels on stdin, never on the command line.
struct AIPanelWireRequest: Codable, Sendable {
    var kind: String
    var endpoint: String
    var model: String?
    var apiKey: String?
    var turns: [AITurn]?
    var tools: [AIToolSpec]?
}

/// What the helper writes before it exits. `ok` is false for a refused request; a crashed helper writes nothing.
struct AIPanelWireResponse: Codable, Sendable {
    var ok: Bool
    var error: String?
    var text: String?
    var toolCalls: [AIToolCall]?
    var reachable: Bool?
    var detail: String?
}
