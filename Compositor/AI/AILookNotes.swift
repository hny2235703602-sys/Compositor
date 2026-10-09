import Foundation

/// The look catalog lives in `Looks.json`, next to this file. Each entry says what a phrase means and gives a
/// Camera Raw starting point. The model reads that, looks at the picture, and chooses the sliders.
enum AILookNotes {
    struct Look: Equatable {
        var id: String
        var undoName: String
        var phrases: [String]
        var use: String
        var settings: CameraRawSettings
    }

    struct Match: Equatable {
        var id: String
        var phrase: String
    }

    /// One line per look: the id, the phrases, and when to use it. The slider values stay in the file.
    static var index: String {
        catalog.map { look in
            "\(look.id) — \(look.phrases.joined(separator: "、")) — \(look.use)"
        }.joined(separator: "\n")
    }

    static func look(named raw: String) -> Look? {
        let folded = fold(raw)
        if let found = catalog.first(where: { $0.id == folded }) { return found }
        return catalog.first { look in
            look.phrases.contains { fold($0) == folded }
        }
    }

    /// Longest phrase wins, so 「黑金色调」beats 「黑金」and 「胶片颗粒」beats 「胶片」.
    static func matches(in text: String) -> [Match] {
        let folded = text.lowercased()
        let tokens = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var hits: [(id: String, phrase: String, length: Int)] = []
        for look in catalog {
            for phrase in look.phrases {
                let needle = phrase.lowercased()
                guard needle.count >= 2, contains(needle, in: folded, tokens: tokens) else { continue }
                hits.append((look.id, phrase, needle.count))
            }
        }
        hits.sort { $0.length > $1.length }
        var seen: Set<String> = []
        return hits.compactMap { hit in
            guard seen.insert(hit.id).inserted else { return nil }
            return Match(id: hit.id, phrase: hit.phrase)
        }
    }

    /// The non-zero sliders of a look, so the model can start from them and change what the picture needs.
    static func recipe(of look: Look) -> String {
        var parts: [String] = []
        func tone(_ name: String, _ value: Double) {
            guard value != 0 else { return }
            parts.append("\(name) \(number(value))")
        }
        tone("exposure", look.settings.exposure)
        tone("contrast", look.settings.contrast)
        tone("highlights", look.settings.highlights)
        tone("shadows", look.settings.shadows)
        tone("whites", look.settings.whites)
        tone("blacks", look.settings.blacks)
        tone("temperature", look.settings.temperature)
        tone("tint", look.settings.tint)
        tone("vibrance", look.settings.vibrance)
        tone("saturation", look.settings.saturation)
        tone("texture", look.settings.texture)
        tone("clarity", look.settings.clarity)
        tone("dehaze", look.settings.dehaze)
        tone("vignette", look.settings.vignetteAmount)
        tone("grain", look.settings.grainAmount)
        wheel("highlights", look.settings.grading.highlights, into: &parts)
        wheel("shadows", look.settings.grading.shadows, into: &parts)
        wheel("midtones", look.settings.grading.midtones, into: &parts)
        wheel("global", look.settings.grading.global, into: &parts)
        return parts.joined(separator: ", ")
    }

    /// A catalog phrase used as an instruction, not a question. The recipe is a starting point for the model.
    static func directMatch(in text: String) -> Match? {
        guard !isQuestion(text) else { return nil }
        return matches(in: text).first
    }

    /// Questions stay with the model. 「什么是通透」should not bake the clear look.
    static func isQuestion(_ text: String) -> Bool {
        if text.contains("?") || text.contains("？") { return true }
        let markers = ["什么", "为什么", "为何", "是不是", "啥意思", "什么意思"]
        return markers.contains { text.contains($0) }
    }

