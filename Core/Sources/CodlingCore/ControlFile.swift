// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A stanza of a Debian control-style file: "Field: value" lines, where a line
/// that starts with a space or tab continues the field above it. Release
/// files, package indexes, dpkg's status file and deb822 source lists all use
/// this form.
public struct ControlStanza: Equatable {
    public private(set) var fields: [(name: String, value: String)] = []

    public init(fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    /// The value of a field, matched without regard to case. A multi-line
    /// value keeps its continuation lines, without their leading space.
    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func == (lhs: ControlStanza, rhs: ControlStanza) -> Bool {
        lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    mutating func append(name: String, value: String) {
        fields.append((name: name, value: value))
    }

    mutating func continueLast(with line: Substring) {
        guard !fields.isEmpty else { return }
        fields[fields.count - 1].value += "\n" + line.dropFirst()
    }
}

public enum ControlFile {
    /// Splits text into stanzas at blank lines. Lines that start with "#" are
    /// comments, as deb822 source lists allow.
    public static func stanzas(in text: String) -> [ControlStanza] {
        var stanzas: [ControlStanza] = []
        var current = ControlStanza()
        var started = false
        text.enumerateLines { rawLine, _ in
            let line = Substring(rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if started {
                    stanzas.append(current)
                    current = ControlStanza()
                    started = false
                }
                return
            }
            if line.first == "#" {
                return
            }
            if line.first == " " || line.first == "\t" {
                current.continueLast(with: line)
                return
            }
            guard let colon = line.firstIndex(of: ":") else {
                return
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            current.append(name: name, value: value)
            started = true
        }
        if started {
            stanzas.append(current)
        }
        return stanzas
    }
}
