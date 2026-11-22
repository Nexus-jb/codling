// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class OpenedPackageTests: XCTestCase {
    private let token = "00112233445566778899aabbccddeeff"

    func testFileOperation() {
        let operation = PackageOperation.file("com.ultrateam.ultradock", token: token)
        XCTAssertEqual(operation.helperArgument, "%" + token)
        XCTAssertEqual(operation.package, "com.ultrateam.ultradock")
        XCTAssertTrue(operation.isValid)
        XCTAssertFalse(PackageOperation.file("-dock", token: token).isValid)
        XCTAssertFalse(PackageOperation.file("com.ultrateam.ultradock", token: "../../etc/passwd").isValid)
        XCTAssertFalse(PackageOperation.file("com.ultrateam.ultradock", token: String(token.dropLast())).isValid)
        XCTAssertFalse(PackageOperation.file("com.ultrateam.ultradock", token: token.uppercased()).isValid)
        XCTAssertFalse(PackageOperation.file("com.ultrateam.ultradock", token: token + "0").isValid)
    }

    func testNewTokensAreValidAndDifferent() {
        let tokens = (0..<50).map { _ in PackageOperation.newFileToken() }
        XCTAssertTrue(tokens.allSatisfy(PackageOperation.isValidFileToken))
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }

    func testReadsWhatDpkgDebPrints() throws {
        let control = """
            Package: com.ultrateam.ultradock
            Name: UltraDock
            Version: 1.0.3
            Architecture: iphoneos-arm64
            Author: Ultra Team <team@example.com>
            Maintainer: Someone Else <else@example.com>
            Section: Tweaks
            Installed-Size: 412
            Pre-Depends: firmware (>= 15.0)
            Depends: mobilesubstrate, com.ultrateam.ultracore (>= 1.2)
            Conflicts: com.example.olddock
            Description: A dock for your home screen
             It blurs and rounds.
             .
             Works with Burrow.

            """
        let opened = try XCTUnwrap(OpenedPackage(token: token, control: control))
        XCTAssertEqual(opened.package, "com.ultrateam.ultradock")
        XCTAssertEqual(opened.displayName, "UltraDock")
        XCTAssertEqual(opened.version, "1.0.3")
        XCTAssertEqual(opened.authorName, "Ultra Team")
        XCTAssertEqual(opened.section, "Tweaks")
        XCTAssertEqual(opened.installedSize, 412)
        XCTAssertEqual(opened.depends, "firmware (>= 15.0), mobilesubstrate, com.ultrateam.ultracore (>= 1.2)")
        XCTAssertEqual(opened.conflicts, "com.example.olddock")
        XCTAssertEqual(opened.summary, "A dock for your home screen")
        XCTAssertEqual(opened.details, "It blurs and rounds.\n\nWorks with Burrow.")
        XCTAssertEqual(opened.fit(deviceArchitecture: "iphoneos-arm64"), .fits)
        XCTAssertEqual(opened.fit(deviceArchitecture: "iphoneos-arm64e"), .otherArchitecture("iphoneos-arm64"))
    }

    func testFallsBackToTheIdentifierAndMaintainer() throws {
        let control = "Package: com.example.plain\nVersion: 2:1.0-1\nArchitecture: all\nMaintainer: Plain Dev\n"
        let opened = try XCTUnwrap(OpenedPackage(token: token, control: control))
        XCTAssertEqual(opened.displayName, "com.example.plain")
        XCTAssertEqual(opened.authorName, "Plain Dev")
        XCTAssertNil(opened.depends)
        XCTAssertNil(opened.summary)
        XCTAssertNil(opened.details)
        XCTAssertEqual(opened.fit(deviceArchitecture: "iphoneos-arm64e"), .fits)
        XCTAssertEqual(OpenedPackage(token: token, control: "Package: x.rootful\nVersion: 1.0\nArchitecture: iphoneos-arm\n")?
            .fit(deviceArchitecture: "iphoneos-arm64"), .otherArchitecture("iphoneos-arm"))
    }

    func testRefusesWhatTheHelperWouldRefuse() {
        XCTAssertNil(OpenedPackage(token: token, control: "Version: 1.0\n"))
        XCTAssertNil(OpenedPackage(token: token, control: "Package: com.example.x\n"))
        XCTAssertNil(OpenedPackage(token: token, control: "Package: -x\nVersion: 1.0\n"))
        XCTAssertNil(OpenedPackage(token: token, control: "Package: com.example.x\nVersion: one\n"))
        XCTAssertNil(OpenedPackage(token: "nope", control: "Package: com.example.x\nVersion: 1.0\n"))
        XCTAssertNil(OpenedPackage(token: token, control: ""))
    }
}
