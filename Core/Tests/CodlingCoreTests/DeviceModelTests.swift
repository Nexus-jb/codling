// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class DeviceModelTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(DeviceModel.name(for: "iPhone15,3"), "iPhone 14 Pro Max")
        XCTAssertEqual(DeviceModel.name(for: "iPhone11,8"), "iPhone XR")
        XCTAssertEqual(DeviceModel.name(for: "iPhone99,1"), "iPhone99,1")
    }

    func testFronts() {
        XCTAssertEqual(DeviceModel.front(for: "iPhone15,3"), .dynamicIsland)
        XCTAssertEqual(DeviceModel.front(for: "iPhone14,7"), .notch)
        XCTAssertEqual(DeviceModel.front(for: "iPhone17,5"), .notch)
        XCTAssertEqual(DeviceModel.front(for: "iPhone14,6"), .homeButton)
        XCTAssertEqual(DeviceModel.front(for: "iPad13,4"), .tablet)
        XCTAssertEqual(DeviceModel.front(for: "iPhone18,2"), .dynamicIsland)
        XCTAssertEqual(DeviceModel.front(for: "x86_64"), .notch)
    }
}
