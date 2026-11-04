import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    public var id: String { rawValue }
    public static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "system") ?? .system
    }
    public func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "appLanguage") }
    public var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for tag in preferredLanguages {
            if tag.lowercased().hasPrefix("zh") { return .simplifiedChinese }
            if tag.lowercased().hasPrefix("en") { return .english }
        }
        return .english
    }
}

public enum Localization {
    private static let lock = NSLock()
    private static var selection = AppLanguage.system
    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selection }
        set { lock.lock(); defer { lock.unlock() }; selection = newValue }
    }
    public static var isChinese: Bool { language.resolved() == .simplifiedChinese }
    public static var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
}

/// Keeps interpolation arguments separate from the translated template, so
/// percentages, paths and server-provided names are never translation keys.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation value: StringInterpolation) {
        key = value.key; arguments = value.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
    private static let placeholders = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")

    public var text: String {
        let template = Localization.isChinese ? key : EnglishStrings.values[key] ?? key
        // Parse placeholders in the template only; arguments may contain braces.
        guard !arguments.isEmpty else { return template }
        let expression = Self.placeholders
        let source = template as NSString
        var result = "", cursor = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}

public func L(_ message: LocalizedMessage) -> String { message.text }
