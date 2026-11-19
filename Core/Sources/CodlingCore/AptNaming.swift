// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum AptNaming {
    /// The name apt gives the local copy of a downloaded file in its lists
    /// directory: the URL without its scheme and credentials, with some
    /// characters percent-encoded and every "/" made "_". For example
    /// https://havoc.app/./Packages becomes havoc.app_._Packages.
    public static func listFileName(for url: String) -> String {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
        }
        // Credentials end at the "@" before the first "/".
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        if let at = rest[..<authorityEnd].lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        let quoted = "\\|{}[]<>\"^~_=!@#$%&*"
        var name = ""
        for byte in rest.utf8 {
            let character = Character(Unicode.Scalar(byte))
            if byte <= 0x20 || byte >= 0x7F || quoted.contains(character) {
                name += String(format: "%%%02x", byte)
            } else if character == "/" {
                name += "_"
            } else {
                name.append(character)
            }
        }
        return name
    }
}
