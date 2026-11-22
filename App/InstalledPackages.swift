// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A package dpkg has installed, read from its status file.
struct InstalledPackage: Identifiable, Hashable {
    let identifier: String
    let fields: [(name: String, value: String)]
    /// When dpkg last installed or upgraded it (InstallDates), when known.
    var installed: Date?

    var id: String { identifier }

    func field(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var name: String { field("Name") ?? identifier }
    var version: String { field("Version") ?? "" }
    var section: String? { field("Section") }
    var author: String? { (field("Author") ?? field("Maintainer")).map(Self.withoutEmail) }

    /// The first line of the description.
    var summary: String {
        (field("Description") ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// The description after its first line, with dpkg's " ." blank lines.
    var details: String {
        let lines = (field("Description") ?? "").split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return lines.map { $0.trimmingCharacters(in: .whitespaces) == "." ? "" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func == (lhs: InstalledPackage, rhs: InstalledPackage) -> Bool {
        lhs.identifier == rhs.identifier && lhs.version == rhs.version
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
        hasher.combine(version)
    }

    /// "Jane Doe <jane@example.com>" becomes "Jane Doe".
    static func withoutEmail(_ person: String) -> String {
        guard let open = person.firstIndex(of: "<") else {
            return person
        }
        let name = person[..<open].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? person : name
    }
}

enum DpkgStatus {
    /// The installed packages in a dpkg status file: stanzas of "Field: value"
    /// lines separated by blank lines, where a line that starts with a space
    /// or tab continues the field above it.
    ///
    /// Packages whose name starts with "gsc." or "cy+" are left out: the
    /// jailbreak creates them to describe the device, and nobody installs or
    /// removes them.
    static func installedPackages(in text: String) -> [InstalledPackage] {
        var packages: [InstalledPackage] = []
        for stanza in text.components(separatedBy: "\n\n") {
            var fields: [(name: String, value: String)] = []
            for line in stanza.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.first == " " || line.first == "\t" {
                    guard !fields.isEmpty else { continue }
                    fields[fields.count - 1].value += "\n" + line.dropFirst()
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields.append((name: name, value: value))
            }
            let field = { (name: String) in fields.first { $0.name == name }?.value }
            guard let identifier = field("Package"), !identifier.isEmpty,
                  let status = field("Status"), status.hasSuffix(" installed"),
                  !identifier.hasPrefix("gsc."), !identifier.hasPrefix("cy+") else {
                continue
            }
            packages.append(InstalledPackage(identifier: identifier, fields: fields))
        }
        return packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class InstalledPackagesModel: ObservableObject {
    enum State {
        case loading
        case loaded([InstalledPackage])
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// The installed version of each package, by identifier.
    @Published private(set) var versions: [String: String] = [:]

    func version(of identifier: String) -> String? {
        versions[identifier]
    }

    /// The installed packages dpkg marks as essential.
    var essential: Set<String> {
        guard case .loaded(let packages) = state else {
            return []
        }
        return Set(packages.filter { $0.field("Essential")?.lowercased() == "yes" }.map(\.identifier))
    }

    func load(statusPath: String?) async {
        guard let statusPath else {
            state = .failed("Codling could not find the jailbreak, so it cannot read the installed packages.")
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[InstalledPackage], Error> in
            Result {
                let data = try Data(contentsOf: URL(fileURLWithPath: statusPath))
                let packages = DpkgStatus.installedPackages(in: String(decoding: data, as: UTF8.self))
                // The file lists sit beside the status file, in info.
                let info = ((statusPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("info")
                let dates = InstallDates.read(infoDirectory: info, identifiers: Set(packages.map(\.identifier)))
                return packages.map { package in
                    var dated = package
                    dated.installed = dates[package.identifier]
                    return dated
                }
            }
        }.value
        switch result {
        case .success(let packages):
            state = .loaded(packages)
            versions = Dictionary(packages.map { ($0.identifier, $0.version) }, uniquingKeysWith: { first, _ in first })
        case .failure(let error):
            state = .failed("Codling could not read \(statusPath): \(error.localizedDescription)")
        }
    }
}
