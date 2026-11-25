// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

/// Finds the settings packages leave behind, before they are removed, and
/// removes those the user chose once they are gone. Codling runs as the
/// user mobile, who owns the preferences it removes.
enum SettingsCleanup {
    /// The settings of each package, read from the files dpkg lists for it.
    /// statusPath is dpkg's status file; its info directory beside it lists
    /// each package's files.
    static func find(packages: [String], statusPath: String?, installed: Set<String>) -> [String: SettingsLeftovers] {
        guard let statusPath else { return [:] }
        let dpkg = (statusPath as NSString).deletingLastPathComponent
        let info = (dpkg as NSString).appendingPathComponent("info")
        // The jailbreak's root, for dpkg lists that name files under it.
        let root = (statusPath as NSString).deletingLastPathComponent
            .replacingOccurrences(of: "/var/lib/dpkg", with: "")

        var found: [String: SettingsLeftovers] = [:]
        for package in packages {
            let list = (info as NSString).appendingPathComponent("\(package).list")
            let owned = ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            let settings = owned.filter(SettingsLeftovers.isSettingsFile).compactMap { readPlist(path($0, root: root)) }
            let domains = SettingsLeftovers.candidateDomains(package: package, settingsPlists: settings,
                                                             otherPackages: installed)
                .compactMap { domain -> SettingsLeftovers.Domain? in
                    // A rootless jailbreak's preferences daemon keeps tweaks'
                    // preferences under the jailbreak's root.
                    let plain = SettingsLeftovers.file(for: domain)
                    let candidates = root.isEmpty ? [plain] : [root + plain, plain]
                    guard let file = candidates.first(where: FileManager.default.fileExists(atPath:)) else {
                        return nil
                    }
                    return .init(name: domain, file: file,
                                 mayHoldActivation: SettingsLeftovers.nameSuggestsActivation(domain)
                                     || SettingsLeftovers.mayHoldActivation(readPlist(file)))
                }
            if !domains.isEmpty {
                found[package] = SettingsLeftovers(domains: domains)
            }
        }
        return found
    }

    /// Removes a domain through the preferences daemon, so that no process
    /// writes back what it cached, then its file. Returns why it failed.
    static func remove(_ domain: SettingsLeftovers.Domain) -> String? {
        let name = domain.name as CFString
        if let keys = CFPreferencesCopyKeyList(name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           !keys.isEmpty {
            CFPreferencesSetMultiple(nil, keys as CFArray, name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard FileManager.default.fileExists(atPath: domain.file) else { return nil }
        do {
            try FileManager.default.removeItem(atPath: domain.file)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A file dpkg lists: as it is, or under the jailbreak's root when the
    /// list names it from there.
    private static func path(_ listed: String, root: String) -> String {
        if root.isEmpty || FileManager.default.fileExists(atPath: listed) {
            return listed
        }
        return root + listed
    }

    private static func readPlist(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
