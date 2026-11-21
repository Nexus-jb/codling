// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class FeaturedMixTests: XCTestCase {
    func testTakesOneFromEachSourceInTurn() {
        let mixed = FeaturedMix.interleave([["a1", "a2", "a3", "a4"], ["b1"], ["c1", "c2"]])
        XCTAssertEqual(mixed, ["a1", "b1", "c1", "a2", "c2", "a3", "a4"])
    }

    func testEmpty() {
        XCTAssertEqual(FeaturedMix.interleave([[String]]()), [])
        XCTAssertEqual(FeaturedMix.interleave([[], ["b1"]]), ["b1"])
    }
}
