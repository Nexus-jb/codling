// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A repository's Release file: what it is, and the size and checksums of the
/// index files it lists.
public struct ReleaseFile {
    public struct Entry: Equatable {
        public var size: Int64
        /// Lowercase hex digests by algorithm: "SHA256", "SHA512", "SHA1", "MD5Sum".
        public var digests: [String: String]
    }

    public let stanza: ControlStanza
    /// Index files by their path relative to the release directory.
    public let entries: [String: Entry]

    public init?(text: String) {
        guard let stanza = ControlFile.stanzas(in: text).first else {
            return nil
        }
        self.stanza = stanza
        var entries: [String: Entry] = [:]
        for algorithm in ["MD5Sum", "SHA1", "SHA256", "SHA512"] {
            guard let list = stanza[algorithm] else { continue }
            for line in list.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3, let size = Int64(parts[1]) else { continue }
                let path = String(parts[2])
                var entry = entries[path] ?? Entry(size: size, digests: [:])
                entry.digests[algorithm] = parts[0].lowercased()
                entries[path] = entry
            }
        }
        self.entries = entries
    }

    public var origin: String? { stanza["Origin"] }
    public var label: String? { stanza["Label"] }
    public var suite: String? { stanza["Suite"] }
    public var codename: String? { stanza["Codename"] }
    public var description: String? { stanza["Description"] }

    /// The compressed forms Codling reads, in the order it prefers them:
    /// smallest download first.
    public static let compressions = ["xz", "bz2", "gz", ""]

    /// The listed form of an index to download: the first of compressions
    /// that the Release file lists, with its entry.
    public func preferredFile(for indexPath: String) -> (path: String, compression: String, entry: Entry)? {
        for compression in Self.compressions {
            let path = compression.isEmpty ? indexPath : indexPath + "." + compression
            if let entry = entries[path] {
                return (path, compression, entry)
            }
        }
        return nil
    }
}
