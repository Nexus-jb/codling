// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One APT source: a repository URI, a suite and its components, as written in
/// /etc/apt/sources.list.d, either one-line (.list) or deb822 (.sources).
public struct Source: Hashable, Identifiable {
    /// The repository URI, always ending in "/".
    public let uri: String
    /// "./" (or another path ending in "/") for a flat repository, else a
    /// distribution such as "1900" or "stable".
    public let suite: String
    public let components: [String]
    /// Keyring files given with Signed-By; empty means the trusted keyrings.
    public let signedBy: [String]
    /// Trusted: yes, or [trusted=yes]: no signature is needed.
    public let trusted: Bool
    /// The file it was read from.
    public let file: String

    public init(uri: String, suite: String, components: [String], signedBy: [String] = [], trusted: Bool = false, file: String = "") {
        self.uri = uri.hasSuffix("/") ? uri : uri + "/"
        self.suite = suite
        self.components = components
        self.signedBy = signedBy
        self.trusted = trusted
        self.file = file
    }

    public var id: String {
        ([uri, suite] + components).joined(separator: " ")
    }

    /// A flat repository keeps its indexes beside its Release file, with no
    /// dists/ tree and no components.
    public var isFlat: Bool {
        suite.hasSuffix("/")
    }

    /// The host, for display and grouping.
    public var host: String {
        URL(string: uri)?.host ?? uri
    }

    /// The directory that holds Release, InRelease and Release.gpg, as apt
    /// names it: a flat suite is appended as written ("https://havoc.app/./"),
    /// a distribution goes under dists/.
    public var releaseDirectory: String {
        isFlat ? uri + suite : uri + "dists/" + suite + "/"
    }

    /// The same directory as a request URL, without "./" segments.
    public var releaseDirectoryURL: URL? {
        URL(string: Self.removingDotSegments(releaseDirectory))
    }

    /// The paths of the package indexes, relative to the release directory
    /// and without a compression suffix, as Release files list them.
    public func packageIndexPaths(architecture: String) -> [String] {
        if isFlat {
            return ["Packages"]
        }
        return components.map { "\($0)/binary-\(architecture)/Packages" }
    }

    static func removingDotSegments(_ url: String) -> String {
        var result = url
        while let range = result.range(of: "/./") {
            result.replaceSubrange(range, with: "/")
        }
        return result
    }
}

public enum SourceList {
    /// The file Codling adds sources to, in sources.list.d. It removes a
    /// source from whichever file lists it.
    public static let codlingFileName = "codling.sources"

