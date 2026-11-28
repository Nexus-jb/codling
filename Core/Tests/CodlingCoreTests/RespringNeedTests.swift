// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import CodlingCore

final class RespringNeedTests: XCTestCase {
    func testTweaks() {
        XCTAssertTrue(RespringNeed.needed(files: ["/.", "/Library", "/Library/MobileSubstrate",
                                                  "/Library/MobileSubstrate/DynamicLibraries",
                                                  "/Library/MobileSubstrate/DynamicLibraries/EasySwipe.dylib",
                                                  "/Library/MobileSubstrate/DynamicLibraries/EasySwipe.plist"]))
        XCTAssertTrue(RespringNeed.needed(files: ["/var/jb/usr/lib/TweakInject/Choicy.plist"]))
        XCTAssertTrue(RespringNeed.needed(files: ["/var/jb/Library/TweakInject/Choicy.dylib"]))
    }

    func testThemesAndLibraries() {
        XCTAssertTrue(RespringNeed.needed(files: ["/var/jb/Library/Themes/Glyphs.theme/IconBundles/a.png"]))
        XCTAssertTrue(RespringNeed.needed(files: ["/var/jb/usr/lib/libsandy.dylib"]))
        XCTAssertTrue(RespringNeed.needed(files: ["/Library/Frameworks/AltList.framework/AltList"]))
        XCTAssertTrue(RespringNeed.needed(files: ["/var/jb/usr/lib/burrow/BurrowLoader.dylib"]))
    }

    func testNotNeeded() {
        // A keyring.
        XCTAssertFalse(RespringNeed.needed(files: ["/.", "/etc", "/etc/apt", "/etc/apt/trusted.gpg.d",
                                                   "/etc/apt/trusted.gpg.d/nexus.gpg"]))
        // An app with its own frameworks and libraries.
        XCTAssertFalse(RespringNeed.needed(files: ["/var/jb/Applications/Codling.app/Codling",
                                                   "/var/jb/Applications/Codling.app/Frameworks/Lib.framework/Lib",
                                                   "/var/jb/Applications/Codling.app/libhelper.dylib"]))
        // A command-line tool, and the folders tweaks go in, without a tweak.
        XCTAssertFalse(RespringNeed.needed(files: ["/var/jb/usr/bin/uiopen", "/var/jb/usr/lib/TweakInject",
                                                   "/Library/MobileSubstrate/DynamicLibraries"]))
        // Settings pages: the Settings app reads them when it opens.
        XCTAssertFalse(RespringNeed.needed(files: ["/Library/PreferenceLoader/Preferences/EasySwipePrefs.plist",
                                                   "/Library/PreferenceBundles/EasySwipePrefs.bundle/Root.plist"]))
        XCTAssertFalse(RespringNeed.needed(files: []))
    }
}
