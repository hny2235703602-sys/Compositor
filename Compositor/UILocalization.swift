import AppKit
import Foundation

/// The English string is the localization key. A missing translation shows the English, which is also what is saved.
func uiName(_ english: String) -> String {
    let code = UserDefaults.standard.string(forKey: "interfaceLanguage")
    if let code, code == "en" || code == "zh-Hans",
       let path = Bundle.main.path(forResource: code, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: english, value: english, table: "Localizable")
    }
    return String(localized: String.LocalizationValue(stringLiteral: english))
}

enum InterfaceTheme {
    static var startingLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    static func surroundWhite(canvasOnly: Bool) -> CGFloat {
        if canvasOnly { return 0 }
        switch UserDefaults.standard.string(forKey: "canvasSurround") {
        case "white": return 1
        case "black": return 0
        default: return 0.42
        }
    }

    static func applyLanguage(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }

    /// Black, gray, or white for everything except the canvas. White uses the light system appearance.
    static func chrome(named raw: String?) -> (body: CGFloat, ruler: CGFloat, ink: CGFloat, light: Bool) {
        switch raw {
        case "white": return (0.94, 0.90, 0.28, true)
        case "black": return (0.05, 0.08, 0.72, false)
        default: return (0.16, 0.20, 0.72, false)
        }
    }

    static func applyChrome(_ raw: String) {
        let light = chrome(named: raw).light
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}
