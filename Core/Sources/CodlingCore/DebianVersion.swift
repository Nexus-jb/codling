// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A Debian package version, [epoch:]upstream[-revision], ordered as the
/// Debian Policy Manual describes (section 5.6.12).
public struct DebianVersion: Comparable, CustomStringConvertible {
    public let epoch: Int
    public let upstream: String
    public let revision: String
    public let description: String

    public init(_ text: String) {
        description = text
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if let colon = rest.firstIndex(of: ":"), let value = Int(rest[..<colon]) {
            epoch = value
            rest = rest[rest.index(after: colon)...]
        } else {
            epoch = 0
        }
        if let dash = rest.lastIndex(of: "-") {
            upstream = String(rest[..<dash])
            revision = String(rest[rest.index(after: dash)...])
        } else {
            upstream = String(rest)
            revision = ""
        }
    }

    public static func < (lhs: DebianVersion, rhs: DebianVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    public static func == (lhs: DebianVersion, rhs: DebianVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    /// Negative, zero or positive, as lhs sorts before, with or after rhs.
    public static func compare(_ lhs: DebianVersion, _ rhs: DebianVersion) -> Int {
        if lhs.epoch != rhs.epoch {
            return lhs.epoch < rhs.epoch ? -1 : 1
        }
        let upstream = compareParts(Array(lhs.upstream.utf8), Array(rhs.upstream.utf8))
        if upstream != 0 {
            return upstream
        }
        return compareParts(Array(lhs.revision.utf8), Array(rhs.revision.utf8))
    }

    /// Compares alternating runs: first characters that are not digits, by
    /// the order below, then digits, as numbers; and so on.
    static func compareParts(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            // The non-digit run.
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let left = i < a.count && !isDigit(a[i]) ? order(a[i]) : 0
                let right = j < b.count && !isDigit(b[j]) ? order(b[j]) : 0
                if left != right {
                    return left < right ? -1 : 1
                }
                if i < a.count && !isDigit(a[i]) { i += 1 }
                if j < b.count && !isDigit(b[j]) { j += 1 }
            }
            // The digit run, without leading zeros.
            while i < a.count && a[i] == 0x30 { i += 1 }
            while j < b.count && b[j] == 0x30 { j += 1 }
            var difference = 0
            while i < a.count && isDigit(a[i]) && j < b.count && isDigit(b[j]) {
                if difference == 0 {
                    difference = Int(a[i]) - Int(b[j])
                }
                i += 1
                j += 1
            }
            if i < a.count && isDigit(a[i]) { return 1 }
            if j < b.count && isDigit(b[j]) { return -1 }
            if difference != 0 {
                return difference < 0 ? -1 : 1
            }
        }
        return 0
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// "~" sorts before everything, even the end of the run; then the end;
    /// then letters; then everything else, by its code.
    private static func order(_ c: UInt8) -> Int {
        if c == 0x7E { return -1 }
        if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { return Int(c) }
        return Int(c) + 256
    }
}
