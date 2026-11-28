// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A security check of one source's packages against the person's other
/// sources and installed packages, from the package index alone. It looks
/// for three things a person should know before installing from a source:
/// packages that another source sells and this one gives away, which are
/// most likely cracked; packages that say they are cracks or cracking tools;
/// and newer copies of the jailbreak's own packages, which the next upgrade
/// would take from this source. It cannot see inside packages, so it says
/// nothing about malware it has no sign of.
public enum SourceScan {
    public struct Finding: Equatable, Identifiable {
        public enum Kind: Equatable {
            /// Sold on the other sources named here; free on this one.
            case paidElsewhere(sellers: [String])
            /// Its name or description says it is a crack or a cracking tool.
            case crack
            /// A system package in a newer version than any other source has.
            case replacesSystem(version: String, installed: String?)
        }

        public var kind: Kind
        public var package: String
        public var name: String

        public var id: String {
            switch kind {
            case .paidElsewhere: return "paid\n" + package
            case .crack: return "crack\n" + package
            case .replacesSystem: return "system\n" + package
            }
        }
    }

    /// The packages that make up the jailbreak itself, beside those dpkg
    /// marks as essential. A source that offers a newer one can take it over.
    public static let systemPackages: Set<String> = [
        "apt", "base", "bash", "coreutils", "darwintools", "dash", "dpkg", "ellekit", "essential", "firmware",
        "launchctl", "libhooker", "mobilesubstrate", "procursus-keyring", "sudo", "uikittools", "zsh",
    ]

    private static let crackWords = try! NSRegularExpression(
        pattern: #"\b(crack|cracked|cracker|cracks|cracking)\b|localiapstore|iapcrazy|installous|iap\s*free"#,
        options: [.caseInsensitive])

    /// Checks a source's packages. others holds the other sources' copies of
    /// the same packages, sourceTitles names sources by id, installed holds
    /// installed versions by package, and essential the installed packages
    /// dpkg marks as essential. convertible is the architecture whose builds
    /// apt cannot install as they are (RootlessConversion): they never take
    /// over the jailbreak's own packages in an upgrade.
    public static func scan(packages: [PackageSummary], others: [PackageSummary], sourceTitles: [String: String],
                            installed: [String: String], essential: Set<String>,
                            convertible: String? = nil) -> [Finding] {
        let mine = newestByPackage(packages)
        var othersByPackage: [String: [PackageSummary]] = [:]
        for offer in others where !mine.isEmpty {
            othersByPackage[offer.package, default: []].append(offer)
        }
        var findings: [Finding] = []
        for package in mine.keys.sorted() {
            guard let summary = mine[package] else { continue }
            let name = summary.displayName
            let elsewhere = othersByPackage[package] ?? []

            if !isCommercial(summary) {
                let sellers = Set(elsewhere.filter(isCommercial).map { sourceTitles[$0.source] ?? $0.source })
                if !sellers.isEmpty {
                    findings.append(Finding(kind: .paidElsewhere(sellers: sellers.sorted()), package: package, name: name))
                }
            }

            let text = [summary.name, summary.summary, summary.package].compactMap { $0 }.joined(separator: "\n")
            if crackWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                findings.append(Finding(kind: .crack, package: package, name: name))
            }

            let installable = { (offer: PackageSummary) in convertible == nil || offer.architecture != convertible }
            if systemPackages.contains(package) || essential.contains(package) || package.hasPrefix("libapt-pkg"),
               installable(summary) {
                // Only the newest copy anywhere wins an upgrade, and only
                // when another source offers it too: the jailbreak's own.
                let newestElsewhere = elsewhere.filter(installable).map(\.version)
                    .max { DebianVersion($0) < DebianVersion($1) }
                if let newestElsewhere, DebianVersion(summary.version) > DebianVersion(newestElsewhere) {
                    findings.append(Finding(kind: .replacesSystem(version: summary.version, installed: installed[package]),
                                            package: package, name: name))
                }
            }
        }
        return findings
    }

    static func isCommercial(_ summary: PackageSummary) -> Bool {
        PackageCatalog.tags(summary.tag).contains("cydia::commercial")
    }

    static func newestByPackage(_ packages: [PackageSummary]) -> [String: PackageSummary] {
        var newest: [String: PackageSummary] = [:]
        for summary in packages {
            if let current = newest[summary.package], DebianVersion(current.version) >= DebianVersion(summary.version) {
                continue
            }
            newest[summary.package] = summary
        }
        return newest
    }

    /// A line for each finding, as people read them.
    public static func describe(_ finding: Finding) -> String {
        switch finding.kind {
        case .paidElsewhere(let sellers):
            return "\(finding.name): sold on \(sellers.joined(separator: ", ")), free here"
        case .crack:
            return "\(finding.name): says it is a crack or a cracking tool"
        case .replacesSystem(let version, let installed):
            let now = installed.map { ", installed \($0)" } ?? ""
            return "\(finding.name) \(version): newer than your other sources have\(now); the next upgrade would take the jailbreak's \(finding.package) from here"
        }
    }
}
