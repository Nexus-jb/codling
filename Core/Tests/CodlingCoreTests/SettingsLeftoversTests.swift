// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class SettingsLeftoversTests: XCTestCase {
    private let rootPlist: [String: Any] = [
        "title": "Tweak",
        "items": [
            ["cell": "PSSwitchCell", "defaults": "com.example.tweak", "key": "enabled"],
            ["cell": "PSSwitchCell", "defaults": "com.example.tweakprefs", "key": "hideLabels"],
            ["cell": "PSSwitchCell", "defaults": "com.apple.springboard", "key": "SBShowGestures"],
            ["cell": "PSLinkListCell", "defaults": "com.other.vendor", "key": "mode"],
            ["cell": "PSGroupCell", "label": "About"],
        ] as [Any],
    ]

    func testSettingsFiles() {
        XCTAssertTrue(SettingsLeftovers.isSettingsFile("/var/jb/Library/PreferenceBundles/Tweak.bundle/Root.plist"))
        XCTAssertTrue(SettingsLeftovers.isSettingsFile("/var/jb/Library/PreferenceLoader/Preferences/Tweak.plist"))
        XCTAssertFalse(SettingsLeftovers.isSettingsFile("/var/jb/Library/MobileSubstrate/DynamicLibraries/Tweak.plist"))
        XCTAssertFalse(SettingsLeftovers.isSettingsFile("/var/jb/Library/PreferenceBundles/Tweak.bundle/Tweak"))
    }

    func testCandidatesKeepTheVendorsAndDropApplesAndOthers() {
        let domains = SettingsLeftovers.candidateDomains(package: "com.example.tweak", settingsPlists: [rootPlist],
                                                         otherPackages: ["com.example.tweak", "preferenceloader"])
        XCTAssertEqual(domains, ["com.example.tweak", "com.example.tweakprefs"])
    }

    func testAnotherInstalledPackagesDomainIsNotTaken() {
        XCTAssertFalse(SettingsLeftovers.qualifies("com.example.dock", package: "com.example.tweak",
                                                   otherPackages: ["com.example.dock"]))
        XCTAssertFalse(SettingsLeftovers.qualifies("com.example.dock.prefs", package: "com.example.tweak",
                                                   otherPackages: ["com.example.dock"]))
        XCTAssertTrue(SettingsLeftovers.qualifies("com.example.tweak.prefs", package: "com.example.tweak",
                                                  otherPackages: ["com.example.tweak"]))
    }

    func testOddNamesNeverQualify() {
        for domain in ["", ".GlobalPreferences", "com.apple.UIKit", "../com.example.tweak", "com.example/tweak",
                       "com..example", "com.example.", "tweak"] {
            XCTAssertFalse(SettingsLeftovers.qualifies(domain, package: "com.example.tweak", otherPackages: []), domain)
        }
    }

    func testPackageWithoutVendorOnlyOwnsItsOwnName() {
        XCTAssertFalse(SettingsLeftovers.qualifies("tweak", package: "tweak", otherPackages: []))
        XCTAssertTrue(SettingsLeftovers.qualifies("tweak.prefs", package: "tweak", otherPackages: []))
        XCTAssertFalse(SettingsLeftovers.qualifies("other.prefs", package: "tweak", otherPackages: []))
    }

    func testActivationKeysKeepTheFile() {
        XCTAssertFalse(SettingsLeftovers.mayHoldActivation(["enabled": true, "hideLabels": false, "color": "red"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["enabled": true, "licenseKey": "ABC"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["Activated": true]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["account": ["serialNumber": "1"]]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["promoCode": "X"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["authToken": "X"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(nil))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["a", "b"]))
    }

    func testActivationNamesKeepTheDomain() {
        for domain in ["com.example.tweak.license", "com.example.tweakLicence", "com.example.activation",
                       "com.example.serial", "com.example.tweakkey", "com.example.key.store", "com.example.drm"] {
            XCTAssertTrue(SettingsLeftovers.nameSuggestsActivation(domain), domain)
        }
        for domain in ["com.example.tweak", "com.example.tweakprefs", "com.example.keyboardtweak"] {
            XCTAssertFalse(SettingsLeftovers.nameSuggestsActivation(domain), domain)
        }
    }

    func testRemovableAndKept() {
        let leftovers = SettingsLeftovers(domains: [
            .init(name: "com.example.tweak", file: SettingsLeftovers.file(for: "com.example.tweak"), mayHoldActivation: false),
            .init(name: "com.example.license", file: SettingsLeftovers.file(for: "com.example.license"), mayHoldActivation: true),
        ])
        XCTAssertEqual(leftovers.removable.map(\.name), ["com.example.tweak"])
        XCTAssertEqual(leftovers.kept.map(\.name), ["com.example.license"])
        XCTAssertEqual(leftovers.removable.first?.file, "/var/mobile/Library/Preferences/com.example.tweak.plist")
    }
}
