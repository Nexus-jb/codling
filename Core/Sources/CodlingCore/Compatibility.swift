// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether a package says it supports the device's iOS version, and where
/// it says so.
public struct CompatibilityReport: Equatable {
    public enum Verdict: Equatable {
        case supported
        case unsupported
        /// The package does not say which versions it supports.
        case unknown
    }

    public enum Source: Equatable {
        /// A firmware dependency, which apt enforces.
        case dependency
        /// compatible::, compatible_min:: or compatible_max:: tags.
        case tags
        /// Words in the package's name or summary, such as "iOS 11 to 16".
        case name
    }

    public var verdict: Verdict
    /// The versions the package says it supports, in words: "iOS 15.0 or later".
    public var range: String?
    public var source: Source?

    public init(verdict: Verdict, range: String? = nil, source: Source? = nil) {
        self.verdict = verdict
        self.range = range
        self.source = source
    }
}

public enum Compatibility {
    /// Checks what a package declares against an iOS version such as
    /// "16.3.1". A firmware dependency comes first, because apt enforces it;
    /// then tags, then the package's name and summary.
    ///
    /// Developers often state only a minimum in the dependency and write the
    /// last version they tested in the name, as in "Glow (iOS 12-17)" with
    /// "firmware (>= 12.0)". On a newer iOS the declared maximum still counts,
    /// unless the dependency sets a maximum of its own or the two contradict
    /// each other.
    public static func check(depends: String?, tag: String?, name: String?, summary: String?,
                             systemVersion: String) -> CompatibilityReport {
        let declared = declaration(tag: tag, name: name, summary: summary, systemVersion: systemVersion)
        guard let groups = firmwareGroups(depends) else {
            return declared?.report ?? CompatibilityReport(verdict: .unknown)
        }
        let dependency = report(for: groups, systemVersion: systemVersion)
        guard dependency.verdict == .supported, let declared, let maximum = declared.maximum,
              !matches(systemVersion, upTo: maximum) else {
            return dependency
        }
        let constraints = groups.flatMap { $0 }
        guard groups.allSatisfy({ $0.count == 1 }), !constraints.contains(where: \.isUpperBound) else {
            return dependency
        }
        let minimum = constraints.filter(\.isLowerBound).map(\.version)
            .max { DebianVersion($0) < DebianVersion($1) }
        if let minimum, !matches(minimum, upTo: maximum) {
            return dependency
        }
        return declared.report
    }

    /// What the tags, or else the name or summary, say, with the highest
    /// version they name.
    struct Declaration {
        let report: CompatibilityReport
        let maximum: String?
    }

    static func declaration(tag: String?, name: String?, summary: String?, systemVersion: String) -> Declaration? {
        if let declaration = fromTags(tag, systemVersion: systemVersion) {
            return declaration
        }
        for text in [name, summary].compactMap({ $0 }) {
            if let declaration = fromWords(text, systemVersion: systemVersion) {
                return declaration
            }
        }
        return nil
    }

    // MARK: Dependencies

    struct Constraint: Equatable {
        let relation: String
        let version: String

        func allows(_ system: String) -> Bool {
            let order = DebianVersion.compare(DebianVersion(system), DebianVersion(version))
            switch relation {
            case ">=", ">": return order >= 0
            case "<=", "<": return order <= 0
            case ">>": return order > 0
            case "<<": return order < 0
            case "=": return order == 0
            default: return true
            }
        }

        var isLowerBound: Bool { [">=", ">", ">>"].contains(relation) }
        var isUpperBound: Bool { ["<=", "<", "<<", "="].contains(relation) }

        var words: String {
            switch relation {
            case ">=", ">": return "iOS \(version) or later"
            case ">>": return "later than iOS \(version)"
            case "<=", "<": return "up to iOS \(version)"
            case "<<": return "before iOS \(version)"
            case "=": return "iOS \(version) only"
            default: return "iOS \(version)"
            }
        }
    }

    /// The firmware constraints of a Depends field, nil when it has none. A
    /// group of alternatives counts only when every alternative is a firmware
    /// constraint; it is met when one of them is.
    static func firmwareGroups(_ depends: String?) -> [[Constraint]]? {
        guard let depends, depends.lowercased().contains("firmware") else { return nil }
        var groups: [[Constraint]] = []
        for group in depends.split(separator: ",") {
            var alternatives: [Constraint] = []
            var onlyFirmware = true
            for alternative in group.split(separator: "|") {
                let text = alternative.trimmingCharacters(in: .whitespaces)
                guard text.lowercased().hasPrefix("firmware"), let open = text.firstIndex(of: "("),
                      let close = text.lastIndex(of: ")"), open < close else {
                    onlyFirmware = false
                    break
                }
                let inside = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let relation = String(inside.prefix { "<>=".contains($0) })
                let version = inside.dropFirst(relation.count).trimmingCharacters(in: .whitespaces)
                guard !relation.isEmpty, !version.isEmpty, version.first?.isNumber == true else {
                    onlyFirmware = false
                    break
                }
                alternatives.append(Constraint(relation: relation, version: version))
            }
            if onlyFirmware && !alternatives.isEmpty {
                groups.append(alternatives)
            }
        }
        return groups.isEmpty ? nil : groups
    }

