import Foundation

/// Whether the configured endpoint answers at all. Any HTTP status counts as reachable: a 401 still means the
/// network, the sandbox, and the host are fine. The key is not sent.
enum AIConnectivity {
    struct Report: Equatable, Sendable {
        var reachable: Bool
        var detail: String
    }

    static func check(endpoint: String) async -> Report {
        guard let url = probeURL(from: endpoint) else {
            return Report(reachable: false, detail: "The endpoint is not a valid URL. The editor is unaffected.")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Report(reachable: true, detail: "Reachable (HTTP \(code)).")
        } catch {
            return Report(reachable: false, detail: "Not reachable. \(error.localizedDescription) The editor is unaffected.")
        }
    }

    /// The chat URL, limited to http and https so a check cannot touch the file system.
    static func probeURL(from endpoint: String) -> URL? {
        guard let url = OpenAICompatibleProvider.completionsURL(from: endpoint),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
