import Foundation

/// Idioma de la interfaz. Por defecto («auto») sigue al Mac: español si el primer idioma
/// del sistema es español, inglés en cualquier otro caso.
enum Lang {
    /// "auto", "en" o "es". Se guarda en los ajustes.
    static var pref = "auto"
    static var isSpanish: Bool {
        switch pref {
        case "es": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.lowercased().hasPrefix("es") ?? false
        }
    }
    static var code: String { isSpanish ? "es" : "en" }
}

/// Texto según el idioma: L("Guardar", "Save").
func L(_ es: String, _ en: String) -> String { Lang.isSpanish ? es : en }
