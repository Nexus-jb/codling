// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A package as lists and search results show it.
public struct PackageSummary: Equatable, Identifiable {
    public var source: String
    public var package: String
    public var version: String
    public var name: String?
    public var section: String?
    public var author: String?
    public var maintainer: String?
    public var summary: String?
    public var icon: String?
    public var tag: String?

    public init(source: String, package: String, version: String, name: String? = nil, section: String? = nil,
                author: String? = nil, maintainer: String? = nil, summary: String? = nil, icon: String? = nil,
                tag: String? = nil) {
        self.source = source
        self.package = package
        self.version = version
        self.name = name
        self.section = section
        self.author = author
        self.maintainer = maintainer
        self.summary = summary
        self.icon = icon
        self.tag = tag
    }

    public var id: String { source + "\n" + package }

    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return package
    }

    /// The author, or the maintainer when there is no author, without an
    /// email address.
    public var displayAuthor: String? {
        (author ?? maintainer).map(Person.name).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var displaySection: String {
        PackageCatalog.displaySection(section)
    }

    /// Paid packages carry cydia::commercial in their Tag field.
    public var isPaid: Bool {
        PackageCatalog.tags(tag).contains("cydia::commercial")
    }
}

public enum Person {
    /// "Jane Doe <jane@example.com>" becomes "Jane Doe".
    public static func name(_ person: String) -> String {
        guard let open = person.firstIndex(of: "<") else {
            return person.trimmingCharacters(in: .whitespaces)
        }
        let name = person[..<open].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? person.trimmingCharacters(in: .whitespaces) : name
    }
}

public extension PackageRecord {
    /// The description after its first line. A line holding only "." is a
    /// blank line.
    var details: String {
        let lines = (description ?? "").split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return lines.map { $0.trimmingCharacters(in: .whitespaces) == "." ? "" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PackageCatalog {
    /// The newest version of each package of each source, sorted by name.
    public static func newest(_ rows: [PackageSummary]) -> [PackageSummary] {
        var best: [String: PackageSummary] = [:]
        for row in rows {
            if let current = best[row.id], DebianVersion(current.version) >= DebianVersion(row.version) {
                continue
            }
            best[row.id] = row
        }
        return best.values.sorted(by: byName)
    }

    public static func byName(_ lhs: PackageSummary, _ rhs: PackageSummary) -> Bool {
        switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }

    /// The sections of a list of packages, with how many packages each holds,
    /// sorted by name.
    public static func sections(_ packages: [PackageSummary]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for package in packages {
            counts[package.displaySection, default: 0] += 1
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// A section as people read it: "Tweaks_(Paid)" is "Tweaks (Paid)", and a
    /// package without one is in "Other".
    public static func displaySection(_ section: String?) -> String {
        let text = (section ?? "").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Other" : text
    }

    public static func tags(_ field: String?) -> [String] {
        (field ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// The words of a search, for SQL LIKE patterns.
    public static func searchWords(_ query: String) -> [String] {
        Array(query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).prefix(8))
    }

    /// A LIKE pattern that matches text containing word, with LIKE's own
    /// characters escaped by "\".
    public static func likePattern(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if character == "%" || character == "_" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    /// Orders search results: an exact name or identifier first, then names
    /// that start with the search, then names that contain it, then the rest.
    public static func rank(_ packages: [PackageSummary], query: String) -> [PackageSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func score(_ package: PackageSummary) -> Int {
            let name = package.displayName.lowercased()
            let identifier = package.package.lowercased()
            if name == needle || identifier == needle { return 0 }
            if name.hasPrefix(needle) { return 1 }
            if name.contains(needle) { return 2 }
            if identifier.contains(needle) { return 3 }
            if (package.displayAuthor ?? "").lowercased().contains(needle) { return 4 }
            return 5
        }
        return packages.map { (score($0), $0) }.sorted { lhs, rhs in
            lhs.0 != rhs.0 ? lhs.0 < rhs.0 : byName(lhs.1, rhs.1)
        }.map(\.1)
    }
}
