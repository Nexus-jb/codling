// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A codling:// link from a web page or another app, such as a
/// repository's "Add to Codling" button. A link only opens something for
/// the user to look at: Codling asks before it adds a source, and installs
/// nothing from a link.
///
/// The forms follow the ones other package managers take, so that a page
/// that has buttons for them can add one for Codling the same way:
///
///     codling://source/https://repo.example.com/
///     codling://sources/add/https://repo.example.com/
///     codling://package/com.example.tweak
public enum CodlingLink: Equatable {
    /// A repository to offer to add, as apt's URI.
    case source(String)
    /// A package to show, by identifier.
    case package(String)

    public static let scheme = "codling"

    /// The link in a URL's text. Nil unless it is one of the forms above
    /// with an address or an identifier Codling accepts.
    public init?(_ text: String) {
        guard text.count <= 2048, let separator = text.range(of: "://"),
              text[..<separator.lowerBound].lowercased() == Self.scheme else {
            return nil
        }
        let rest = String(text[separator.upperBound...])
        for (prefix, isSource) in [("source/", true), ("sources/add/", true), ("package/", false)]
        where rest.lowercased().hasPrefix(prefix) {
            var value = String(rest.dropFirst(prefix.count))
            // A page may encode the address once, as a query value is.
            if let decoded = value.removingPercentEncoding, value.contains("%") {
                value = decoded
            }
            if isSource {
                guard value.contains("://"), let uri = SourceList.repositoryURI(from: value) else { return nil }
                self = .source(uri)
            } else {
                if value.hasSuffix("/") {
                    value.removeLast()
                }
                guard PackageOperation.isValidName(value) else { return nil }
                self = .package(value)
            }
            return
        }
        return nil
    }
}
