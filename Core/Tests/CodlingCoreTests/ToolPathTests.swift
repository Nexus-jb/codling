// SPDX-License-Identifier: Apache-2.0

import CodlingCore
import XCTest

final class ToolPathTests: XCTestCase {
    let hidden = "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"

    func testRootHideRoots() {
        XCTAssertTrue(ToolPath.isRootHide(root: hidden))
        XCTAssertTrue(ToolPath.isRootHide(root: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"))
        XCTAssertFalse(ToolPath.isRootHide(root: "/var/jb"))
        XCTAssertFalse(ToolPath.isRootHide(root: "/private/preboot/ABCDEF/jb-XYZ/procursus"))
        XCTAssertFalse(ToolPath.isRootHide(root: "/private/var/containers/Bundle/Application/.jbroot-"))
        XCTAssertFalse(ToolPath.isRootHide(root: ""))
    }

    func testRootlessPathsStayReal() {
        XCTAssertEqual(ToolPath.convert("/var/jb/etc/apt/trusted.gpg.d/a.gpg", root: "/var/jb"),
                       "/var/jb/etc/apt/trusted.gpg.d/a.gpg")
        XCTAssertEqual(ToolPath.convert("/var/mobile/Library/Caches/x", root: "/var/jb"), "/var/mobile/Library/Caches/x")
    }

    func testRootHidePaths() {
        XCTAssertEqual(ToolPath.convert(hidden + "/etc/apt/trusted.gpg.d/a.gpg", root: hidden),
                       "/etc/apt/trusted.gpg.d/a.gpg")
        XCTAssertEqual(ToolPath.convert(hidden, root: hidden), "/")
        XCTAssertEqual(ToolPath.convert(hidden + "/usr/bin", root: hidden), "/usr/bin")
        // The root and the path may each be written with or without /private.
        let short = String(hidden.dropFirst("/private".count))
        XCTAssertEqual(ToolPath.convert(short + "/usr/bin", root: hidden), "/usr/bin")
        XCTAssertEqual(ToolPath.convert(hidden + "/usr/bin", root: short), "/usr/bin")
        // Anything outside the root is on the system volume.
        XCTAssertEqual(ToolPath.convert("/var/mobile/Library/Caches/com.nexusjb.codling/x.Release", root: hidden),
                       "/rootfs/var/mobile/Library/Caches/com.nexusjb.codling/x.Release")
        XCTAssertEqual(ToolPath.convert(hidden + "0/x", root: hidden), "/rootfs" + hidden + "0/x")
    }
}
