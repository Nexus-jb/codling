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

    func testTheNoticeNamesBurrowOnlyWhenItIsQueued() {
        let withBurrow = Essentials.notice(for: Essentials.all)
        XCTAssertTrue(withBurrow.contains("Burrow, for Safe Mode, and packages many tweaks need."))
        // RootHide, where no source has Burrow yet.
        let withoutBurrow = Essentials.notice(for: Array(Essentials.all.dropFirst()))
        XCTAssertFalse(withoutBurrow.contains("Burrow"))
        XCTAssertTrue(withoutBurrow.contains("first launch: packages many tweaks need."))
        XCTAssertTrue(withoutBurrow.hasSuffix("Nothing is installed until you confirm."))
    }

    func testNothingWhenAllAreInstalledOrNoSourceHasThem() {
        let all = Set(Essentials.all.map(\.identifier))
        XCTAssertTrue(Essentials.missing(installed: all.contains, offered: all.contains).isEmpty)
        XCTAssertTrue(Essentials.missing(installed: { _ in false }, offered: { _ in false }).isEmpty)
    }
}
