// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class AvailableUpdatesTests: XCTestCase {
    private func offer(_ source: String, _ package: String, _ version: String) -> PackageSummary {
        PackageSummary(source: source, package: package, version: version, name: package)
    }

    func testFindsNewerVersionsOnly() {
        let found = AvailableUpdates.find(
            installed: ["a": "1.0", "b": "2.0", "c": "1.0"],
            offers: [offer("s1", "a", "1.1"), offer("s1", "b", "2.0"), offer("s1", "c", "0.9"),
                     offer("s1", "d", "5.0")])
        XCTAssertEqual(found.map(\.package), ["a"])
    }

    func testTakesTheNewestOfferAndBreaksTiesByAddress() {
        let found = AvailableUpdates.find(
            installed: ["a": "1.0", "b": "1.0"],
            offers: [offer("https://z.example/", "a", "1.2"), offer("https://y.example/", "a", "1.3"),
                     offer("https://z.example/", "b", "2.0"), offer("https://a.example/", "b", "2.0")])
        XCTAssertEqual(found.map(\.source), ["https://y.example/", "https://a.example/"])
        XCTAssertEqual(found.map(\.version), ["1.3", "2.0"])
    }
}
