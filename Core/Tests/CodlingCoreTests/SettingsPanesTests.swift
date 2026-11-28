// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import CodlingCore

final class SettingsPanesTests: XCTestCase {
    /// CoreFoundation 1953.1, as on iOS 16.
    private let version = 1953.1

    func testEntryFiles() {
        XCTAssertTrue(SettingsPane.isEntryFile("/Library/PreferenceLoader/Preferences/EasySwipePrefs.plist"))
        XCTAssertTrue(SettingsPane.isEntryFile("/var/jb/Library/PreferenceLoader/Preferences/Choicy.plist"))
        XCTAssertFalse(SettingsPane.isEntryFile("/Library/PreferenceLoader/Preferences"))
        XCTAssertFalse(SettingsPane.isEntryFile("/Library/PreferenceBundles/ChoicyPrefs.bundle/Root.plist"))
    }

    func testLabelIsTheIdentifier() {
        let plist: [String: Any] = ["entry": ["bundle": "ChoicyPrefs", "cell": "PSLinkCell", "label": "Choicy",
                                              "isController": true]]
        XCTAssertEqual(SettingsPane.pane(in: plist, coreFoundationVersion: version),
                       SettingsPane(title: "Choicy", identifier: "Choicy"))
    }

    func testIdOverridesTheLabel() {
        let plist: [String: Any] = ["entry": ["label": "Easy Swipe", "id": "EasySwipe"]]
        XCTAssertEqual(SettingsPane.pane(in: plist, coreFoundationVersion: version),
                       SettingsPane(title: "Easy Swipe", identifier: "EasySwipe"))
        let empty: [String: Any] = ["entry": ["label": "Easy Swipe", "id": ""]]
        XCTAssertEqual(SettingsPane.pane(in: empty, coreFoundationVersion: version)?.identifier, "Easy Swipe")
    }

    func testRowsThatOpenNoPage() {
        XCTAssertNil(SettingsPane.pane(in: ["entry": ["cell": "PSLinkCell"]], coreFoundationVersion: version))
        XCTAssertNil(SettingsPane.pane(in: ["entry": ["label": ""]], coreFoundationVersion: version))
        XCTAssertNil(SettingsPane.pane(in: ["items": []], coreFoundationVersion: version))
        XCTAssertNil(SettingsPane.pane(in: ["entry": ["label": "Group", "cell": "PSGroupCell"]],
                                       coreFoundationVersion: version))
        XCTAssertNil(SettingsPane.pane(in: "not a dictionary", coreFoundationVersion: version))
        XCTAssertNotNil(SettingsPane.pane(in: ["entry": ["label": "List", "cell": "PSLinkListCell"]],
                                          coreFoundationVersion: version))
    }

    func testFilter() {
        func pane(_ versions: [Any], key: String = "filter") -> SettingsPane? {
            SettingsPane.pane(in: ["entry": ["label": "Tweak"], key: ["CoreFoundationVersion": versions]],
                              coreFoundationVersion: version)
        }
        XCTAssertNotNil(pane([1900]))
        XCTAssertNotNil(pane([1953.1]))
        XCTAssertNil(pane([2000]))
        XCTAssertNotNil(pane([1900, 2000]))
        XCTAssertNil(pane([1900, 1953.1]))
        XCTAssertNotNil(pane(["1900", "2000.0"]))
        XCTAssertNotNil(pane([1900], key: "pl_filter"))
        XCTAssertNil(pane([2000], key: "pl_filter"))
        XCTAssertNil(pane([]))
        XCTAssertNil(pane(["new"]))
        // A filter without CoreFoundationVersion leaves the entry in.
        XCTAssertNotNil(SettingsPane.pane(in: ["entry": ["label": "Tweak"], "filter": ["Bundles": ["x"]]],
                                          coreFoundationVersion: version))
    }

    func testInGeneral() {
        XCTAssertTrue(SettingsPane.inGeneral(systemVersion: "18.0"))
        XCTAssertTrue(SettingsPane.inGeneral(systemVersion: "26.0.1"))
        XCTAssertFalse(SettingsPane.inGeneral(systemVersion: "17.5.1"))
        XCTAssertFalse(SettingsPane.inGeneral(systemVersion: ""))
    }

    func testAddress() {
        let choicy = SettingsPane(title: "Choicy", identifier: "Choicy")
        XCTAssertEqual(SettingsPane.address(of: choicy, systemVersion: "18.1.1"), "prefs:root=General&path=Choicy")
        XCTAssertEqual(SettingsPane.address(of: choicy, systemVersion: "26.0"), "prefs:root=General&path=Choicy")
        XCTAssertEqual(SettingsPane.address(of: choicy, systemVersion: "16.3.1"), "prefs:root=Choicy")
        XCTAssertEqual(SettingsPane.address(of: choicy, systemVersion: "17"), "prefs:root=Choicy")
        let spaced = SettingsPane(title: "Easy Swipe", identifier: "Easy Swipe&Co=1")
        XCTAssertEqual(SettingsPane.address(of: spaced, systemVersion: "18.1.1"),
                       "prefs:root=General&path=Easy%20Swipe%26Co%3D1")
    }
}
