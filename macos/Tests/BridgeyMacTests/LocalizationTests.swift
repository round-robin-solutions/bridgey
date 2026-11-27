import Foundation
import XCTest
@testable import BridgeyMac

/// English and Russian stay complete and in step: the same keys in every table, the same format arguments, every key
/// the code asks for present, plural forms that work, no hard-coded English in the views, and British English copy
/// without dashes.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let tables = ["Localizable", "Setup", "Agents"]

    override func tearDown() {
        L10n.bundle = .main
        L10n.language = nil
        super.tearDown()
    }

    private func strings(_ language: String, _ table: String) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Resources/\(language).lproj/\(table).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language).lproj/\(table).strings does not parse")
    }

    private func plurals(_ language: String) throws -> [String: Any] {
        let url = Self.root.appendingPathComponent("Resources/\(language).lproj/Localizable.stringsdict")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "\(language).lproj/Localizable.stringsdict does not parse")
    }

    private func bundle(_ language: String) throws -> Bundle {
        L10n.language = language
        return try XCTUnwrap(Bundle(path: Self.root.appendingPathComponent("Resources/\(language).lproj").path))
    }

    func testEnglishAndRussianHaveTheSameKeys() throws {
        for table in Self.tables {
            let english = try strings("en", table), russian = try strings("ru", table)
            XCTAssertEqual(Set(english.keys).subtracting(russian.keys).sorted(), [], "\(table): missing in Russian")
            XCTAssertEqual(Set(russian.keys).subtracting(english.keys).sorted(), [], "\(table): only in Russian")
        }
        let english = try plurals("en"), russian = try plurals("ru")
        XCTAssertEqual(Set(english.keys), Set(russian.keys), "Localizable.stringsdict keys differ between English and Russian")
        let localizable = try strings("en", "Localizable")
        for key in english.keys {
            XCTAssertNotNil(localizable[key], "\(key) has plural forms but no Localizable.strings fallback")
        }
        for (key, value) in russian {
            guard let entry = value as? [String: Any], let format = entry["NSStringLocalizedFormatKey"] as? String else { continue }
            for name in Self.variables(format) {
                let rule = try XCTUnwrap(entry[name] as? [String: String], "\(key): no rule for \(name)")
                for form in ["one", "few", "many", "other"] { XCTAssertNotNil(rule[form], "\(key).\(name) has no Russian \(form) form") }
            }
        }
    }

    func testFormatArgumentsMatch() throws {
        for table in Self.tables {
            let english = try strings("en", table), russian = try strings("ru", table)
            for (key, value) in english {
                guard let translated = russian[key] else { continue }
                XCTAssertEqual(Self.arguments(translated), Self.arguments(value), "\(table): \(key) has different format arguments in Russian")
            }
        }
    }

    func testEveryKeyTheCodeUsesExists() throws {
        let helpers = ["text": "Localizable", "plural": "Localizable", "setup": "Setup", "agents": "Agents"]
        let pattern = try NSRegularExpression(pattern: #"L10n\.(text|plural|setup|agents)\(\s*"([^"\\]+)""#)
        let folder = Self.root.appendingPathComponent("Sources/BridgeyMac")
        var missing: [String] = []
        var used = 0
        var cache: [String: [String: String]] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let kind = Range(match.range(at: 1), in: source).map({ String(source[$0]) }),
                      let key = Range(match.range(at: 2), in: source).map({ String(source[$0]) }), let table = helpers[kind] else { continue }
                used += 1
                for language in ["en", "ru"] {
                    let id = "\(language)/\(table)"
                    if cache[id] == nil { cache[id] = try strings(language, table) }
                    if cache[id]?[key] == nil { missing.append("\(file): \(key) (\(language).lproj/\(table).strings)") }
                }
            }
        }
        XCTAssertGreaterThan(used, 2000)
        XCTAssertEqual(missing.sorted(), [], "Keys the code uses that a table does not have")
    }

    func testRussianPluralsUseOneFewAndMany() throws {
        L10n.bundle = try bundle("ru")
        XCTAssertEqual(L10n.plural("phonefiles.counts", fallback: "", 1, 1), "1 папка, 1 файл")
        XCTAssertEqual(L10n.plural("phonefiles.counts", fallback: "", 3, 5), "3 папки, 5 файлов")
        XCTAssertEqual(L10n.plural("phonefiles.counts", fallback: "", 21, 22), "21 папка, 22 файла")
        XCTAssertEqual(L10n.plural("phonefiles.shown", fallback: "", 11), "11 объектов")
        XCTAssertEqual(L10n.plural("sync.choose.count", fallback: "", 3, 21), "3 из 21 настройки")
        XCTAssertEqual(L10n.plural("developer.tapsLeft", fallback: "", 5), "Ещё 5 нажатий, и откроются настройки для разработчиков")
        XCTAssertEqual(L10n.plural("stream.alerts", fallback: "", 2), "2 уведомления")
        XCTAssertEqual(L10n.plural("stream.alerts.app", fallback: "", 5, "WhatsApp"), "5 уведомлений WhatsApp")
    }

    func testEnglishPluralsSaySingularOnceAndPluralOtherwise() throws {
        L10n.bundle = try bundle("en")
        XCTAssertEqual(L10n.plural("phonefiles.counts", fallback: "", 1, 1), "1 folder, 1 file")
        XCTAssertEqual(L10n.plural("phonefiles.counts", fallback: "", 0, 2), "0 folders, 2 files")
        XCTAssertEqual(L10n.plural("phonefiles.progress.files", fallback: "", 1, 1, "2 MB", "2 MB"), "1 of 1 file, 2 MB of 2 MB")
        XCTAssertEqual(L10n.plural("updateAll.summary.phones", fallback: "", 2), "Updates 2 connected phones")
        XCTAssertEqual(L10n.plural("stream.alerts.app", fallback: "", 1, "WhatsApp"), "1 WhatsApp alert")
    }

    func testStatusLinesShowInRussian() throws {
        L10n.bundle = try bundle("ru")
        XCTAssertEqual(StatusText.localized("Ping delivered"), "Пинг доставлен")
        XCTAssertEqual(StatusText.localized("Saved photo.jpg to Downloads"), "Файл photo.jpg сохранён в Downloads")
        XCTAssertEqual(StatusText.localized("Sending report.pdf…"), "Отправляем report.pdf…")
        XCTAssertEqual(StatusText.localized("Something new"), "Something new", "unknown lines stay as they are")
        L10n.bundle = .main
        L10n.language = nil
        XCTAssertEqual(StatusText.localized("Transfer cancelled"), "Transfer cancelled")
    }

    /// Text("Off"), .help("…") and the like show English whatever the language. Proper names and symbols are allowed.
    func testViewsHaveNoHardCodedText() throws {
        let call = #"(?:\bText|\bButton|\bLabel|\bToggle|\bTextField|\bSection|\.help|\.accessibilityLabel|\.accessibilityHint|\.accessibilityValue|\.navigationTitle|setAccessibilityLabel|addButton\(withTitle:|\.title\s*=|\.prompt\s*=|\.message\s*=|messageText\s*=|informativeText\s*=)\s*\(?\s*"((?:[^"\\]|\\.)*)""#
        let pattern = try NSRegularExpression(pattern: call)
        let allowed: Set<String> = ["Bridgey", "wss://"]
        let folder = Self.root.appendingPathComponent("Sources/BridgeyMac")
        var found: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where file.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for (number, raw) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("///") else { continue }
                // Keys are not copy, and one such as "callcard.hide.help" would look like a .help call.
                let line = raw.replacingOccurrences(of: #"L10n\.(\w+)\(\s*"[^"]*""#, with: "L10n.$1(key", options: .regularExpression)
                for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let literal = String(line[range])
                    // Words left once interpolations and escapes are gone.
                    let words = Self.withoutInterpolations(literal)
                        .replacingOccurrences(of: #"\\u\{[0-9A-Fa-f]+\}|\\."#, with: " ", options: .regularExpression)
                    guard words.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil, !allowed.contains(literal) else { continue }
                    found.append("\(file):\(number + 1): \(literal)")
                }
            }
        }
        XCTAssertEqual(found, [], "Hard-coded text in views: use L10n.text with English and Russian entries")
    }

    func testEnglishCopyIsBritishWithoutDashes() throws {
        let american = try NSRegularExpression(pattern: #"\b(colors?|colored|canceled|canceling|centers?|centered|behaviors?|favorites?|gray|catalogs?|optimiz\w*|organiz\w*|recogniz\w*|customiz\w*|minimiz\w*|maximiz\w*|prioritiz\w*|synchroniz\w*|authoriz\w*|initializ\w*|analyz\w*)\b"#,
                                                options: .caseInsensitive)
        var problems: [String] = []
        for table in Self.tables {
            for (key, value) in try strings("en", table) {
                if value.contains("\u{2014}") || value.contains("\u{2013}") { problems.append("\(key): dash") }
                if american.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil { problems.append("\(key): \(value)") }
            }
            for (key, value) in try strings("ru", table) where value.contains("\u{2014}") || value.contains("\u{2013}") {
                problems.append("ru \(key): dash")
            }
        }
        XCTAssertEqual(problems.sorted(), [])
    }

    // MARK: Helpers

    /// "\\(count) of \\(total(of: x)) files" -> "  of   files": interpolations go, nested brackets included.
    private static func withoutInterpolations(_ literal: String) -> String {
        var result = ""
        var depth = 0
        var characters = Array(literal)[...]
        while let char = characters.popFirst() {
            if depth == 0, char == "\\", characters.first == "(" {
                characters.removeFirst()
                depth = 1
                result.append(" ")
            } else if depth > 0 {
                if char == "(" { depth += 1 } else if char == ")" { depth -= 1 }
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// "%1$#@files@" -> ["files"].
    private static func variables(_ format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?#@([A-Za-z]+)@"#)
        return pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)).compactMap {
            Range($0.range(at: 1), in: format).map { String(format[$0]) }
        }
    }

    /// Each argument as position and type: "%d of %@" and "%2$@ из %1$d" are both [1: d, 2: @].
    static func arguments(_ format: String) -> [Int: String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:\.\d+)?(ll|l)?([@dfsuxX])"#)
        let cleaned = format.replacingOccurrences(of: "%%", with: "")
        var next = 1
        var result: [Int: String] = [:]
        for match in pattern.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
            let position = Range(match.range(at: 1), in: cleaned).flatMap { Int(cleaned[$0]) } ?? next
            next = position + 1
            result[position] = Range(match.range(at: 3), in: cleaned).map { String(cleaned[$0]) }
        }
        return result
    }
}