    /// A repository address as people type it, as apt's URI: https:// when no
    /// scheme is given, the scheme and host in lower case, and a trailing
    /// "/". nil when it is not an http or https address of a host, or holds
    /// characters the root helper does not write: the helper checks the same.
    public static func repositoryURI(from text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "https://" was already in the field when an address was pasted
        // after it.
        for prefix in ["https://", "http://"] where address.lowercased().hasPrefix(prefix) {
            let rest = address.dropFirst(prefix.count)
            if rest.lowercased().hasPrefix("https://") || rest.lowercased().hasPrefix("http://") {
                address = String(rest)
            }
        }
        if !address.contains("://") {
            address = "https://" + address
        }
        guard let separator = address.range(of: "://") else {
            return nil
        }
        let scheme = address[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else {
            return nil
        }
        let rest = address[separator.upperBound...]
        let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<hostEnd].lowercased()
        var path = String(rest[hostEnd...])
        let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(hostCharacters.contains),
              !host.hasPrefix("."), !host.hasPrefix("-"), !host.hasSuffix("."), host.contains(".") else {
            return nil
        }
        if !path.hasSuffix("/") {
            path += "/"
        }
        let pathCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~/%+-")
        guard path.allSatisfy(pathCharacters.contains),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return nil
        }
        let uri = scheme + "://" + host + path
        return uri.count <= 512 ? uri : nil
    }

    /// The sources in a .sources file (deb822). Stanzas with "Enabled: no",
    /// and types other than deb, are left out.
    public static func parseDeb822(_ text: String, file: String = "") -> [Source] {
        var sources: [Source] = []
        for stanza in ControlFile.stanzas(in: text) {
            if let enabled = stanza["Enabled"], enabled.lowercased() == "no" {
                continue
            }
            let types = words(stanza["Types"])
            guard types.contains("deb") else { continue }
            let uris = words(stanza["URIs"])
            let suites = words(stanza["Suites"])
            let components = words(stanza["Components"])
            let signedBy = keyFiles(stanza["Signed-By"])
            let trusted = stanza["Trusted"]?.lowercased() == "yes"
            for uri in uris {
                for suite in suites {
                    sources.append(Source(uri: uri, suite: suite, components: suite.hasSuffix("/") ? [] : components,
                                          signedBy: signedBy, trusted: trusted, file: file))
                }
            }
        }
        return sources
    }

    /// The sources in a one-line .list file:
    /// `deb [option=value ...] uri suite [component ...]`.
    public static func parseOneLine(_ text: String, file: String = "") -> [Source] {
        var sources: [Source] = []
        text.enumerateLines { rawLine, _ in
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.first == "deb" else { return }
            tokens.removeFirst()
            var signedBy: [String] = []
            var trusted = false
            if let first = tokens.first, first.hasPrefix("[") {
                // Options run to the token that ends with "]".
                var options: [String] = []
                while let token = tokens.first {
                    tokens.removeFirst()
                    options.append(token.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                    if token.hasSuffix("]") { break }
                }
                for option in options where !option.isEmpty {
                    let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    switch pair[0].lowercased() {
                    case "signed-by": signedBy = pair[1].split(separator: ",").map(String.init)
                    case "trusted": trusted = pair[1].lowercased() == "yes"
                    default: break
                    }
                }
            }
            guard tokens.count >= 2 else { return }
            let suite = tokens[1]
            let components = suite.hasSuffix("/") ? [] : Array(tokens.dropFirst(2))
            sources.append(Source(uri: tokens[0], suite: suite, components: components,
                                  signedBy: signedBy, trusted: trusted, file: file))
        }
        return sources
    }

    /// Every source apt reads under an etc/apt directory: sources.list, then
    /// the files in sources.list.d in name order. The same source written twice
    /// is kept once.
    /// The repository addresses in copied text, such as one address per
    /// line or the lines of a sources.list, in order and each once.
    public static func repositoryURIs(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "\"" || $0 == "'" })
            .filter { $0.contains(".") && $0 != "./" }
            .compactMap { repositoryURI(from: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    /// A repository's name from its Release or InRelease file: its Label,
    /// else its Origin.
    public static func releaseName(_ text: String) -> String? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            for key in ["Label", "Origin"] where line.hasPrefix(key + ":") && fields[key] == nil {
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    fields[key] = value
                }
            }
        }
        return fields["Label"] ?? fields["Origin"]
    }

    public static func read(aptDirectory: String, fileManager: FileManager = .default) -> [Source] {
        var files: [String] = []
        let main = aptDirectory + "/sources.list"
        if fileManager.fileExists(atPath: main) {
            files.append(main)
        }
        let directory = aptDirectory + "/sources.list.d"
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        for name in names.sorted() where name.hasSuffix(".list") || name.hasSuffix(".sources") {
            files.append(directory + "/" + name)
        }
        var seen = Set<String>()
        var sources: [Source] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let parsed = file.hasSuffix(".sources") ? parseDeb822(text, file: file) : parseOneLine(text, file: file)
            for source in parsed where seen.insert(source.id).inserted {
                sources.append(source)
            }
        }
        return sources
    }

    private static func words(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// Signed-By holds key file paths, or a whole armored key; only paths are
    /// kept.
    private static func keyFiles(_ value: String?) -> [String] {
        guard let value, !value.contains("BEGIN PGP") else { return [] }
        return words(value)
    }
}
