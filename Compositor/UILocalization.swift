import Foundation

/// The English string is the localization key. A missing translation shows the English, which is also what is saved.
func uiName(_ english: String) -> String {
    String(localized: String.LocalizationValue(stringLiteral: english))
}
