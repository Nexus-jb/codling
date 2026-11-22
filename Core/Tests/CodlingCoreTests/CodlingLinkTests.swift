// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class CodlingLinkTests: XCTestCase {
    func testSourceLinks() {
        XCTAssertEqual(CodlingLink("codling://source/https://repo.example.com/"), .source("https://repo.example.com/"))
        XCTAssertEqual(CodlingLink("codling://sources/add/https://repo.example.com/"), .source("https://repo.example.com/"))
        XCTAssertEqual(CodlingLink("CODLING://Source/https://Repo.Example.com/beta"), .source("https://repo.example.com/beta/"))
        XCTAssertEqual(CodlingLink("codling://source/https%3A%2F%2Fapi.nexusjb.com%2Frepos%2Fcodling%2F"),
                       .source("https://api.nexusjb.com/repos/codling/"))
        XCTAssertEqual(CodlingLink("codling://source/http://repo.example.com/"), .source("http://repo.example.com/"))
    }

    func testPackageLinks() {
        XCTAssertEqual(CodlingLink("codling://package/com.example.tweak"), .package("com.example.tweak"))
        XCTAssertEqual(CodlingLink("codling://package/com.example.tweak/"), .package("com.example.tweak"))
    }

    func testRefusesWhatCodlingWouldNot() {
        XCTAssertNil(CodlingLink("sileo://source/https://repo.example.com/"))
        XCTAssertNil(CodlingLink("codling://source/ftp://repo.example.com/"))
        XCTAssertNil(CodlingLink("codling://source/file:///var/jb/etc/apt/"))
        XCTAssertNil(CodlingLink("codling://source/repo.example.com"))
        XCTAssertNil(CodlingLink("codling://source/https://repo.example.com/\"; rm"))
        XCTAssertNil(CodlingLink("codling://package/-rf"))
        XCTAssertNil(CodlingLink("codling://package/com.example tweak"))
        XCTAssertNil(CodlingLink("codling://package/"))
        XCTAssertNil(CodlingLink("codling://install/com.example.tweak"))
        XCTAssertNil(CodlingLink("codling://"))
        XCTAssertNil(CodlingLink("codling://source/https://" + String(repeating: "a", count: 3000) + ".com/"))
    }
}
