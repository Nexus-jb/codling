// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

/// Finds what packages leave behind, before they are removed, and removes
/// what the user chose once they are gone. Codling runs as the user mobile,
/// who owns the user's data it removes; what mobile cannot remove is said,
/// not forced, and nothing is removed through the root helper.
enum SettingsCleanup {
    /// The most entries Codling looks through inside one leftover folder to
    /// tell whether it holds an activation; a larger folder stays.
    private static let folderLimit = 400

    /// What each package would leave behind. statusPath is dpkg's status
    /// file; its info directory beside it lists each package's files.
    static func find(packages: [String], statusPath: String?, installed: Set<String>) -> [String: SettingsLeftovers] {
        guard let statusPath else { return [:] }
        let dpkg = (statusPath as NSString).deletingLastPathComponent
        let info = (dpkg as NSString).appendingPathComponent("info")
        // The jailbreak's root, for dpkg lists that name files under it, and
        // where a rootless jailbreak keeps tweaks' preferences.
        let root = dpkg.replacingOccurrences(of: "/var/lib/dpkg", with: "")
        let folders = SettingsLeftovers.dataFolders.flatMap { root.isEmpty ? [$0] : [root + $0, $0] }
        let nested = SettingsLeftovers.nestedDataFolders.flatMap { root.isEmpty ? [$0] : [root + $0, $0] }

        var found: [String: SettingsLeftovers] = [:]
        for package in packages {
            let list = (info as NSString).appendingPathComponent("\(package).list")
            let owned = ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            let settings = owned.filter(SettingsLeftovers.isSettingsFile).compactMap { readPlist(path($0, root: root)) }
            let domains = SettingsLeftovers.candidateDomains(package: package, settingsPlists: settings,
                                                             otherPackages: installed)
            let names = domains + SettingsLeftovers.ownFileNames(owned)
            let ownedPaths = Set(owned)

            var items: [SettingsLeftovers.Item] = []
            func belongs(_ entry: String) -> Bool {
                SettingsLeftovers.belongs(entry, to: names, package: package, otherPackages: installed)
            }
            func look(in folder: String) {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
                for entry in entries.sorted() where belongs(entry) {
                    let full = (folder as NSString).appendingPathComponent(entry)
                    // dpkg removes what the package brought itself.
                    guard !ownedPaths.contains(full), let item = item(full, entry: entry, folder: folder, domains: domains),
                          !items.contains(where: { $0.path == item.path }) else { continue }
                    items.append(item)
                }
            }
            folders.forEach(look(in:))
            // A tweak also writes inside the folders of the processes it runs
            // in, as Caches/com.apple.itunesstored/VersionSpoof.log: one level
            // down, only entries named after the package are taken.
            for folder in nested {
                guard let subfolders = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for subfolder in subfolders.sorted() where !belongs(subfolder) {
                    let full = (folder as NSString).appendingPathComponent(subfolder)
                    if let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType,
                       type == .typeDirectory {
                        look(in: full)
                    }
                }
            }
            if !items.isEmpty {
                found[package] = SettingsLeftovers(items: items)
            }
        }
        return found
    }

    /// Removes a leftover file or folder. A preferences file is removed
    /// as it is, without asking the preferences daemon to empty it (which
    /// would make the daemon write it back, empty, a few seconds later);
    /// then the user's preferences daemon is asked to quit, so that it
    /// forgets what it cached and nothing writes the file back. The file is
    /// removed again if it comes back. Returns why it failed.
    static func remove(_ item: SettingsLeftovers.Item) async -> String? {
        guard case .preferences = item.kind else {
            return removeEntry(item.path)
        }
        if let problem = removeEntry(item.path) {
            return problem
        }
        stopPreferencesDaemon()
        var goneFor = 0
        for _ in 0..<12 {
            if exists(item.path) {
                goneFor = 0
                if let problem = removeEntry(item.path) {
                    return problem
                }
            } else {
                goneFor += 1
                if goneFor == 3 {
                    return nil
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return exists(item.path) ? "it came back; restart SpringBoard and remove the package's leftovers again" : nil
    }

    /// Asks the preferences daemon that serves the user mobile, as Codling
    /// runs, to quit. SIGTERM lets it save what other apps changed first;
    /// launchd starts it again when it is next needed.
    private static func stopPreferencesDaemon() {
        for process in Respring.processes(named: "cfprefsd") where process.user == getuid() {
            kill(process.pid, SIGTERM)
        }
    }

    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func removeEntry(_ path: String) -> String? {
        guard exists(path) else { return nil }
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A leftover entry, and whether it may hold an activation. A link is
    /// never followed nor taken.
    private static func item(_ path: String, entry: String, folder: String,
                             domains: [String]) -> SettingsLeftovers.Item? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return nil }
        switch type {
        case .typeDirectory:
            return .init(kind: .folder, path: path, mayHoldActivation: folderMayHoldActivation(path, name: entry))
        case .typeRegular:
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let data = size <= SettingsLeftovers.contentLimit ? FileManager.default.contents(atPath: path) : nil
            let holds = SettingsLeftovers.fileMayHoldActivation(name: entry, size: size, data: data)
            if folder.hasSuffix(SettingsLeftovers.preferencesFolder), entry.hasSuffix(".plist"),
               domains.contains(String(entry.dropLast(6))) {
                return .init(kind: .preferences(domain: String(entry.dropLast(6))), path: path, mayHoldActivation: holds)
            }
            return .init(kind: .file, path: path, mayHoldActivation: holds)
        default:
            return nil
        }
    }

    /// Whether anything inside a folder may hold an activation; a folder
    /// too large to look through, or with a link inside, counts too.
    private static func folderMayHoldActivation(_ folder: String, name: String) -> Bool {
        if SettingsLeftovers.nameSuggestsActivation(name) {
            return true
        }
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return true }
        var seen = 0
        while let relative = walker.nextObject() as? String {
            seen += 1
            if seen > folderLimit {
                return true
            }
            let full = (folder as NSString).appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: full),
                  let type = attributes[.type] as? FileAttributeType else { return true }
            let entry = (relative as NSString).lastPathComponent
            switch type {
            case .typeDirectory:
                if SettingsLeftovers.nameSuggestsActivation(entry) {
                    return true
                }
            case .typeRegular:
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let data = size <= SettingsLeftovers.contentLimit ? FileManager.default.contents(atPath: full) : nil
                if SettingsLeftovers.fileMayHoldActivation(name: entry, size: size, data: data) {
                    return true
                }
            default:
                return true
            }
        }
        return false
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
