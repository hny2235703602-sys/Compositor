import Foundation

/// Chat Completions against any server that speaks the OpenAI request shape. The key is held only for the
/// lifetime of this value, which the panel creates inside one send.
struct OpenAICompatibleProvider: AIProvider {
    var endpoint: String
    var model: String
    var apiKey: String

    /// How long a chat reply may take. Reasoning models often send nothing until the answer is done.
    static let replyTimeout: TimeInterval = 30 * 60

    func complete(_ turns: [AITurn], tools: [AIToolSpec]) async throws -> AICompletion {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIProviderError.missingKey }
        guard let url = Self.completionsURL(from: endpoint) else { throw AIProviderError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A reasoning model can stay silent until it finishes. This is that whole wait, not a gap between bytes.
        // Stop still cancels the call.
        request.timeoutInterval = Self.replyTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.body(model: model, turns: turns, tools: tools)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIProviderError.status(-1, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw AIProviderError.status(status, Self.failureMessage(in: data, hiding: key))
        }
        return try Self.completion(from: data)
    }

    /// `https://host/v1` and a full `…/chat/completions` URL both work. A host with no path, such as
    /// `https://zhongkey.com`, is the API root and gets `/v1` inserted. A trailing slash is ignored.
    static func completionsURL(from endpoint: String) -> URL? {
        guard let root = apiRoot(from: endpoint) else { return nil }
        return URL(string: root + "/chat/completions")
    }

    /// The `/v1` root used for both chat and the model list.
    static func apiRoot(from endpoint: String) -> String? {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if trimmed.hasSuffix("chat/completions") {
            trimmed = String(trimmed.dropLast("chat/completions".count))
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
        } else if trimmed.hasSuffix("/models") {
            trimmed = String(trimmed.dropLast("/models".count))
        }
        guard let resolved = URL(string: trimmed) else { return nil }
        if resolved.path.isEmpty || resolved.path == "/" { trimmed += "/v1" }
        return trimmed
    }

    static func redact(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "••••")
    }

    private static func body(model: String, turns: [AITurn], tools: [AIToolSpec]) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "messages": turns.map { messageJSON($0) }
        ]
        // An empty list is omitted on purpose: advertising tools would invite calls this build cannot run.
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool -> [String: Any] in
                let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8)))
                    ?? ["type": "object", "properties": [String: Any]()]
                return ["type": "function", "function": [
                    "name": tool.name, "description": tool.description, "parameters": parameters
                ]]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func messageJSON(_ turn: AITurn) -> [String: Any] {
        var message: [String: Any] = ["role": turn.role.rawValue]
        if let toolCallID = turn.toolCallID { message["tool_call_id"] = toolCallID }
        if !turn.toolCalls.isEmpty {
            message["content"] = turn.text.isEmpty ? NSNull() : turn.text
            message["tool_calls"] = turn.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
            return message
        }
        guard !turn.images.isEmpty else {
            message["content"] = turn.text
            return message
        }
        // A picture the model can see, not a base64 string buried in JSON.
        var parts: [[String: Any]] = [["type": "text", "text": turn.text]]
        for image in turn.images {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
        }
        message["content"] = parts
        return message
    }

    private static func completion(from data: Data) throws -> AICompletion {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { throw AIProviderError.decode }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> AIToolCall? in
            guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let arguments = function["arguments"] as? String ?? "{}"
            return AIToolCall(id: id, name: name, arguments: arguments)
        }
        let text = text(from: message["content"])
        if calls.isEmpty, text == nil || text?.isEmpty == true { throw AIProviderError.empty }
        return AICompletion(text: text, toolCalls: calls)
    }

    private static func text(from content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func failureMessage(in data: Data, hiding key: String) -> String {
        let raw: String
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            raw = message
        } else {
            raw = String(data: data, encoding: .utf8) ?? ""
        }
        let redacted = redact(raw, key: key)
        if redacted.count <= 240 { return redacted }
        return String(redacted.prefix(240)) + "…"
    }
}
