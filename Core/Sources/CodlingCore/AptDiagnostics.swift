// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What went wrong in apt or dpkg output, in plain words, and what to do.
public struct AptDiagnosis: Equatable {
    /// A repair Codling can make for the user.
    public enum Fix: Equatable {
        /// dpkg --configure -a: finish setting up packages that were unpacked
        /// or left half configured.
        case configurePending
        /// Refresh the sources.
        case refreshSources
        /// Try the same thing again.
        case retry
    }

    /// A stable name for the problem, such as "dpkg-interrupted".
    public let id: String
    public let title: String
    /// What happened, in plain words.
    public let explanation: String
    /// What the user can do, when Codling cannot do it for them.
    public let advice: String
    public let fix: Fix?
    /// The line of output it was read from.
    public let line: String
}

public enum AptDiagnostics {
    /// The problems in apt or dpkg output, in the order they first appear,
    /// each once.
    public static func diagnose(_ output: String) -> [AptDiagnosis] {
        var found: [AptDiagnosis] = []
        var seen = Set<String>()
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            for rule in rules {
                guard let groups = rule.match(line) else { continue }
                let diagnosis = rule.diagnosis(groups: groups, line: line)
                if seen.insert(diagnosis.id + diagnosis.explanation).inserted {
                    found.append(diagnosis)
                }
                break
            }
        }
        // The generic dpkg failure only matters when nothing more specific
        // explains it.
        if found.count > 1 {
            found.removeAll { $0.id == "dpkg-failed" }
        }
        return found
    }

    /// The parts of dpkg --audit output that are real problems.
    ///
    /// dpkg --audit prints sections: a header, which may wrap, then the
    /// packages, indented, one per line. The section on packages "missing the
    /// md5sums control file" is left out: it lists the packages the jailbreak
    /// makes to describe the device (cy+cpu.arm64, gsc.64-bit, firmware), and
    /// packages built without checksums of their files. Nothing is broken, and
    /// reinstalling them would not change it.
    public static func significantAudit(_ output: String) -> String {
        var sections: [[String]] = [[]]
        for line in output.components(separatedBy: "\n") {
            let indented = line.first == " " || line.first == "\t"
            let current = sections[sections.count - 1]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    sections.append([])
                }
                continue
            }
            // A header after a package line starts the next section, even
            // without a blank line between them.
            if !indented, let last = current.last, last.first == " " || last.first == "\t" {
                sections.append([])
            }
            sections[sections.count - 1].append(line)
        }
        return sections.filter { section in
            guard !section.isEmpty else { return false }
            let header = section.prefix { $0.first != " " && $0.first != "\t" }.joined(separator: " ")
            return !header.contains("missing the md5sums control file")
        }
        .map { $0.joined(separator: "\n") }
        .joined(separator: "\n\n")
    }

    struct Rule {
        let id: String
        let pattern: NSRegularExpression
        let title: String
        /// $1, $2 ... stand for the pattern's groups.
        let explanation: String
        let advice: String
        let fix: AptDiagnosis.Fix?

        init(_ id: String, _ pattern: String, title: String, explanation: String, advice: String,
             fix: AptDiagnosis.Fix? = nil) {
            self.id = id
            // The patterns are written here and tested; a bad one is a bug.
            self.pattern = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.title = title
            self.explanation = explanation
            self.advice = advice
            self.fix = fix
        }

        func match(_ line: String) -> [String]? {
            let range = NSRange(line.startIndex..., in: line)
            guard let result = pattern.firstMatch(in: line, range: range) else { return nil }
            return (0..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
        }

        func diagnosis(groups: [String], line: String) -> AptDiagnosis {
            var text = explanation
            var advice = self.advice
            for index in stride(from: groups.count - 1, to: 0, by: -1) {
                text = text.replacingOccurrences(of: "$\(index)", with: groups[index])
                advice = advice.replacingOccurrences(of: "$\(index)", with: groups[index])
            }
            return AptDiagnosis(id: id, title: title, explanation: text, advice: advice, fix: fix, line: line)
        }
    }

    /// The common problems, most specific first: each line takes the first
    /// rule that matches it.
    static let rules: [Rule] = [
        Rule("dpkg-interrupted", #"dpkg was interrupted"#,
             title: "A package installation was interrupted",
             explanation: "dpkg stopped before it finished setting up the last packages, for example because the app closed or the device restarted.",
             advice: "Finish setting them up. Nothing is downloaded again.",
             fix: .configurePending),
        Rule("half-configured", #"packages are only half configured|have been unpacked but not yet configured|half-configured|not fully installed or removed"#,
             title: "A package was not set up completely",
             explanation: "A package was unpacked, but its setup script did not finish, so it may not work yet.",
             advice: "Finish setting it up. If its setup fails again, the package's developer needs to fix it.",
             fix: .configurePending),
        Rule("needs-reinstall", #"packages are in a mess|only half installed|very bad inconsistent state|needs to be reinstalled"#,
             title: "A package needs to be reinstalled",
             explanation: "A package's files were only partly installed, so dpkg cannot set it up or remove it as it is.",
             advice: "Install the same package again from its source, then try once more."),
        Rule("lock-held", #"(?:could not get lock|unable to acquire the dpkg frontend lock|unable to lock the administration directory).*?(?:held by process (\d+)(?: \(([^)]+)\))?)?\.?$"#,
             title: "Another package manager is busy",
             explanation: "Another app is installing or removing packages right now, so apt has to wait for it.",
             advice: "Let the other app finish, or close it (such as Sileo or Zebra), then try again.",
             fix: .retry),
        Rule("architecture-mismatch", #"package architecture \(([^)]+)\) does not match system \(([^)]+)\)"#,
             title: "The package is built for another jailbreak",
             explanation: "This package is for $1, but this device's jailbreak uses $2. A rootful package cannot work on a rootless jailbreak.",
             advice: "Ask the developer for a $2 version, or look for one in another source."),
        Rule("old-chip", #"needs an Apple A12 chip or newer"#,
             title: "This device is not supported",
             explanation: "The package supports the Apple A12 chip and newer: iPhone XS, iPhone XR and later.",
             advice: "Use it on a newer device."),
        Rule("file-conflict", #"trying to overwrite '([^']+)', which is also in package ([^\s]+)"#,
             title: "Two packages contain the same file",
             explanation: "This package would replace $1, which belongs to $2. dpkg stops so that one package does not break the other.",
             advice: "Remove $2 first if you no longer need it, or ask the developers which package should own the file."),
        Rule("essential-package", #"potentially harmful|essential (?:system-critical )?packages? (?:is|are) not permitted|removing essential"#,
             title: "The change would remove an essential package",
             explanation: "apt stopped because the change would remove a package the system needs to work. Codling never removes essential packages.",
             advice: "Leave that package installed. If a package you want conflicts with it, ask its developer about it."),
        Rule("unauthenticated", #"there were unauthenticated packages"#,
             title: "Some packages are not verified",
             explanation: "They come from sources that are not signed, so apt does not install them without your consent.",
             advice: "Review the change again, and confirm it with the warning it shows."),
        Rule("removals-not-reviewed", #"packages need to be removed but remove is disabled"#,
             title: "The change would remove other packages",
             explanation: "apt found that the change now also removes packages, which the review did not show, so nothing was changed.",
             advice: "Review the change again: the review lists every package that would be removed before you confirm.",
             fix: .retry),
        Rule("unmet-dependencies", #"unmet dependencies|held broken packages|depends: .* but (?:it is not going to be installed|it is not installable)|fix-broken install"#,
             title: "Some packages it needs cannot be installed",
             explanation: "The package depends on other packages that are missing, too old, or in conflict with what is installed.",
             advice: "Refresh your sources so the newest versions are known. If it still fails, a source with the missing package may need to be added.",
             fix: .refreshSources),
        Rule("unknown-package", #"unable to locate package ([^\s]+)"#,
             title: "The package was not found",
             explanation: "None of your sources has $1, as far as the last refresh knows.",
             advice: "Refresh your sources. If it is still missing, add the source that offers it.",
             fix: .refreshSources),
        Rule("hash-mismatch", #"hash sum mismatch|checksum mismatch|does not match its .* checksum"#,
             title: "A download did not match its checksum",
             explanation: "A downloaded file is not the one the source's Release file describes. The source may be in the middle of an update, or the file was changed on the way.",
             advice: "Try again in a few minutes. If it keeps happening, the source's owner should rebuild its index.",
             fix: .retry),
        Rule("missing-key", #"NO_PUBKEY ([0-9A-F]+)|public key is not available"#,
             title: "The source's key is not installed",
             explanation: "The source is signed, but this device does not have the key it was signed with, so the signature cannot be checked.",
             advice: "If the source offers a keyring package, install it. Never add a key you did not get from the source's owner."),
        Rule("bad-signature", #"BADSIG|signatures were invalid|signature does not match"#,
             title: "The source's signature is not valid",
             explanation: "The source's Release file does not match its signature. It may have been changed on the way.",
             advice: "Do not install from this source until its owner fixes it, and try again later."),
        Rule("not-valid-yet", #"is not valid yet|invalid for another"#,
             title: "The device's clock is wrong",
             explanation: "The source's Release file is dated in the future for this device, so the date and time on the device are probably off.",
             advice: "Turn on Set Automatically in Settings, General, Date & Time, then refresh.",
             fix: .refreshSources),
        Rule("expired", #"release file .* is expired|is expired \(invalid since"#,
             title: "The source has not been updated",
             explanation: "The source's Release file has passed its expiry date, so apt no longer trusts it to be current.",
             advice: "Wait for the source's owner to update it. If the device's clock is wrong, set it automatically."),
        Rule("no-network", #"temporary failure resolving|could not resolve|network is unreachable|no route to host|not connected to the internet"#,
             title: "The server could not be reached",
             explanation: "The device could not connect to the source's server.",
             advice: "Check the internet connection, then try again.",
             fix: .retry),
        Rule("refused-download", #"failed to fetch .*(?:401|403)|401\s+unauthorized|403\s+forbidden"#,
             title: "The source refused the download",
             explanation: "The source's server would not give the package. Paid packages need your account with the source.",
             advice: "Buying and downloading paid packages comes in a later version of Codling. Until then, install it with the app you bought it in."),
        Rule("not-found", #"failed to fetch .*(?:404|not found)|404\s+not found"#,
             title: "The server does not have the file",
             explanation: "The source's server answered that the file does not exist. The source may have moved or closed.",
             advice: "Refresh your sources. If it keeps happening, the source may be gone; check its address.",
             fix: .refreshSources),
        Rule("disk-full", #"no space left on device|you don't have enough free space"#,
             title: "The device is out of space",
             explanation: "There is not enough free space to download or install the package.",
             advice: "Free some space, for example by deleting apps or old files, then try again.",
             fix: .retry),
        Rule("damaged-archive", #"not a debian format archive|unexpected end of file|corrupted filesystem tarfile|error reading .* from package|lzma error|zstd error"#,
             title: "The downloaded package is damaged",
             explanation: "The package file is incomplete or is not a package at all, for example because the download was cut off.",
             advice: "Download it again. If it keeps happening, the source has a damaged file.",
             fix: .retry),
        Rule("malformed-sources", #"malformed (?:entry|line|stanza).*(?:list|sources)|type '[^']*' is not known on line"#,
             title: "A sources file has an error",
             explanation: "A file in /etc/apt/sources.list.d has a line apt cannot read, so apt stops before doing anything.",
             advice: "Remove or fix that source in the app that added it."),
        Rule("dpkg-failed", #"sub-process .*dpkg returned an error code|errors were encountered while processing"#,
             title: "dpkg could not finish",
             explanation: "dpkg stopped with an error while installing or removing packages.",
             advice: "Finish setting up the packages that were left. If it fails again, the messages above it say which package caused it.",
             fix: .configurePending),
    ]
}
