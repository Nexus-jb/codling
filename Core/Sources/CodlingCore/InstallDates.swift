// SPDX-License-Identifier: Apache-2.0

import Foundation

/// When dpkg last installed or upgraded each package. dpkg keeps no date in
/// its status file, but it writes a package's file list, info/NAME.list or
/// info/NAME:ARCH.list, every time it unpacks the package, so the list's
/// modification time is that date, as other package managers read it too.
public enum InstallDates {
    /// The date for each package in identifiers that has a file list in
    /// infoDirectory (such as /var/jb/var/lib/dpkg/info). A package listed
    /// both with and without an architecture gets the later date.
    public static func read(infoDirectory: String, identifiers: Set<String>,
                            fileManager: FileManager = .default) -> [String: Date] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: infoDirectory) else {
            return [:]
        }
        var dates: [String: Date] = [:]
        for name in names where name.hasSuffix(".list") {
            let stem = String(name.dropLast(".list".count))
            let identifier = stem.split(separator: ":", maxSplits: 1).first.map(String.init) ?? stem
            guard identifiers.contains(identifier) else {
                continue
            }
            let path = (infoDirectory as NSString).appendingPathComponent(name)
            guard let date = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
                continue
            }
            if let known = dates[identifier], known >= date {
                continue
            }
            dates[identifier] = date
        }
        return dates
    }

    /// Identifiers ordered newest first by date; those without a date come
    /// last. Ties, and the dateless, keep the order they came in.
    public static func newestFirst(_ identifiers: [String], dates: [String: Date]) -> [String] {
        identifiers.enumerated().sorted { left, right in
            switch (dates[left.element], dates[right.element]) {
            case let (a?, b?) where a != b:
                return a > b
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return left.offset < right.offset
            }
        }.map(\.element)
    }
}
