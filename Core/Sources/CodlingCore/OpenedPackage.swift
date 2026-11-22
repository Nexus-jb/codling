// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A .deb the user opened in Codling from another app, as its control file
/// describes it. No source vouches for it: the user chose the file, so
/// Codling shows what the package says it is and installs it only when they
/// confirm.
public struct OpenedPackage: Equatable {
    /// Whether the package can be installed on this jailbreak.
    public enum Fit: Equatable {
        case fits
        /// Built for another scheme: iphoneos-arm for rootful jailbreaks,
        /// which Codling does not support, or the other of rootless and
        /// RootHide.
        case otherArchitecture(String)
    }

    public let token: String
    public let package: String
    public let version: String
    public let architecture: String
    public let name: String?
    public let author: String?
    public let maintainer: String?
    public let section: String?
    public let description: String?
    public let depends: String?
    public let conflicts: String?
    public let installedSize: Int64?

    /// The package from the control fields the helper printed, under the
    /// token it kept the file with. Nil unless the token, the name and the
    /// version are ones the helper accepts.
    public init?(token: String, control: String) {
        guard let stanza = ControlFile.stanzas(in: control).first,
              let package = stanza["Package"], let version = stanza["Version"],
              PackageOperation.file(package, token: token).isValid,
              PackageOperation.isValidVersion(version) else {
            return nil
        }
        func field(_ name: String) -> String? {
            stanza[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        self.token = token
        self.package = package
        self.version = version
        architecture = field("Architecture") ?? ""
        name = field("Name")
        author = field("Author")
        maintainer = field("Maintainer")
        section = field("Section")
        description = field("Description")
        depends = field("Pre-Depends").map { [$0, field("Depends")].compactMap { $0 }.joined(separator: ", ") }
            ?? field("Depends")
        conflicts = field("Conflicts")
        installedSize = field("Installed-Size").flatMap { Int64($0) }
    }

    /// The name lists show: the Name field, or the package's identifier.
    public var displayName: String { name ?? package }

    /// The first line of the description.
    public var summary: String? {
        description.flatMap { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) }
    }

    /// The description after its first line, with Debian's "." lines as
    /// blank lines.
    public var details: String? {
        guard let description, let newline = description.firstIndex(of: "\n") else { return nil }
        let lines = description[description.index(after: newline)...].split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) == "." ? "" : String($0) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The author's name without the email address: "Ultra Team
    /// <team@example.com>" is "Ultra Team".
    public var authorName: String? {
        (author ?? maintainer).map { value in
            guard let open = value.firstIndex(of: "<") else { return value }
            let name = value[..<open].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? value : name
        }
    }

    /// Whether this device's package architecture (iphoneos-arm64 rootless,
    /// iphoneos-arm64e with RootHide) can take it. A package without an
    /// Architecture field is left to apt.
    public func fit(deviceArchitecture: String) -> Fit {
        architecture.isEmpty || architecture == "all" || architecture == deviceArchitecture
            ? .fits : .otherArchitecture(architecture)
    }
}
