import Foundation

/// Diagnostic notes live in `Knowledge.json`, next to this file. A note is a procedure, not a Camera Raw
/// recipe. Only the notes whose phrases appear in the current request are handed to the model.
enum AIKnowledge {
    struct Note: Equatable {
        var id: String
        var phrases: [String]
        var text: String
    }

    struct Match: Equatable {
        var id: String
        var phrase: String
    }

    /// The procedure for this request, or empty when the sentence is a question or matches nothing.
    static func note(for text: String) -> String {
        guard !AILookNotes.isQuestion(text) else { return "" }
        let hits = matches(in: text)
        guard !hits.isEmpty else { return "" }
        let body = hits.map { hit in
            """

            Diagnosis for 「\(hit.phrase)」 (\(hit.id)).
            \(catalog.first { $0.id == hit.id }?.text ?? "")
            """
        }.joined()
        let ids = Set(hits.map(\.id))
        let vibranceNotes: Set<String> = ["pale_color", "loud_color", "distant_haze"]
        guard ids.contains("low_key_dull"), !ids.isDisjoint(with: vibranceNotes) else { return body }
        return body + "\nPriority: low_key_dull outranks the other diagnoses, and any catalog recipe yields. Do not raise vibrance or saturation."
    }

    /// Longest phrase wins, and each note is listed once.
    static func matches(in text: String) -> [Match] {
        let folded = text.lowercased()
        let tokens = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var hits: [(id: String, phrase: String, length: Int)] = []
        for note in catalog {
            for phrase in note.phrases {
                let needle = phrase.lowercased()
                guard needle.count >= 2, contains(needle, in: folded, tokens: tokens) else { continue }
                hits.append((note.id, phrase, needle.count))
            }
        }
        hits.sort { $0.length > $1.length }
        var seen: Set<String> = []
        return hits.compactMap { hit in
            guard seen.insert(hit.id).inserted else { return nil }
            return Match(id: hit.id, phrase: hit.phrase)
        }
    }

    private static let catalog: [Note] = load()

    /// Chinese phrases match inside a sentence. Latin phrases match a whole word, so "soft" is not found in "software".
    private static func contains(_ needle: String, in text: String, tokens: Set<String>) -> Bool {
        let latin = needle.allSatisfy { $0.isASCII }
        if latin { return tokens.contains(needle) }
        return text.contains(needle)
    }

    private static func load() -> [Note] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(AIKnowledgeFile.self, from: data) else { return [] }
        return file.notes.compactMap(Note.init)
    }

    private static func fileURL() -> URL? {
        if let url = Bundle.main.url(forResource: "Knowledge", withExtension: "json") { return url }
        if let url = Bundle.main.url(forResource: "Knowledge", withExtension: "json", subdirectory: "AI") { return url }
        guard let root = Bundle.main.resourceURL else { return nil }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return enumerator?.compactMap { $0 as? URL }.first { $0.lastPathComponent == "Knowledge.json" }
    }
}

private extension AIKnowledge.Note {
    init?(_ item: AIKnowledgeFile.Item) {
        let phrases = item.phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrases.isEmpty, !text.isEmpty else { return nil }
        self.id = item.id
        self.phrases = phrases
        self.text = text
    }
}

private struct AIKnowledgeFile: Decodable {
    var notes: [Item]

    struct Item: Decodable {
        var id: String
        var phrases: [String]
        var text: String
    }
}
