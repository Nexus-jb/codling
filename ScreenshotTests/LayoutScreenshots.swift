// SPDX-License-Identifier: Apache-2.0
//
// Screenshots of Codling's main pages in the simulator, upright and on its
// side, for checking the layout on every iPhone and iPad size that can be
// jailbroken. .github/workflows/screenshots.yml runs this on several
// simulators. It is not part of the app: nothing here ships in a package.
//
// The test reads two settings, which xcodebuild passes on from TEST_RUNNER_
// variables of the same names:
//
//   SCREENSHOT_ROOT  a folder laid out like a rootless jailbreak's root,
//                    with real sources in etc/apt and a dpkg status file
//   SCREENSHOT_DIR   where the PNG files go, one per page and orientation

import XCTest

final class LayoutScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL!
    private var prefix = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["SCREENSHOT_ROOT"], let output = environment["SCREENSHOT_DIR"] else {
            throw XCTSkip("SCREENSHOT_ROOT and SCREENSHOT_DIR are not set")
        }
        directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["CODLING_SIMULATOR_ROOT"] = root
        XCUIDevice.shared.orientation = .portrait
    }

    func testMainPages() throws {
        app.launch()
        // The first launch waits for the sources to refresh.
        waitUntilHittable(tab("Installed"), seconds: 180)
        settle(8)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            prefix = orientation == .portrait ? "portrait" : "landscape"
            settle(2)
            walkThroughPages()
        }
    }

    private func walkThroughPages() {
        tab("Featured").tap()
        settle(4)
        shoot("1-featured")

        tab("Sources").tap()
        settle(2)
        shoot("2-sources")

        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Packages'")).firstMatch
        if all.waitForExistence(timeout: 10) {
            all.tap()
            // The list reads the index first.
            let rows = app.scrollViews.firstMatch.buttons
            let deadline = Date().addingTimeInterval(30)
            while rows.count == 0 && Date() < deadline {
                settle(1)
            }
            settle(2)
            shoot("3-all-packages")
            // The first package in the list.
            if rows.count > 0 {
                rows.element(boundBy: 0).tap()
                settle(5)
                shoot("4-package")
                goBack()
            }
            goBack()
        }

        tab("Installed").tap()
        settle(2)
        shoot("5-installed")

        tab("Search").tap()
        settle(1)
        // Codling's own search field before iOS 26, the system's on it.
        let field = [app.searchFields.firstMatch, app.textFields.firstMatch].first { $0.waitForExistence(timeout: 3) }
        if let field {
            field.tap()
            field.typeText("theme\n")
            settle(4)
            // The floating tab bar steps aside while the keyboard is up.
            if app.keyboards.firstMatch.exists {
                app.swipeDown()
                settle(1)
            }
            shoot("6-search")
        }
    }

    private func tab(_ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists {
            back.tap()
            settle(1)
        }
    }

    private func shoot(_ name: String) {
        let file = directory.appendingPathComponent("\(prefix)-\(name).png")
        let image = XCUIScreen.main.screenshot()
        do {
            try image.pngRepresentation.write(to: file)
        } catch {
            XCTFail("Could not write \(file.path): \(error)")
        }
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntilHittable(_ element: XCUIElement, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return
            }
            settle(1)
        }
        XCTFail("\(element) did not appear within \(Int(seconds)) seconds")
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

