// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class SourceScanTests: XCTestCase {
    func summary(_ source: String, _ package: String, _ version: String = "1.0", name: String? = nil,
                 summary: String? = nil, tag: String? = nil) -> PackageSummary {
        PackageSummary(source: source, package: package, version: version, name: name, summary: summary, tag: tag)
    }

    func testFindings() {
        let new = "new"
        let packages = [
            summary(new, "com.dev.paid", name: "Paid Tweak"),
            summary(new, "com.dev.paid", "0.9", name: "Paid Tweak"),
            summary(new, "com.dev.free", name: "Free Tweak"),
            summary(new, "com.dev.alsosold", name: "Also Sold", tag: "cydia::commercial"),
            summary(new, "com.pirate.tool", name: "Ultimate IAP Cracker", summary: "Get in-app purchases"),
            summary(new, "com.other.patcher", name: "Patcher", summary: "Cracked version of a tweak"),
            summary(new, "com.dev.crackle", name: "Crackle", summary: "Fireplace sounds"),
            summary(new, "dpkg", "1.99", name: "dpkg"),
            summary(new, "bash", "5.0", name: "bash"),
            summary(new, "zsh", "5.9"),
            summary(new, "com.dev.essential", "2.0"),
        ]
        let others = [
            summary("chariz", "com.dev.paid", "1.2", tag: "purpose::extension, cydia::commercial"),
            summary("havoc", "com.dev.paid", "1.2", tag: "cydia::commercial"),
            summary("havoc", "com.dev.free"),
            summary("havoc", "com.dev.alsosold", tag: "cydia::commercial"),
            summary("procursus", "dpkg", "1.21.21"),
            summary("procursus", "bash", "5.2"),
            summary("procursus", "com.dev.essential", "1.0"),
        ]
        let findings = SourceScan.scan(packages: packages, others: others,
                                       sourceTitles: ["chariz": "Chariz", "havoc": "Havoc"],
                                       installed: ["dpkg": "1.21.21", "com.dev.essential": "1.0"],
                                       essential: ["com.dev.essential"])
        let lines = findings.map(SourceScan.describe)
        XCTAssertEqual(lines, [
            "com.dev.essential 2.0: newer than your other sources have, installed 1.0; the next upgrade would take the jailbreak's com.dev.essential from here",
            "Paid Tweak: sold on Chariz, Havoc, free here",
            "Patcher: says it is a crack or a cracking tool",
            "Ultimate IAP Cracker: says it is a crack or a cracking tool",
            // 1.99 is newer than 1.21.21: 99 is more than 21.
            "dpkg 1.99: newer than your other sources have, installed 1.21.21; the next upgrade would take the jailbreak's dpkg from here",
        ])
    }

    func testSystemPackages() {
        let others = [summary("procursus", "dpkg", "1.21.21"), summary("procursus", "apt", "2.7.0")]
        // A newer dpkg than the jailbreak's source has.
        var findings = SourceScan.scan(packages: [summary("new", "dpkg", "1.22.0")], others: others,
                                       sourceTitles: [:], installed: ["dpkg": "1.21.21"], essential: [])
        XCTAssertEqual(findings.map(\.kind), [.replacesSystem(version: "1.22.0", installed: "1.21.21")])
        // The same or an older one is not taken on upgrade.
        findings = SourceScan.scan(packages: [summary("new", "dpkg", "1.21.21"), summary("new", "apt", "2.6.1")],
                                   others: others, sourceTitles: [:], installed: [:], essential: [])
        XCTAssertEqual(findings, [])
        // The jailbreak's own source, the only one with apt, is not flagged.
        findings = SourceScan.scan(packages: [summary("procursus", "apt", "2.7.0")], others: [],
                                   sourceTitles: [:], installed: ["apt": "2.6.1"], essential: [])
        XCTAssertEqual(findings, [])
    }

    func testCleanSource() {
        let findings = SourceScan.scan(packages: [summary("opa", "com.opa334.choicy", name: "Choicy")],
                                       others: [summary("havoc", "com.other.tweak", tag: "cydia::commercial")],
                                       sourceTitles: [:], installed: [:], essential: [])
        XCTAssertEqual(findings, [])
    }
}
