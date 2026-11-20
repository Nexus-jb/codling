// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class CompatibilityTests: XCTestCase {
    let device = "16.3.1"

    func check(depends: String? = nil, tag: String? = nil, name: String? = nil, summary: String? = nil) -> CompatibilityReport {
        Compatibility.check(depends: depends, tag: tag, name: name, summary: summary, systemVersion: device)
    }

    func testDependencies() {
        XCTAssertEqual(check(depends: "firmware (>= 15.0), uikittools"),
                       .init(verdict: .supported, range: "iOS 15.0 or later", source: .dependency))
        XCTAssertEqual(check(depends: "mobilesubstrate (>= 0.9.5000), firmware (>= 17.0)"),
                       .init(verdict: .unsupported, range: "iOS 17.0 or later", source: .dependency))
        XCTAssertEqual(check(depends: "firmware (>= 14.0), firmware (<< 16.0)"),
                       .init(verdict: .unsupported, range: "iOS 14.0 or later, before iOS 16.0", source: .dependency))
        XCTAssertEqual(check(depends: "firmware (<< 16.4)").verdict, .supported)
        XCTAssertEqual(check(depends: "firmware (>= 16.3.1)").verdict, .supported)
        XCTAssertEqual(check(depends: "firmware (>= 16.4) | firmware (<< 16.0)").verdict, .unsupported)
        XCTAssertEqual(check(depends: "mobilesubstrate, preferenceloader").verdict, .unknown)
        // A firmware alternative beside another package says nothing alone.
        XCTAssertEqual(check(depends: "firmware (>= 17.0) | com.example.shim").verdict, .unknown)
    }

    func testTags() {
        XCTAssertEqual(check(tag: "purpose::extension, compatible::ios15, compatible::ios16"),
                       .init(verdict: .supported, range: "iOS 15, 16", source: .tags))
        XCTAssertEqual(check(tag: "compatible::ios17").verdict, .unsupported)
        XCTAssertEqual(check(tag: "compatible::ios16.x").verdict, .supported)
        XCTAssertEqual(check(tag: "compatible_min::ios14.0, compatible_max::ios16.5"),
                       .init(verdict: .supported, range: "iOS 14.0 to 16.5", source: .tags))
        XCTAssertEqual(check(tag: "compatible_max::ios16.2").verdict, .unsupported)
        XCTAssertEqual(check(tag: "cydia::commercial").verdict, .unknown)
    }

    func testWords() {
        XCTAssertEqual(check(name: "AutoAnswer XS (rootless) (iOS 11 to 16)"),
                       .init(verdict: .supported, range: "iOS 11 to 16", source: .name))
        XCTAssertEqual(check(name: "Something (iOS 17 to 26)").verdict, .unsupported)
        XCTAssertEqual(check(name: "Thing", summary: "Works on iOS 14-15").verdict, .unsupported)
        XCTAssertEqual(check(summary: "For iOS 15+ devices").verdict, .supported)
        XCTAssertEqual(check(summary: "Needs iOS 16.4 or later").verdict, .unsupported)
        XCTAssertEqual(check(name: "Aemulo", summary: "NFC Frickery").verdict, .unknown)
        // The dependency wins over the name.
        XCTAssertEqual(check(depends: "firmware (>= 15.0)", name: "Old (iOS 11 to 14)").verdict, .supported)
    }

    func testJailbreakKind() {
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm64"), .rootless)
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm64e"), .roothide)
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm"), .rootful)
        XCTAssertEqual(JailbreakKind(architecture: "all"), .any)
    }
}
