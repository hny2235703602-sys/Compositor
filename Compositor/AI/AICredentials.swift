import Foundation

/// The API key is kept for the whole app, never in a project file. The panel shows the last four characters and
/// a request reads the secret only for the call that needs it.
///
/// The login keychain asks for its password after every rebuild, and the data protection keychain refuses this
/// sandboxed app (status -34018). The key therefore lives in the app's own support directory, which stays put
/// when a different document is opened.
enum AICredentials {
    static let service = "com.wonderassembly.compositor"
    static let account = "ai.openai.apiKey"

    private static var cached: String?
    private static var didResolve = false

    enum Failure: LocalizedError {
        case write
        var errorDescription: String? {
            switch self {
            case .write: String(localized: "The key could not be saved.")
            }
        }
    }

    static func save(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try write(trimmed, account: account)
        cached = trimmed
        didResolve = true
    }

    static func load() -> String? {
        if didResolve { return cached }
        let key = read(account: account)
        cached = key
        didResolve = true
        return key
    }

    static func delete() {
        remove(account: account)
        cached = nil
        didResolve = true
    }

    /// Last four characters, for the panel. Shorter secrets are treated as unset for display so the field never
    /// shows the whole key.
    static func suffix() -> String? {
        guard let key = load(), key.count > 4 else { return nil }
        return String(key.suffix(4))
    }

    static func write(_ secret: String, account: String) throws {
        let url = storeURL(account: account)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(secret.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.write
        }
    }

    static func read(account: String) -> String? {
        guard let data = try? Data(contentsOf: storeURL(account: account)) else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func remove(account: String) {
        try? FileManager.default.removeItem(at: storeURL(account: account))
    }

    private static func storeURL(account: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = account.replacingOccurrences(of: "/", with: "-")
        return base.appendingPathComponent("Compositor", isDirectory: true).appendingPathComponent(name)
    }
}
