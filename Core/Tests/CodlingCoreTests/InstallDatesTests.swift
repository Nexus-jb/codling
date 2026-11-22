// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class InstallDatesTests: XCTestCase {
    private var info: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        info = FileManager.default.temporaryDirectory.appendingPathComponent("install-dates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: info)
    }

    private func list(_ name: String, minutesAfterStart minutes: Double) throws {
        let path = info.appendingPathComponent(name).path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("/.\n".utf8)))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(minutes * 60)], ofItemAtPath: path)
    }

    func testDatesFromFileLists() throws {
        try list("com.example.old.list", minutesAfterStart: 0)
        try list("com.example.new:iphoneos-arm64.list", minutesAfterStart: 30)
        // Both forms: the later counts.
        try list("com.example.both.list", minutesAfterStart: 5)
        try list("com.example.both:iphoneos-arm64.list", minutesAfterStart: 20)
        // Other files in info, and packages not asked for.
        try list("com.example.old.md5sums", minutesAfterStart: 90)
        try list("com.example.removed.list", minutesAfterStart: 60)

        let dates = InstallDates.read(infoDirectory: info.path,
                                      identifiers: ["com.example.old", "com.example.new", "com.example.both", "com.example.nolist"])
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates["com.example.old"], start)
        XCTAssertEqual(dates["com.example.new"], start.addingTimeInterval(30 * 60))
        XCTAssertEqual(dates["com.example.both"], start.addingTimeInterval(20 * 60))
        XCTAssertNil(dates["com.example.nolist"])
        XCTAssertNil(dates["com.example.removed"])
    }

    func testMissingDirectory() {
        XCTAssertEqual(InstallDates.read(infoDirectory: info.appendingPathComponent("none").path, identifiers: ["a"]), [:])
    }

    func testNewestFirst() {
        let dates = ["a": start, "b": start.addingTimeInterval(60), "c": start.addingTimeInterval(60), "e": start.addingTimeInterval(120)]
        // e newest; b and c tie and keep their order; a; then d and f, with
        // no date, in their order.
        XCTAssertEqual(InstallDates.newestFirst(["a", "b", "c", "d", "e", "f"], dates: dates), ["e", "b", "c", "a", "d", "f"])
        XCTAssertEqual(InstallDates.newestFirst([], dates: dates), [])
    }
}