    private static let catalog: [Look] = load()

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func wheel(_ name: String, _ wheel: CameraRawGradeWheel, into parts: inout [String]) {
        guard wheel.saturation != 0 || wheel.luminance != 0 else { return }
        parts.append("\(name) hue \(number(wheel.hue)) saturation \(number(wheel.saturation)) luminance \(number(wheel.luminance))")
    }

    private static func fold(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Chinese phrases match inside a sentence. Latin phrases match a whole word, so "soft" is not found in "software".
    private static func contains(_ needle: String, in text: String, tokens: Set<String>) -> Bool {
        let latin = needle.allSatisfy { $0.isASCII }
        if latin { return tokens.contains(needle) }
        return text.contains(needle)
    }

    private static func load() -> [Look] {
        guard let url = catalogURL(), let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(AILookFile.self, from: data) else { return [] }
        return file.looks.compactMap(Look.init)
    }

    private static func catalogURL() -> URL? {
        if let url = Bundle.main.url(forResource: "Looks", withExtension: "json") { return url }
        if let url = Bundle.main.url(forResource: "Looks", withExtension: "json", subdirectory: "AI") { return url }
        guard let root = Bundle.main.resourceURL else { return nil }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return enumerator?.compactMap { $0 as? URL }.first { $0.lastPathComponent == "Looks.json" }
    }
}

private extension AILookNotes.Look {
    init?(_ item: AILookFile.Item) {
        let settings = item.cameraRaw
        guard !settings.isIdentity else { return nil }
        let phrases = item.phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }
        self.id = item.id
        self.undoName = item.title
        self.phrases = phrases
        self.use = item.use
        self.settings = settings
    }
}

private struct AILookFile: Decodable {
    var looks: [Item]

    struct Item: Decodable {
        var id: String
        var title: String
        var use: String
        var phrases: [String]
        var settings: Settings
        var grading: Grading?
    }

    struct Settings: Decodable {
        var exposure: Double?
        var contrast: Double?
        var highlights: Double?
        var shadows: Double?
        var whites: Double?
        var blacks: Double?
        var temperature: Double?
        var tint: Double?
        var vibrance: Double?
        var saturation: Double?
        var texture: Double?
        var clarity: Double?
        var dehaze: Double?
        var vignette: Double?
        var grain: Double?
    }

    struct Grading: Decodable {
        var highlights: Wheel?
        var shadows: Wheel?
        var midtones: Wheel?
        var global: Wheel?
    }

    struct Wheel: Decodable {
        var hue: Double?
        var saturation: Double?
        var luminance: Double?
    }
}

private extension AILookFile.Item {
    var cameraRaw: CameraRawSettings {
        var raw = CameraRawSettings()
        raw.exposure = settings.exposure ?? 0
        raw.contrast = settings.contrast ?? 0
        raw.highlights = settings.highlights ?? 0
        raw.shadows = settings.shadows ?? 0
        raw.whites = settings.whites ?? 0
        raw.blacks = settings.blacks ?? 0
        raw.temperature = settings.temperature ?? 0
        raw.tint = settings.tint ?? 0
        raw.vibrance = settings.vibrance ?? 0
        raw.saturation = settings.saturation ?? 0
        raw.texture = settings.texture ?? 0
        raw.clarity = settings.clarity ?? 0
        raw.dehaze = settings.dehaze ?? 0
        raw.vignetteAmount = settings.vignette ?? 0
        raw.grainAmount = settings.grain ?? 0
        if let wheel = grading?.highlights { raw.grading.highlights = wheel.applied }
        if let wheel = grading?.shadows { raw.grading.shadows = wheel.applied }
        if let wheel = grading?.midtones { raw.grading.midtones = wheel.applied }
        if let wheel = grading?.global { raw.grading.global = wheel.applied }
        return raw
    }
}

private extension AILookFile.Wheel {
    var applied: CameraRawGradeWheel {
        CameraRawGradeWheel(hue: hue ?? 0, saturation: saturation ?? 0, luminance: luminance ?? 0)
    }
}
