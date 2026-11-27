import Foundation

enum L10n {
    /// Where the strings come from: the app's bundle. Tests point it at one language's folder
    /// (`Resources/ru.lproj`) to draw and check the Russian app; `swift test` has no app bundle.
    static var bundle: Bundle = .main
    /// The language the strings are in, which picks the plural rule. Nil: the bundle's own (the app's language).
    static var language: String?

    static func text(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: fallback, comment: "")
    }

    /// A count in a sentence, with the language's plural forms from Localizable.stringsdict
    /// (Russian has one, few and many): "1 file", "2 files"; "1 файл", "2 файла", "5 файлов".
    /// The fallback is the English plural; its singular comes from the English stringsdict.
    static func plural(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        let locale = Locale(identifier: language ?? bundle.preferredLocalizations.first ?? "en")
        return String(format: text(key, fallback: fallback), locale: locale, arguments: arguments)
    }
}
