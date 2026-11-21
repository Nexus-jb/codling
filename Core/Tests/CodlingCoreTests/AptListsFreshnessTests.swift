// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class AptListsFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let sources = ["https://repo.chariz.com/", "https://havoc.app/"]

    func testNeverUpdated() {
        XCTAssertFalse(AptListsFreshness().isFresh(now: start, sources: sources))
    }

    func testFreshWithinTheWindow() {
        var lists = AptListsFreshness()
        lists.recordUpdate(at: start, sources: sources.reversed())
        XCTAssertTrue(lists.isFresh(now: start, sources: sources))
        XCTAssertTrue(lists.isFresh(now: start.addingTimeInterval(AptListsFreshness.window - 1), sources: sources))
        XCTAssertFalse(lists.isFresh(now: start.addingTimeInterval(AptListsFreshness.window), sources: sources))
        // A clock set back is not trusted.
        XCTAssertFalse(lists.isFresh(now: start.addingTimeInterval(-60), sources: sources))
    }

    func testSourcesChanged() {
        var lists = AptListsFreshness()
        lists.recordUpdate(at: start, sources: sources)
        XCTAssertFalse(lists.isFresh(now: start, sources: sources + ["https://repo.nexusjb.com/"]))
        XCTAssertFalse(lists.isFresh(now: start, sources: [sources[0]]))
    }

    func testInvalidate() {
        var lists = AptListsFreshness()
        lists.recordUpdate(at: start, sources: sources)
        lists.invalidate()
        XCTAssertFalse(lists.isFresh(now: start, sources: sources))
    }

    func testAptAnswers() {
        XCTAssertTrue(AptListsFreshness.mentionsMissingPackage("E: Unable to locate package com.example.new"))
        XCTAssertTrue(AptListsFreshness.mentionsMissingPackage("E: Version '1.2' for 'com.example.tweak' was not found"))
        XCTAssertTrue(AptListsFreshness.mentionsMissingPackage("E: Package 'x' has no installation candidate"))
        XCTAssertFalse(AptListsFreshness.mentionsMissingPackage("E: Unmet dependencies."))
        XCTAssertTrue(AptListsFreshness.mentionsFailedDownload(
            "E: Failed to fetch https://havoc.app/debs/x.deb  404  Not Found\nE: Unable to fetch some archives"))
        XCTAssertFalse(AptListsFreshness.mentionsFailedDownload("dpkg: error processing archive"))
    }
}
