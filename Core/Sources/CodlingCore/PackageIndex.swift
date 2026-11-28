// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A package as a repository's Packages index lists it.
public struct PackageRecord: Equatable {
    public var package = ""
    public var version = ""
    public var architecture = ""
    public var name: String?
    public var section: String?
    public var author: String?
    public var maintainer: String?
    public var description: String?
    public var depiction: String?
    public var sileoDepiction: String?
    public var icon: String?
    public var filename: String?
    public var size: Int64?
    public var sha256: String?
    public var depends: String?
    public var tag: String?

    public init() {}

    /// The first line of the description.
    public var summary: String {
        description.flatMap { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) } ?? ""
    }
}

public enum PackageIndex {
    /// The packages in a Packages index, for one architecture and "all".
    /// Stanzas without Package or Version are skipped. Reads bytes rather than
    /// a String: indexes run to tens of megabytes.
    ///
    /// convertible is a second architecture whose packages are kept too, for
    /// a package the index has no build of for architecture or "all": on
    /// RootHide, rootless packages, which RootHide Patcher can convert
    /// (RootlessConversion).
    public static func parse(_ data: Data, architecture: String, convertible: String? = nil) -> [PackageRecord] {
        let records = parseRecords(data, architecture: architecture, convertible: convertible)
        guard let convertible else { return records }
        let native = Set(records.lazy.filter { $0.architecture != convertible }.map(\.package))
        return records.filter { $0.architecture != convertible || !native.contains($0.package) }
    }

    private static func parseRecords(_ data: Data, architecture: String, convertible: String?) -> [PackageRecord] {
        var records: [PackageRecord] = []
        records.reserveCapacity(data.count / 1200)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var record = PackageRecord()
            var started = false
            var field: Field?
            var value: [UInt8] = []

            func finishField() {
                if let field {
                    record.set(field, to: String(decoding: value, as: UTF8.self))
                }
                field = nil
                value.removeAll(keepingCapacity: true)
            }
            func finishRecord() {
                finishField()
                if started, !record.package.isEmpty, !record.version.isEmpty,
                   record.architecture.isEmpty || record.architecture == architecture || record.architecture == "all"
                    || (convertible != nil && record.architecture == convertible) {
                    records.append(record)
                }
                record = PackageRecord()
                started = false
            }

            var start = 0
            let count = bytes.count
            while start <= count {
                var end = start
                while end < count && bytes[end] != 0x0A {
                    end += 1
                }
                var lineEnd = end
                if lineEnd > start && bytes[lineEnd - 1] == 0x0D {
                    lineEnd -= 1
                }
                if lineEnd == start {
                    // A blank line ends the stanza.
                    finishRecord()
                } else if bytes[start] == 0x20 || bytes[start] == 0x09 {
                    // A continuation line, kept only for fields Codling stores.
                    if field != nil {
                        value.append(0x0A)
                        value.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[(start + 1)..<lineEnd]))
                    }
                } else if bytes[start] != 0x23 {
                    finishField()
                    var colon = start
                    while colon < lineEnd && bytes[colon] != 0x3A {
                        colon += 1
                    }
                    if colon < lineEnd {
                        field = Field(bytes: UnsafeBufferPointer(rebasing: bytes[start..<colon]))
                        if field != nil {
                            var valueStart = colon + 1
                            while valueStart < lineEnd && (bytes[valueStart] == 0x20 || bytes[valueStart] == 0x09) {
                                valueStart += 1
                            }
                            var valueEnd = lineEnd
                            while valueEnd > valueStart && (bytes[valueEnd - 1] == 0x20 || bytes[valueEnd - 1] == 0x09) {
                                valueEnd -= 1
                            }
                            value.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[valueStart..<valueEnd]))
                        }
                        started = true
                    }
                }
                start = end + 1
            }
            finishRecord()
        }
        return records
    }

    /// The fields Codling keeps, matched without regard to case.
    enum Field: CaseIterable {
        case package, version, architecture, name, section, author, maintainer, description
        case depiction, sileoDepiction, icon, filename, size, sha256, depends, tag

        var key: String {
            switch self {
            case .package: return "package"
            case .version: return "version"
            case .architecture: return "architecture"
            case .name: return "name"
            case .section: return "section"
            case .author: return "author"
            case .maintainer: return "maintainer"
            case .description: return "description"
            case .depiction: return "depiction"
            case .sileoDepiction: return "sileodepiction"
            case .icon: return "icon"
            case .filename: return "filename"
            case .size: return "size"
            case .sha256: return "sha256"
            case .depends: return "depends"
            case .tag: return "tag"
            }
        }

        private static let byKey: [String: Field] = Dictionary(uniqueKeysWithValues: allCases.map { ($0.key, $0) })

        init?(bytes: UnsafeBufferPointer<UInt8>) {
            guard bytes.count <= 16 else { return nil }
            let key = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
            guard let field = Field.byKey[key] else { return nil }
            self = field
        }
    }
}

private extension PackageRecord {
    mutating func set(_ field: PackageIndex.Field, to value: String) {
        switch field {
        case .package: package = value
        case .version: version = value
        case .architecture: architecture = value
        case .name: name = value
        case .section: section = value
        case .author: author = value
        case .maintainer: maintainer = value
        case .description: description = value
        case .depiction: depiction = value
        case .sileoDepiction: sileoDepiction = value
        case .icon: icon = value
        case .filename: filename = value
        case .size: size = Int64(value)
        case .sha256: sha256 = value.lowercased()
        case .depends: depends = value
        case .tag: tag = value
        }
    }
}
