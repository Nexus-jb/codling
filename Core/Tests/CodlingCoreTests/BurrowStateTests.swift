// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class BurrowStateTests: XCTestCase {
    /// The shape burrowctl json prints, with keys sorted as it sorts them.
    let sample = """
    {"daemonRunning":true,"disabledEverywhere":["Old"],\
    "disabledInProcesses":{"backboardd":["*"],"com.apple.springboard":["Baz","Foo"],"com.example.bank":["Foo"]},\
    "engine":"Burrow","events":[\
    {"action":"safe-mode","date":"2026-11-19T08:12:03Z","process":"com.apple.springboard","tweak":"Foo",\
    "text":"turned off Foo in com.apple.springboard: EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib"},\
    {"action":"off","date":"2026-11-20T15:00:00Z","process":"com.example.bank","tweak":"Foo",\
    "text":"turned Foo off in com.example.bank with burrowctl disable"},\
    {"action":"safe-mode","date":null,"process":"com.example.app","tweak":"Bar",\
    "text":"turned off Bar in com.example.app: an uncaught exception"}],\
    "format":1,"loader":"Burrow","safeModeSince":"2026-11-19T02:00:00Z","settings":"valid",\
    "settingsPath":"/var/jb/etc/burrow/loader.plist","trialUntil":null,"tweakDirectory":"/var/jb/usr/lib/TweakInject",\
    "tweaks":[\
    {"bundles":["com.apple.springboard"],"classes":[],"executables":[],"manager":false,"name":"Foo",\
    "package":"com.example.foo","packageName":"Foo Tweak","packageVersion":"1.2"},\
    {"bundles":["com.apple.UIKit"],"classes":[],"executables":[],"manager":false,"name":"Bar"},\
    {"bundles":["com.apple.WebKit"],"classes":[],"executables":["Preferences"],"manager":false,"name":"Web",\
    "package":"com.example.web","packageName":null,"packageVersion":"2"},\
    {"bundles":["com.apple.Foundation"],"classes":[],"executables":[],"manager":true,"name":"Choicy"},\
    {"bundles":[],"classes":[],"executables":[],"manager":false,"name":"Nothing"}],\
    "wentBack":null}
    """

    func testDecoding() throws {
        let state = try BurrowState.decode(Data(sample.utf8))
        XCTAssertEqual(state.format, 1)
        XCTAssertTrue(state.usesBurrowLoader)
        XCTAssertTrue(state.canChangeSettings)
        XCTAssertEqual(state.safeModeSince, Date(timeIntervalSince1970: 1_795_053_600))
        XCTAssertNil(state.trialUntil)
        XCTAssertNil(state.wentBack)
        XCTAssertEqual(state.tweaks.map(\.name), ["Foo", "Bar", "Web", "Choicy", "Nothing"])
        XCTAssertEqual(state.tweaks[0].displayName, "Foo Tweak")
        XCTAssertEqual(state.tweaks[1].displayName, "Bar")
        XCTAssertEqual(state.tweaks[2].displayName, "Web")
        XCTAssertNil(state.events[2].date)
    }

    func testWhereTweaksAreOff() throws {
        let state = try BurrowState.decode(Data(sample.utf8))
        XCTAssertTrue(state.isOffEverywhere("Old"))
        XCTAssertFalse(state.isOffEverywhere("Foo"))
        XCTAssertEqual(state.placesOff("Foo"), [
            .init(process: "backboardd", everyTweak: true),
            .init(process: "com.apple.springboard", everyTweak: false),
            .init(process: "com.example.bank", everyTweak: false),
        ])
        XCTAssertEqual(state.placesOff("Bar"), [.init(process: "backboardd", everyTweak: true)])
        XCTAssertEqual(state.processesWithEveryTweakOff, ["backboardd"])

        // Safe Mode's events, newest first, and whether each is still off.
        XCTAssertEqual(state.safeModeEvents.map(\.tweak), ["Bar", "Foo"])
        XCTAssertFalse(state.isStillOff(state.safeModeEvents[0]))
        XCTAssertTrue(state.isStillOff(state.safeModeEvents[1]))
    }

    func testReach() throws {
        let state = try BurrowState.decode(Data(sample.utf8))
        let tweaks = Dictionary(uniqueKeysWithValues: state.tweaks.map { ($0.name, $0) })
        let apps: Set<String> = ["com.apple.Preferences", "com.example.bank"]
        XCTAssertEqual(tweaks["Foo"]?.reach, .named)
        XCTAssertEqual(tweaks["Foo"]?.namedTargets, ["com.apple.springboard"])
        XCTAssertEqual(tweaks["Foo"]?.mayLoadIntoAnyApp(installedApps: apps), false)
        XCTAssertEqual(tweaks["Bar"]?.reach, .everyApp)
        XCTAssertEqual(tweaks["Bar"]?.namedTargets, [])
        XCTAssertEqual(tweaks["Web"]?.reach, .named)
        XCTAssertEqual(tweaks["Web"]?.namedTargets, ["com.apple.WebKit", "Preferences"])
        XCTAssertEqual(tweaks["Web"]?.mayLoadIntoAnyApp(installedApps: apps), true)
        XCTAssertEqual(tweaks["Choicy"]?.reach, .everyProcess)
        XCTAssertEqual(tweaks["Nothing"]?.reach, .nothing)
        XCTAssertEqual(tweaks["Nothing"]?.mayLoadIntoAnyApp(installedApps: apps), false)
    }

    func testWhenSettingsCannotChange() throws {
        var state = try BurrowState.decode(Data(sample.utf8))
        state.loader = "ElleKit"
        XCTAssertFalse(state.canChangeSettings)
        state.loader = "Burrow"
        state.settings = "invalid"
        XCTAssertFalse(state.canChangeSettings)
        state.settings = "none"
        XCTAssertTrue(state.canChangeSettings)
        state.format = 2
        XCTAssertFalse(state.canChangeSettings)
    }

    func testWentBack() throws {
        let text = sample.replacingOccurrences(of: "\"wentBack\":null",
                                               with: "\"wentBack\":{\"date\":\"2026-11-18T10:00:00Z\",\"reason\":\"SpringBoard crashed twice\"}")
        let state = try BurrowState.decode(Data(text.utf8))
        XCTAssertEqual(state.wentBack?.reason, "SpringBoard crashed twice")
        XCTAssertNotNil(state.wentBack?.date)
    }
}
