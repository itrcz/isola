import Foundation

// System language, with English fallback. No separate language preference to drift from macOS.
func L(_ ru: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? ru : en
}
