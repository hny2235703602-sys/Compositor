import Foundation

/// The models a key can use at an OpenAI-compatible endpoint. `GET …/models` returns them, so the panel
/// can offer a list instead of asking for a model name.
enum AIModelCatalog {
    struct Result: Equatable, Sendable {
        var models: [String]
        var error: String?
    }

    static func fetch(endpoint: String, apiKey: String) async -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return Result(models: [], error: AIProviderError.missingKey.localizedDescription)
        }
        guard let url = modelsURL(from: endpoint) else {
            return Result(models: [], error: "The endpoint is not a valid URL. The editor is unaffected.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                return Result(models: [], error: "Could not fetch models (\(status)). \(brief(data, hiding: key)) The editor is unaffected.")
            }
            if let page = pageError(in: data) { return Result(models: [], error: page) }
            let models = ids(in: data)
            guard !models.isEmpty else {
                return Result(models: [], error: "The endpoint returned no models. The editor is unaffected.")
            }
            return Result(models: models, error: nil)
        } catch {
            return Result(models: [], error: "Could not fetch models. \(error.localizedDescription) The editor is unaffected.")
        }
    }

    /// Same root as chat. A bare host becomes `https://host/v1/models`.
    static func modelsURL(from endpoint: String) -> URL? {
        guard let root = OpenAICompatibleProvider.apiRoot(from: endpoint) else { return nil }
        return URL(string: root + "/models")
    }

    /// A 200 response that is the site's HTML, not a model list.
    static func pageError(in data: Data) -> String? {
        let sample = String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard sample.hasPrefix("<") else { return nil }
        return "This address returned a web page, not a model list. The editor is unaffected."
    }

    /// OpenAI's `data: [{id}]`, a `models` array, or a bare list of names.
    static func ids(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let object = json as? [String: Any] {
            rows = (object["data"] as? [Any]) ?? (object["models"] as? [Any]) ?? []
        } else if let list = json as? [Any] {
            rows = list
        } else {
            return []
        }
        var seen = Set<String>()
        var ids: [String] = []
        for row in rows {
            let id: String?
            if let name = row as? String { id = name }
            else if let object = row as? [String: Any] { id = object["id"] as? String }
            else { id = nil }
            guard let id, !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids.sorted()
    }

    private static func brief(_ data: Data, hiding key: String) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let redacted = OpenAICompatibleProvider.redact(raw, key: key)
        if redacted.count <= 180 { return redacted }
        return String(redacted.prefix(180)) + "…"
    }
}
