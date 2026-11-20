// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A JSON value, decoded the same way on every platform.
public enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // Depictions are written by hand, so values are read leniently: a number
    // may arrive as a string and the other way round, and a key may differ
    // in case from the documented one ("url" for "URL").

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        if let value = object[key] {
            return value
        }
        let lowered = key.lowercased()
        return object.first { $0.key.lowercased() == lowered }?.value
    }

    public var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    public var number: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

/// A color as depictions write it: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, rgb(),
/// rgba() or a basic CSS color name.
public struct DepictionColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    private static let names: [String: (Int, Int, Int)] = [
        "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0), "green": (0, 128, 0),
        "lime": (0, 255, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0), "orange": (255, 165, 0),
        "purple": (128, 0, 128), "pink": (255, 192, 203), "gray": (128, 128, 128), "grey": (128, 128, 128),
        "brown": (165, 42, 42), "cyan": (0, 255, 255), "magenta": (255, 0, 255), "teal": (0, 128, 128),
        "navy": (0, 0, 128),
    ]

    public init?(css text: String?) {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "clear" || value == "transparent" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        if let (r, g, b) = Self.names[value] {
            self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
            return
        }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else { return nil }
            let parts = value[value.index(after: open)..<close].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let channels = parts.prefix(3).compactMap { Double($0) }
            guard channels.count == 3 else { return nil }
            var alpha = 1.0
            if parts.count == 4 {
                guard let given = Double(parts[3]) else { return nil }
                alpha = given
            }
            self.init(red: Self.clamp(channels[0] / 255), green: Self.clamp(channels[1] / 255),
                      blue: Self.clamp(channels[2] / 255), alpha: Self.clamp(alpha))
            return
        }
        var hex = Substring(value)
        if hex.hasPrefix("#") {
            hex = hex.dropFirst()
        } else if hex.count != 6 && hex.count != 8 {
            return nil
        }
        guard hex.allSatisfy(\.isHexDigit), let number = UInt64(hex, radix: 16) else { return nil }
        func channel(_ shift: Int, _ bits: Int) -> Double {
            let mask = UInt64((1 << bits) - 1)
            let raw = Double((number >> UInt64(shift)) & mask)
            return raw / Double(mask)
        }
        switch hex.count {
        case 3: self.init(red: channel(8, 4), green: channel(4, 4), blue: channel(0, 4))
        case 4: self.init(red: channel(12, 4), green: channel(8, 4), blue: channel(4, 4), alpha: channel(0, 4))
        case 6: self.init(red: channel(16, 8), green: channel(8, 8), blue: channel(0, 8))
        case 8: self.init(red: channel(24, 8), green: channel(16, 8), blue: channel(8, 8), alpha: channel(0, 8))
        default: return nil
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// A width and height, written "{263, 148}", as an object or as an array.
public struct DepictionSize: Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init?(_ value: JSONValue?) {
        guard let value else { return nil }
        var numbers: [Double] = []
        switch value {
        case .string(let text):
            numbers = DepictionNumbers.all(in: text)
        case .array(let items):
            numbers = items.compactMap(\.number)
        case .object:
            if let width = (value["width"] ?? value["x"])?.number, let height = (value["height"] ?? value["y"])?.number {
                numbers = [width, height]
            }
        default:
            break
        }
        guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0, numbers[0] < 10_000, numbers[1] < 10_000 else {
            return nil
        }
        self.init(width: numbers[0], height: numbers[1])
    }
}

/// Insets written "{top, left, bottom, right}".
public struct DepictionInsets: Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init?(_ value: JSONValue?) {
        guard let text = value?.string else { return nil }
        let numbers = DepictionNumbers.all(in: text)
        guard numbers.count == 4, numbers.allSatisfy({ $0 >= 0 && $0 < 1000 }) else { return nil }
        self.init(top: numbers[0], left: numbers[1], bottom: numbers[2], right: numbers[3])
    }
}

enum DepictionNumbers {
    /// The numbers in a text such as "{263, 148}".
    static func all(in text: String) -> [Double] {
        text.split(whereSeparator: { !($0.isNumber || $0 == "." || $0 == "-") }).compactMap { Double($0) }
    }
}

public enum DepictionAlignment: Equatable {
    case leading
    case center
    case trailing

    public init(_ value: JSONValue?) {
        switch value?.string?.lowercased() {
        case "1", "center", "centre": self = .center
        case "2", "right", "trailing": self = .trailing
        default: self = .leading
        }
    }
}

public enum DepictionURL {
    /// An http or https URL from a depiction, resolved against the address of
    /// the file it came from. Spaces and other characters that are not
    /// allowed in a URL are escaped.
    public static func web(_ text: String?, base: URL?) -> URL? {
        guard let url = any(text, base: base), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }

    /// Any absolute URL, resolved against base when relative.
    public static func any(_ text: String?, base: URL?) -> URL? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096 else { return nil }
        let parsed = URL(string: trimmed, relativeTo: base)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0, relativeTo: base) }
        guard let url = parsed?.absoluteURL, url.scheme != nil else { return nil }
        return url
    }

    /// The characters a URL may hold as written, with "%" for text that is
    /// already escaped.
    private static let allowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.insert(charactersIn: "#%")
        return set
    }()
}

/// What a depiction button or link does.
public enum DepictionAction: Equatable {
    /// A web page, opened in the browser.
    case web(URL)
    /// Another native depiction, shown in Codling.
    case depiction(URL)
    /// A package, by identifier, looked up in the sources.
    case package(String)
    /// A mail, telephone or message link, handed to the system.
    case system(URL)

    /// The first of action and backupAction that Codling can perform; nil
    /// when neither can be, so that no button is shown that does nothing.
    public static func parse(_ action: String?, backup: String? = nil, base: URL?) -> DepictionAction? {
        parse(action, base: base) ?? parse(backup, base: base)
    }

    public static func parse(_ text: String?, base: URL?) -> DepictionAction? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let lowered = text.lowercased()
        if lowered.hasPrefix("depiction-") {
            return DepictionURL.web(String(text.dropFirst("depiction-".count)), base: base).map(DepictionAction.depiction)
        }
        if lowered.hasPrefix("form-") {
            // Forms post to a repository's payment service, which comes later.
            return nil
        }
        for prefix in ["sileo://package/", "cydia://package/", "zbra://packages/", "zbra://package/"] where lowered.hasPrefix(prefix) {
            var identifier = String(text.dropFirst(prefix.count))
            if let end = identifier.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "/" }) {
                identifier = String(identifier[..<end])
            }
            identifier = identifier.removingPercentEncoding ?? identifier
            return isPackageName(identifier) ? .package(identifier) : nil
        }
        if lowered.hasPrefix("cydia://url/") {
            return DepictionURL.web(String(text.dropFirst("cydia://url/".count)), base: nil).map(DepictionAction.web)
        }
        guard let url = DepictionURL.any(text, base: base), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "http", "https": return url.host == nil ? nil : .web(url)
        case "mailto", "tel", "sms": return .system(url)
        default: return nil
        }
    }

    /// A Debian package name: letters, digits, "+", "-" and ".", starting
    /// with a letter or digit.
    public static func isPackageName(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= 200, let first = name.unicodeScalars.first,
              first.isASCII, CharacterSet.alphanumerics.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "+-.".unicodeScalars.contains(scalar))
        }
    }
}
