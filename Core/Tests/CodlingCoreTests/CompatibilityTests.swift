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
        // A name that contradicts the dependency does not count.
        XCTAssertEqual(check(depends: "firmware (>= 15.0)", name: "Old (iOS 11 to 14)").verdict, .supported)
    }

    /// The same packages on other iOS versions, including ones no test
    /// device runs.
    func testAcrossVersions() {
        func verdict(_ version: String, depends: String? = nil, tag: String? = nil, name: String? = nil,
                     summary: String? = nil) -> CompatibilityReport.Verdict {
            Compatibility.check(depends: depends, tag: tag, name: name, summary: summary, systemVersion: version).verdict
        }

        // A minimum in the dependency only.
        let ios17 = "firmware (>= 17.0)"
        for version in ["14.8", "15.8.3", "16.3.1", "16.7.10"] {
            XCTAssertEqual(verdict(version, depends: ios17), .unsupported, version)
        }
        for version in ["17.0", "17.3.1", "18.7.1", "26.0.1"] {
            XCTAssertEqual(verdict(version, depends: ios17), .supported, version)
        }

        // A minimum in the dependency and a maximum in the name.
        let glowDepends = "firmware (>= 12.0), mobilesubstrate"
        let glow = "Glow (rootless iOS 12-17)"
        XCTAssertEqual(verdict("11.4", depends: glowDepends, name: glow), .unsupported)
        for version in ["12.0", "15.4", "16.3.1", "17.0", "17.3.1", "17.7"] {
            XCTAssertEqual(verdict(version, depends: glowDepends, name: glow), .supported, version)
        }
        XCTAssertEqual(Compatibility.check(depends: glowDepends, tag: nil, name: glow, summary: nil,
                                           systemVersion: "18.7.1"),
                       .init(verdict: .unsupported, range: "iOS 12 to 17", source: .name))
        XCTAssertEqual(verdict("26.0.1", depends: glowDepends, name: glow), .unsupported)

        // A range in the name only.
        let autoAnswer = "AutoAnswer XS (rootless) (iOS 11 to 16)"
        for version in ["11.0", "14.8", "15.8.3", "16.3.1", "16.7.10"] {
            XCTAssertEqual(verdict(version, name: autoAnswer), .supported, version)
        }
        for version in ["10.3.3", "17.0", "18.7.1", "26.0.1"] {
            XCTAssertEqual(verdict(version, name: autoAnswer), .unsupported, version)
        }

        // A maximum in the tags beside a minimum-only dependency.
        let tags = "compatible_min::ios15.0, compatible_max::ios17.x"
        XCTAssertEqual(verdict("17.3.1", depends: "firmware (>= 15.0)", tag: tags), .supported)
        XCTAssertEqual(verdict("18.7.1", depends: "firmware (>= 15.0)", tag: tags), .unsupported)
        XCTAssertEqual(verdict("18.7.1", tag: "compatible::ios17, compatible::ios18"), .supported)
        XCTAssertEqual(verdict("26.0.1", tag: "compatible::ios17, compatible::ios18"), .unsupported)

        // A dependency with a maximum of its own stands.
        XCTAssertEqual(verdict("17.3.1", depends: "firmware (>= 15.0), firmware (<< 18.0)",
                               name: "Old (iOS 15 to 16)"), .supported)
        XCTAssertEqual(verdict("18.7.1", depends: "firmware (>= 15.0), firmware (<< 18.0)"), .unsupported)
        // A minimum in the words does not overrule the dependency's.
        XCTAssertEqual(verdict("15.8.3", depends: "firmware (>= 14.0)",
                               summary: "The iOS 17+ lock screen on older iOS"), .supported)

        // Open ranges reach iOS 26.
        XCTAssertEqual(verdict("26.0.1", summary: "For iOS 15+ devices"), .supported)
        XCTAssertEqual(verdict("26.0.1", name: "Tweak (iOS 15 to 18)"), .unsupported)
        XCTAssertEqual(verdict("26.0.1", depends: "mobilesubstrate"), .unknown)
    }

    func testJailbreakKind() {
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm64"), .rootless)
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm64e"), .roothide)
        XCTAssertEqual(JailbreakKind(architecture: "iphoneos-arm"), .rootful)
        XCTAssertEqual(JailbreakKind(architecture: "all"), .any)
    }
}
