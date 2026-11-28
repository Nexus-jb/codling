// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import CodlingCore

final class RootlessConversionTests: XCTestCase {
    private let index = """
        Package: com.example.both
        Version: 1.0
        Architecture: iphoneos-arm64e

        Package: com.example.both
        Version: 2.0
        Architecture: iphoneos-arm64

        Package: com.example.rootless
        Version: 1.2
        Architecture: iphoneos-arm64
        Filename: debs/com.example.rootless_1.2_iphoneos-arm64.deb

        Package: com.example.theme
        Version: 3.0
        Architecture: all

        Package: com.example.theme
        Version: 3.1
        Architecture: iphoneos-arm64

        Package: com.example.rootful
        Version: 1.0
        Architecture: iphoneos-arm
        """

    func testRootHideKeepsRootlessPackagesWithoutANativeBuild() {
        let records = PackageIndex.parse(Data(index.utf8), architecture: "iphoneos-arm64e",
                                         convertible: RootlessConversion.convertibleArchitecture(on: "iphoneos-arm64e"))
        XCTAssertEqual(records.map { "\($0.package) \($0.version) \($0.architecture)" }, [
            "com.example.both 1.0 iphoneos-arm64e",
            "com.example.rootless 1.2 iphoneos-arm64",
            "com.example.theme 3.0 all",
        ])
    }

    func testWithoutAConvertibleArchitectureNothingChanges() {
        let roothide = PackageIndex.parse(Data(index.utf8), architecture: "iphoneos-arm64e")
        XCTAssertEqual(roothide.map(\.package), ["com.example.both", "com.example.theme"])
        let rootless = PackageIndex.parse(Data(index.utf8), architecture: "iphoneos-arm64",
                                          convertible: RootlessConversion.convertibleArchitecture(on: "iphoneos-arm64"))
        XCTAssertEqual(rootless.map { "\($0.package) \($0.version)" }, [
            "com.example.both 2.0", "com.example.rootless 1.2", "com.example.theme 3.0", "com.example.theme 3.1",
        ])
    }

    func testOnlyRootlessPackagesOnRootHideNeedConverting() {
        XCTAssertTrue(RootlessConversion.needsConversion("iphoneos-arm64", on: "iphoneos-arm64e"))
        XCTAssertFalse(RootlessConversion.needsConversion("iphoneos-arm64e", on: "iphoneos-arm64e"))
        XCTAssertFalse(RootlessConversion.needsConversion("all", on: "iphoneos-arm64e"))
        XCTAssertFalse(RootlessConversion.needsConversion(nil, on: "iphoneos-arm64e"))
        XCTAssertFalse(RootlessConversion.needsConversion("iphoneos-arm64", on: "iphoneos-arm64"))
        XCTAssertNil(RootlessConversion.convertibleArchitecture(on: "iphoneos-arm64"))
    }

    func testUpdatesNeverConvertOverANativeBuild() {
        let offers = [
            PackageSummary(source: "roothide", package: "preferenceloader", version: "2.2.8",
                           architecture: "iphoneos-arm64e"),
            PackageSummary(source: "other", package: "preferenceloader", version: "2.3", architecture: "iphoneos-arm64"),
            PackageSummary(source: "havoc", package: "com.example.tweak", version: "1.1", architecture: "iphoneos-arm64"),
            PackageSummary(source: "havoc", package: "com.example.same", version: "1.0", architecture: "iphoneos-arm64"),
            PackageSummary(source: "havoc", package: "com.example.patched", version: "2.0",
                           architecture: "iphoneos-arm64"),
        ]
        let installed = ["preferenceloader": "2.2.8", "com.example.tweak": "1.0", "com.example.same": "1.0",
                         "com.example.patched": "2.0~roothide"]
        let kept = RootlessConversion.offersForUpdates(offers, installed: installed, on: "iphoneos-arm64e")
        XCTAssertEqual(kept.map { "\($0.source) \($0.package)" }, ["roothide preferenceloader", "havoc com.example.tweak"])
        let updates = AvailableUpdates.find(installed: installed, offers: kept)
        XCTAssertEqual(updates.map(\.package), ["com.example.tweak"])
        // Rootless devices take every offer as it is.
        XCTAssertEqual(RootlessConversion.offersForUpdates(offers, installed: installed, on: "iphoneos-arm64"), offers)
    }

    func testAPatchedVersionIsTheRootlessVersionItCameFrom() {
        XCTAssertEqual(RootlessConversion.rootlessVersion(ofInstalled: "2.0~roothide"), "2.0")
        XCTAssertEqual(RootlessConversion.rootlessVersion(ofInstalled: "2.0"), "2.0")
        XCTAssertFalse(RootlessConversion.isNewer("2.0", thanInstalled: "2.0~roothide"))
        XCTAssertTrue(RootlessConversion.isNewer("2.0.1", thanInstalled: "2.0~roothide"))
        XCTAssertFalse(RootlessConversion.isNewer("1.9", thanInstalled: "2.0"))
    }

    func testTheDownloadKeepsAPlainFileNameOrGetsOne() {
        XCTAssertEqual(RootlessConversion.fileName(package: "com.example.rootless", version: "1.2",
                                                   filename: "./debs/com.example.rootless_1.2_iphoneos-arm64.deb"),
                       "com.example.rootless_1.2_iphoneos-arm64.deb")
        XCTAssertEqual(RootlessConversion.fileName(package: "com.example.paid", version: "1:2.0",
                                                   filename: "https://cdn.example.com/get?id=7"),
                       "com.example.paid_1%3a2.0_iphoneos-arm64.deb")
        XCTAssertEqual(RootlessConversion.fileName(package: "com.example.odd", version: "1.0",
                                                   filename: "debs/weird name;rm.deb"),
                       "com.example.odd_1.0_iphoneos-arm64.deb")
        XCTAssertEqual(RootlessConversion.fileName(package: "com.example.none", version: "1.0", filename: nil),
                       "com.example.none_1.0_iphoneos-arm64.deb")
        XCTAssertEqual(RootlessConversion.fileName(package: "com.example.hidden", version: "1.0", filename: "a/.x.deb"),
                       "com.example.hidden_1.0_iphoneos-arm64.deb")
    }
}
