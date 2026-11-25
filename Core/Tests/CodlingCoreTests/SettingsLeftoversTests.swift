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

    func testOwnFileNames() {
        let owned = [
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/VersionSpoof.dylib",
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/VersionSpoof.plist",
            "/var/jb/Library/PreferenceBundles/VersionSpoofPrefs.bundle",
            "/var/jb/Library/PreferenceBundles/VersionSpoofPrefs.bundle/Root.plist",
            "/var/jb/usr/lib/TweakInject/Dock.dylib",
            "/var/jb/usr/lib/TweakInject/Settings.dylib",
            "/var/jb/usr/lib/libexample.dylib",
        ]
        XCTAssertEqual(SettingsLeftovers.ownFileNames(owned), ["VersionSpoof", "VersionSpoofPrefs"])
    }

    func testEntriesThatBelong() {
        let names = ["com.example.tweak", "com.example.tweakprefs", "VersionSpoof"]
        let others: Set<String> = ["com.example.tweak", "com.example.tweak.addon", "com.example.dock"]
        func belongs(_ entry: String) -> Bool {
            SettingsLeftovers.belongs(entry, to: names, package: "com.example.tweak", otherPackages: others)
        }
        XCTAssertTrue(belongs("com.example.tweak.plist"))
        XCTAssertTrue(belongs("com.example.tweak"))
        XCTAssertTrue(belongs("com.example.tweak_diagnostics.txt"))
        XCTAssertTrue(belongs("com.example.tweak-cache"))
        XCTAssertTrue(belongs("COM.EXAMPLE.TWEAKPREFS.plist"))
        XCTAssertTrue(belongs("VersionSpoof.log"))
        XCTAssertTrue(belongs("VersionSpoof"))
        // Another installed package matches more closely.
        XCTAssertFalse(belongs("com.example.tweak.addon.plist"))
        // Not the same name, only the same beginning.
        XCTAssertFalse(belongs("com.example.tweaker.plist"))
        XCTAssertFalse(belongs("VersionSpoofer"))
        XCTAssertFalse(belongs("com.example.dock.plist"))
        XCTAssertFalse(belongs(".com.example.tweak.plist"))
        XCTAssertFalse(belongs("NexusLicense"))
    }

    func testActivationNames() {
        for name in ["com.example.tweak.license", "com.example.tweakLicence.plist", "com.example.activation",
                     "com.example.serial", "com.example.tweakkey", "com.example.tweakkey.plist", "com.example.key.store",
                     "com.example.drm", "NexusLicense", "com.example.tweak_key.json"] {
            XCTAssertTrue(SettingsLeftovers.nameSuggestsActivation(name), name)
        }
        for name in ["com.example.tweak", "com.example.tweak.plist", "com.example.tweakprefs", "com.example.keyboardtweak"] {
            XCTAssertFalse(SettingsLeftovers.nameSuggestsActivation(name), name)
        }
    }

    func testActivationKeysKeepAPlist() {
        XCTAssertFalse(SettingsLeftovers.mayHoldActivation(["enabled": true, "hideLabels": false, "color": "red"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["enabled": true, "licenseKey": "ABC"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["Activated": true]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["account": ["serialNumber": "1"]]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["promoCode": "X"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["authToken": "X"]))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(nil))
        XCTAssertTrue(SettingsLeftovers.mayHoldActivation(["a", "b"]))
    }

    func testFiles() throws {
        let settings = try PropertyListSerialization.data(fromPropertyList: ["enabled": true], format: .xml, options: 0)
        let licensed = try PropertyListSerialization.data(fromPropertyList: ["licenseKey": "A"], format: .xml, options: 0)
        func holds(_ name: String, _ data: Data?, size: Int? = nil) -> Bool {
            SettingsLeftovers.fileMayHoldActivation(name: name, size: size ?? data?.count ?? 0, data: data)
        }
        XCTAssertFalse(holds("com.example.tweak.plist", settings))
        XCTAssertTrue(holds("com.example.tweak.plist", licensed))
        XCTAssertTrue(holds("com.example.tweak.license", settings))
        XCTAssertFalse(holds("com.example.tweak_diagnostics.txt", Data("iOS 16.3.1, spoofed 17.0, serial port".utf8)))
        XCTAssertTrue(holds("com.example.tweak.json", Data("{\"purchased\": true}".utf8)))
        XCTAssertFalse(holds("com.example.tweak.log", nil, size: 10_000_000))
        XCTAssertTrue(holds("com.example.tweak.db", nil, size: 10_000_000))
    }

    func testShortNames() {
        XCTAssertEqual(SettingsLeftovers.Item(kind: .file, path: "/var/jb/var/mobile/Library/Caches/com.example.tweak",
                                              mayHoldActivation: false).shortName, "Caches/com.example.tweak")
        XCTAssertEqual(SettingsLeftovers.Item(kind: .folder, path: "/var/mobile/Documents/com.example.tweak",
                                              mayHoldActivation: false).shortName, "Documents/com.example.tweak")
    }

    func testRemovableAndKept() {
        let leftovers = SettingsLeftovers(items: [
            .init(kind: .preferences(domain: "com.example.tweak"),
                  path: "/var/mobile/Library/Preferences/com.example.tweak.plist", mayHoldActivation: false),
            .init(kind: .file, path: "/var/mobile/Library/Caches/com.example.tweak.license", mayHoldActivation: true),
        ])
        XCTAssertEqual(leftovers.removable.map(\.shortName), ["Preferences/com.example.tweak.plist"])
        XCTAssertEqual(leftovers.kept.map(\.shortName), ["Caches/com.example.tweak.license"])
    }
}
