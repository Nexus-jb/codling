// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class EssentialsTests: XCTestCase {
    func testIdentifiersAreValidAndDistinct() {
        let identifiers = Essentials.all.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.allSatisfy(PackageOperation.isValidName))
        XCTAssertEqual(identifiers.first, "com.nexusjb.burrow")
        XCTAssertTrue(Essentials.all.allSatisfy { !$0.name.isEmpty && !$0.reason.isEmpty })
    }

    func testOffersOnlyWhatIsMissingAndAvailable() {
        let installed: Set = ["preferenceloader"]
        let offered: Set = ["com.nexusjb.burrow", "preferenceloader", "ws.hbang.common"]
        let missing = Essentials.missing(installed: installed.contains, offered: offered.contains)
        XCTAssertEqual(missing.map(\.identifier), ["com.nexusjb.burrow", "ws.hbang.common"])
    }

    func testNothingWhenAllAreInstalledOrNoSourceHasThem() {
        let all = Set(Essentials.all.map(\.identifier))
        XCTAssertTrue(Essentials.missing(installed: all.contains, offered: all.contains).isEmpty)
        XCTAssertTrue(Essentials.missing(installed: { _ in false }, offered: { _ in false }).isEmpty)
    }
}