    static func report(for groups: [[Constraint]], systemVersion: String) -> CompatibilityReport {
        let supported = groups.allSatisfy { group in group.contains { $0.allows(systemVersion) } }
        let range = groups.map { $0.map(\.words).joined(separator: " or ") }.joined(separator: ", ")
        return CompatibilityReport(verdict: supported ? .supported : .unsupported, range: range, source: .dependency)
    }

    // MARK: Tags

    static func fromTags(_ field: String?, systemVersion: String) -> Declaration? {
        let tags = PackageCatalog.tags(field)
        var majors: [String] = []
        var minimum: String?
        var maximum: String?
        for tag in tags {
            if let version = value(tag, after: "compatible::ios") {
                majors.append(version)
            } else if let version = value(tag, after: "compatible_min::ios") {
                minimum = version
            } else if let version = value(tag, after: "compatible_max::ios") {
                maximum = version
            }
        }
        if minimum != nil || maximum != nil {
            return Declaration(report: bounded(minimum: minimum, maximum: maximum, systemVersion: systemVersion,
                                               source: .tags),
                               maximum: maximum)
        }
        guard !majors.isEmpty else { return nil }
        let supported = majors.contains { major in Self.matches(systemVersion, upTo: major) && Self.matches(major, upTo: systemVersion, inclusive: true) }
        let sorted = majors.sorted { DebianVersion($0) < DebianVersion($1) }
        let range = sorted.count == 1 ? "iOS \(sorted[0])" : "iOS " + sorted.joined(separator: ", ")
        return Declaration(report: CompatibilityReport(verdict: supported ? .supported : .unsupported,
                                                       range: range, source: .tags),
                           maximum: sorted.last)
    }

    /// "16" from "compatible::ios16", "16.5" from "compatible_max::ios16.5",
    /// "16" from "compatible::ios16.x".
    private static func value(_ tag: String, after prefix: String) -> String? {
        guard tag.hasPrefix(prefix) else { return nil }
        var version = String(tag.dropFirst(prefix.count))
        while version.hasSuffix(".x") {
            version.removeLast(2)
        }
        guard let first = version.first, first.isNumber,
              version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return version
    }

    // MARK: Words

    private static let rangePattern = try! NSRegularExpression(
        pattern: #"\biOS\s*(\d+(?:\.\d+)*)\s*(?:to|-|–|through|thru|~)\s*(?:iOS\s*)?(\d+(?:\.\d+)*)"#, options: [.caseInsensitive])
    private static let openPattern = try! NSRegularExpression(
        pattern: #"\biOS\s*(\d+(?:\.\d+)*)\s*(?:\+|and (?:up|later|newer|above)|or (?:later|newer|above))"#, options: [.caseInsensitive])

    static func fromWords(_ text: String, systemVersion: String) -> Declaration? {
        let range = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        if let match = rangePattern.firstMatch(in: text, range: range),
           let low = group(match, 1), let high = group(match, 2) {
            return Declaration(report: bounded(minimum: low, maximum: high, systemVersion: systemVersion,
                                               source: .name),
                               maximum: high)
        }
        if let match = openPattern.firstMatch(in: text, range: range), let low = group(match, 1) {
            return Declaration(report: bounded(minimum: low, maximum: nil, systemVersion: systemVersion,
                                               source: .name),
                               maximum: nil)
        }
        return nil
    }

    // MARK: Ranges

    /// A minimum and a maximum as people write them: "iOS 11 to 16" covers
    /// every 16.x, and "up to 16.5" covers 16.5.1.
    static func bounded(minimum: String?, maximum: String?, systemVersion: String,
                        source: CompatibilityReport.Source) -> CompatibilityReport {
        var supported = true
        if let minimum, !matches(minimum, upTo: systemVersion, inclusive: true) {
            supported = false
        }
        if let maximum, !matches(systemVersion, upTo: maximum) {
            supported = false
        }
        let words: String
        switch (minimum, maximum) {
        case let (low?, high?): words = "iOS \(low) to \(high)"
        case let (low?, nil): words = "iOS \(low) or later"
        case let (nil, high?): words = "up to iOS \(high)"
        default: words = ""
        }
        return CompatibilityReport(verdict: supported ? .supported : .unsupported, range: words, source: source)
    }

    /// Whether version is at most limit, comparing only as many parts as the
    /// limit has: 16.3.1 is within "16" and within "16.3".
    static func matches(_ version: String, upTo limit: String, inclusive: Bool = true) -> Bool {
        let limitParts = limit.split(separator: ".").count
        let truncated = version.split(separator: ".").prefix(limitParts).joined(separator: ".")
        let order = DebianVersion.compare(DebianVersion(truncated), DebianVersion(limit))
        return inclusive ? order <= 0 : order < 0
    }
}

/// The jailbreak a package is built for, from its architecture.
public enum JailbreakKind: Equatable {
    case rootless
    case roothide
    case rootful
    /// Architecture "all": any jailbreak.
    case any
    case other(String)

    public init(architecture: String) {
        switch architecture {
        case "iphoneos-arm64": self = .rootless
        case "iphoneos-arm64e": self = .roothide
        case "iphoneos-arm": self = .rootful
        case "all", "": self = .any
        default: self = .other(architecture)
        }
    }

    public var title: String {
        switch self {
        case .rootless: return "rootless"
        case .roothide: return "RootHide"
        case .rootful: return "rootful"
        case .any: return "any"
        case .other(let architecture): return architecture
        }
    }
}
