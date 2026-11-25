// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The settings a package leaves behind when it is removed: dpkg removes
/// the files the package brought, but not the preferences its settings page
/// wrote. They are found before the removal, from the package's own
/// settings files, so that the user can choose to remove them too.
///
/// Only a preference domain the package itself names, from its own vendor,
/// qualifies; never Apple's, nor one that belongs to another installed
/// package. A domain whose file may hold an activation (a license, a serial,
/// a token) is kept, so that removing settings never loses a purchase.
public struct SettingsLeftovers: Equatable {
    public struct Domain: Equatable {
        /// The preference domain, such as com.example.tweak.
        public let name: String
        /// Its file under the user's preferences.
        public let file: String
        /// The file has a key that looks like an activation, or could not be
        /// read: Codling keeps it.
        public let mayHoldActivation: Bool

        public init(name: String, file: String, mayHoldActivation: Bool) {
            self.name = name
            self.file = file
            self.mayHoldActivation = mayHoldActivation
        }
    }

    public var domains: [Domain]

    public init(domains: [Domain]) {
        self.domains = domains
    }

    /// What removing the settings removes.
    public var removable: [Domain] { domains.filter { !$0.mayHoldActivation } }
    /// What it keeps, because it may hold an activation.
    public var kept: [Domain] { domains.filter(\.mayHoldActivation) }
    public var isEmpty: Bool { domains.isEmpty }

    /// Where the user's preferences live, for Codling and for tweaks.
    public static let preferencesDirectory = "/var/mobile/Library/Preferences"

    public static func file(for domain: String) -> String {
        "\(preferencesDirectory)/\(domain).plist"
    }

    /// A file of the package that describes its settings page: a
    /// PreferenceLoader entry or a plist inside its preference bundle.
    public static func isSettingsFile(_ path: String) -> Bool {
        guard path.hasSuffix(".plist") else { return false }
        return path.contains("/Library/PreferenceLoader/Preferences/") || path.contains("/Library/PreferenceBundles/")
    }

    /// Every "defaults" a settings page names: the domain each of its
    /// switches and fields writes to.
    public static func namedDomains(in plist: Any) -> [String] {
        var found: [String] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let domain = dictionary["defaults"] as? String {
                    found.append(domain)
                }
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(plist)
        return found
    }

    /// The domains the package's settings could live in, in order: its own
    /// identifier, then those its settings files name, each once and only
    /// when it qualifies.
    public static func candidateDomains(package: String, settingsPlists: [Any], otherPackages: Set<String>) -> [String] {
        var result: [String] = []
        for domain in [package] + settingsPlists.flatMap(namedDomains) where !result.contains(domain) {
            if qualifies(domain, package: package, otherPackages: otherPackages) {
                result.append(domain)
            }
        }
        return result
    }

    /// A domain the package may own: a plain reverse-DNS name, not Apple's,
    /// from the package's own vendor, and not another installed package's.
    public static func qualifies(_ domain: String, package: String, otherPackages: Set<String>) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !domain.isEmpty, domain.count <= 200, domain.allSatisfy(allowed.contains),
              domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else {
            return false
        }
        let lowered = domain.lowercased()
        if lowered.hasPrefix("com.apple.") || lowered.hasPrefix(".globalpreferences") {
            return false
        }
        for other in otherPackages where other != package {
            if domain == other || domain.hasPrefix(other + ".") {
                return false
            }
        }
        if domain == package || domain.hasPrefix(package + ".") {
            return true
        }
        // The same vendor: the first two labels match, as com.example in
        // com.example.tweak and com.example.tweakprefs.
        let vendor = package.split(separator: ".").prefix(2)
        return vendor.count == 2 && Array(domain.split(separator: ".").prefix(2)) == Array(vendor)
    }

    /// Whether a preferences file may hold an activation: any key, at the
    /// top or one level down, that names a license, a serial, a token or a
    /// purchase, or ends in "key" or "code". A file that is not a dictionary
    /// counts too, since Codling cannot tell.
    public static func mayHoldActivation(_ plist: Any?) -> Bool {
        guard let dictionary = plist as? [String: Any] else { return true }
        var keys = Array(dictionary.keys)
        for value in dictionary.values {
            if let inner = value as? [String: Any] {
                keys.append(contentsOf: inner.keys)
            }
        }
        let markers = ["licen", "activat", "serial", "registr", "purchas", "drm", "token", "unlock", "receipt", "udid", "entitle"]
        return keys.contains { key in
            let lowered = key.lowercased()
            return markers.contains { lowered.contains($0) } || lowered.hasSuffix("key") || lowered.hasSuffix("code")
        }
    }
}
