// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a package leaves behind when it is removed: dpkg removes the files
/// the package brought, but not the preferences its settings page wrote nor
/// the files the tweak made while it ran. They are found before the
/// removal, so that the user can choose to remove them too.
///
/// A leftover is an entry in the user's data folders whose name starts with
/// the package's identifier, a preference domain its settings page names,
/// or the name of one of its own libraries or preference bundles.
/// Never Apple's, never one that matches another installed package more
/// closely, and never anything that may hold an activation (a license, a
/// serial, a key, a token): those are kept, whatever source the package came
/// from, so that removing leftovers never loses a purchase.
public struct SettingsLeftovers: Equatable {
    public struct Item: Equatable {
        public enum Kind: Equatable {
            /// A preferences file, removed through the preferences daemon.
            case preferences(domain: String)
            case file
            case folder
        }

        public let kind: Kind
        public let path: String
        /// It may hold an activation, or Codling could not tell: it stays.
        public let mayHoldActivation: Bool

        public init(kind: Kind, path: String, mayHoldActivation: Bool) {
            self.kind = kind
            self.path = path
            self.mayHoldActivation = mayHoldActivation
        }

        /// The path from the user's Library or home, as
        /// Caches/com.example.tweak.
        public var shortName: String {
            for marker in ["/var/mobile/Library/", "/var/mobile/"] {
                if let range = path.range(of: marker) {
                    return String(path[range.upperBound...])
                }
            }
            return path
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// What removing the leftovers removes.
    public var removable: [Item] { items.filter { !$0.mayHoldActivation } }
    /// What it keeps, because it may hold an activation.
    public var kept: [Item] { items.filter(\.mayHoldActivation) }
    public var isEmpty: Bool { items.isEmpty }

    /// The folders, under /var/mobile, where tweaks keep what they make. On
    /// a rootless jailbreak the same folders also exist under the
    /// jailbreak's root, where the preferences daemon keeps tweaks'
    /// preferences, as /var/jb/var/mobile/Library/Preferences.
    public static let dataFolders = [
        "/var/mobile/Library/Preferences",
        "/var/mobile/Library/Caches",
        "/var/mobile/Library/Application Support",
        "/var/mobile/Library",
        "/var/mobile/Documents",
    ]

    public static let preferencesFolder = "/var/mobile/Library/Preferences"

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

    /// The names the package's leftovers start with, in order: its own
    /// identifier, then the domains its settings files name, each once and
    /// only when it qualifies.
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

    /// Names Apple and the system use for folders and files in the user's
    /// data, which a tweak's file of the same name must not reach.
    static let systemNames: Set<String> = [
        "preferences", "caches", "application support", "documents", "library", "logs", "cookies", "webkit",
        "springboard", "safari", "mobile", "settings", "widgets", "keyboard", "keyboards", "media", "photos",
        "mail", "notes", "calendar", "addressbook", "sms", "voicemail", "shortcuts", "backup", "backups", "tweaks",
        "tweak", "prefs", "preference", "bundle", "resources", "assets", "images", "icons", "themes", "default",
    ]

    /// The names of the tweak's own files, from the files dpkg lists for
    /// the package: its libraries, as VersionSpoof from VersionSpoof.dylib,
    /// and its preference bundles, as VersionSpoofPrefs. Only names of six
    /// letters or more that no system folder uses, so a tweak's file named
    /// Settings never reaches Apple's.
    public static func ownFileNames(_ owned: [String]) -> [String] {
        var names: [String] = []
        for path in owned {
            let file = path.split(separator: "/").last.map(String.init) ?? ""
            let name: String
            if file.hasSuffix(".dylib"), path.contains("/DynamicLibraries/") || path.contains("/TweakInject/") {
                name = String(file.dropLast(6))
            } else if file.hasSuffix(".bundle"), path.contains("/PreferenceBundles/") {
                name = String(file.dropLast(7))
            } else {
                continue
            }
            if name.count >= 6, !systemNames.contains(name.lowercased()), name.contains(where: \.isLetter),
               !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// How closely an entry's name matches a name it may start with: the
    /// name's length when the entry is that name, or that name followed by
    /// ".", "_" or "-" (as com.example.tweak.plist or com.example.tweak_log);
    /// zero otherwise. Letter case does not matter.
    public static func match(_ entry: String, _ name: String) -> Int {
        let entry = entry.lowercased(), name = name.lowercased()
        guard !name.isEmpty else { return 0 }
        if entry == name || [".", "_", "-"].contains(where: { entry.hasPrefix(name + $0) }) {
            return name.count
        }
        return 0
    }

    /// Whether an entry in a data folder is the package's: it matches one
    /// of the package's names, and no other installed package matches it as
    /// closely, so com.example.tweak.addon stays with com.example.tweak.addon.
    public static func belongs(_ entry: String, to names: [String], package: String, otherPackages: Set<String>) -> Bool {
        guard !entry.hasPrefix(".") else { return false }
        let own = names.map { match(entry, $0) }.max() ?? 0
        guard own > 0 else { return false }
        let other = otherPackages.filter { $0 != package }.map { match(entry, $0) }.max() ?? 0
        return own > other
    }

    /// Words that name an activation, in a key or in a name.
    static let activationMarkers = ["licen", "activat", "serial", "registr", "purchas", "drm", "token", "unlock",
                                    "receipt", "udid", "entitle"]

    /// Whether a name says it holds an activation, as
    /// com.example.tweak.license, NexusLicense or com.example.serialkey do.
    public static func nameSuggestsActivation(_ name: String) -> Bool {
        let lowered = name.lowercased()
        var stem = lowered
        for ext in [".plist", ".json", ".txt", ".log", ".dat"] where stem.hasSuffix(ext) {
            stem.removeLast(ext.count)
        }
        return activationMarkers.contains { lowered.contains($0) } || stem.hasSuffix("key")
            || stem.contains("key.") || stem.contains("key_") || stem.hasSuffix("code")
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
        return keys.contains { key in
            let lowered = key.lowercased()
            return activationMarkers.contains { lowered.contains($0) } || lowered.hasSuffix("key")
                || lowered.hasSuffix("code")
        }
    }

    /// The most of a file Codling reads to tell whether it holds an
    /// activation.
    public static let contentLimit = 256 * 1024

    /// Whether a file may hold an activation, from its name and bytes. A
    /// property list is judged by its keys; anything else by the words a
    /// license or a purchase leaves in it. A file larger than Codling reads
    /// is judged by its extension: data and text it cannot read through
    /// stay, pictures and logs do not.
    public static func fileMayHoldActivation(name: String, size: Int, data: Data?) -> Bool {
        if nameSuggestsActivation(name) {
            return true
        }
        let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]).lowercased() } ?? ""
        guard size <= contentLimit, let data else {
            return ["plist", "json", "txt", "dat", "db", "sqlite", "key", "lic", "bin", ""].contains(ext)
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           plist is [String: Any] || plist is [Any] {
            return mayHoldActivation(plist)
        }
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return ["licen", "activat", "receipt", "purchas", "drm"].contains { text.contains($0) }
    }
}
