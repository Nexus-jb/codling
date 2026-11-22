// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class ReportsTests: XCTestCase {
    /// A crash as burrowctl json gives it.
    let crashJSON = """
    {"bundleIdentifier":"com.apple.springboard","date":"2026-11-22T08:12:00Z","device":"iPhone15,3",\
    "exception":{"message":null,"name":null,"signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x10",\
    "type":"EXC_BAD_ACCESS"},\
    "frames":[{"image":"Foo.dylib","offset":16256,"symbol":"-[FooView layoutSubviews]","symbolOffset":16},\
    {"image":"UIKitCore","offset":4096,"symbol":null,"symbolOffset":0}],\
    "incident":"11111111-2222-3333-4444-000000000001",\
    "packages":{"Bar":{"name":"Bar","package":"com.example.bar","version":"2.0-1"},\
    "Foo":{"name":"Foo","package":"com.example.foo","version":"1.2"}},\
    "process":"SpringBoard","reason":"EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib (-[FooView layoutSubviews] + 16)",\
    "system":"iPhone OS 16.3.1 (20D67)","tweak":"Foo","tweaks":["Bar","Foo"]}
    """

    private let device = Reports.Device(model: "iPhone11,6", system: "18.1.1", build: nil, jailbreak: "rootless",
                                        loader: "burrow", client: "Codling 0.1.0")

    private func crash() throws -> BurrowState.Crash {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BurrowState.Crash.self, from: Data(crashJSON.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEndpointFile() {
        XCTAssertEqual(Reports.endpoint(fromFile: "https://api.example.com/codling\n")?.absoluteString,
                       "https://api.example.com/codling/")
        XCTAssertNil(Reports.endpoint(fromFile: "http://api.example.com/codling/"))
        XCTAssertNil(Reports.endpoint(fromFile: "https://api.example.com/?a=b"))
        XCTAssertNil(Reports.endpoint(fromFile: ""))
        let endpoint = URL(string: "https://api.example.com/codling/")!
        XCTAssertEqual(Reports.url(endpoint, .crash).absoluteString, "https://api.example.com/codling/crash")
        XCTAssertEqual(Reports.url(endpoint, .install).absoluteString, "https://api.example.com/codling/install")
    }

    func testSystemLine() {
        XCTAssertEqual(Reports.systemVersion("iPhone OS 16.3.1 (20D67)")?.version, "16.3.1")
        XCTAssertEqual(Reports.systemVersion("iPhone OS 16.3.1 (20D67)")?.build, "20D67")
        XCTAssertEqual(Reports.systemVersion("iPadOS 18.1")?.version, "18.1")
        XCTAssertNil(Reports.systemVersion("iPadOS 18.1")?.build)
        XCTAssertNil(Reports.systemVersion(nil))
        XCTAssertNil(Reports.systemVersion("unknown"))
        XCTAssertEqual(Reports.loaderName("Burrow"), "burrow")
        XCTAssertEqual(Reports.loaderName("ElleKit"), "ellekit")
        XCTAssertNil(Reports.loaderName("none"))
    }

    func testCrashLogDecodes() throws {
        let crash = try crash()
        XCTAssertEqual(crash.id, "11111111-2222-3333-4444-000000000001")
        XCTAssertEqual(crash.package, .init(package: "com.example.foo", name: "Foo", version: "1.2"))
        XCTAssertEqual(crash.frames.count, 2)
        XCTAssertNil(crash.frames[1].symbol)
        // Older Burrow builds give no crashes; newer ones give the log.
        let older = """
        {"daemonRunning":true,"disabledEverywhere":[],"disabledInProcesses":{},"engine":"Burrow","events":[],\
        "format":1,"loader":"Burrow","safeModeSince":null,"settings":"none","trialUntil":null,"tweaks":[],"wentBack":null}
        """
        XCTAssertTrue(try BurrowState.decode(Data(older.utf8)).crashLog.isEmpty)
        let newer = older.replacingOccurrences(of: "\"wentBack\":null}", with: "\"wentBack\":null,\"crashes\":[\(crashJSON)]}")
        XCTAssertEqual(try BurrowState.decode(Data(newer.utf8)).crashLog.map(\.tweak), ["Foo"])
    }

    func testCrashReport() throws {
        let report = try XCTUnwrap(Reports.CrashReport(crash: try crash(), id: "abc", architecture: "iphoneos-arm64",
                                                       device: device))
        let body = try object(Reports.body(report))
        XCTAssertEqual(body["format"] as? Int, 1)
        XCTAssertEqual(body["id"] as? String, "abc")
        XCTAssertEqual(body["date"] as? String, "2026-11-22T08:12:00Z")
        XCTAssertEqual(body["package"] as? String, "com.example.foo")
        XCTAssertEqual(body["version"] as? String, "1.2")
        XCTAssertEqual(body["architecture"] as? String, "iphoneos-arm64")
        XCTAssertEqual(body["tweak"] as? String, "Foo")
        XCTAssertEqual(body["process"] as? String, "com.apple.springboard")
        XCTAssertEqual(body["reason"] as? String, "EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib (-[FooView layoutSubviews] + 16)")
        let exception = try XCTUnwrap(body["exception"] as? [String: Any])
        XCTAssertEqual(exception["type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertTrue(exception["name"] is NSNull)
        let frames = try XCTUnwrap(body["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["image"] as? String, "Foo.dylib")
        XCTAssertEqual(frames[0]["offset"] as? Int, 16256)
        XCTAssertTrue(frames[1]["symbol"] is NSNull)
        let others = try XCTUnwrap(body["otherTweaks"] as? [[String: Any]])
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others[0]["tweak"] as? String, "Bar")
        XCTAssertEqual(others[0]["package"] as? String, "com.example.bar")
        // The crash's own device and system win over the current ones.
        XCTAssertEqual(body["device"] as? String, "iPhone15,3")
        XCTAssertEqual(body["system"] as? String, "16.3.1")
        XCTAssertEqual(body["build"] as? String, "20D67")
        XCTAssertEqual(body["jailbreak"] as? String, "rootless")
        XCTAssertEqual(body["loader"] as? String, "burrow")
        XCTAssertEqual(body["client"] as? String, "Codling 0.1.0")
        // Nothing that identifies the device, and no incident identifier.
        let text = String(decoding: try Reports.body(report), as: UTF8.self)
        XCTAssertFalse(text.contains("11111111-2222"))
        XCTAssertFalse(text.lowercased().contains("udid"))
        XCTAssertEqual(Set(body.keys), ["format", "id", "date", "package", "version", "architecture", "tweak", "process",
                                        "reason", "exception", "frames", "otherTweaks", "device", "system", "build",
                                        "jailbreak", "loader", "client"])
    }

    func testNoReportWithoutAPackage() throws {
        var crash = try crash()
        crash.packages["Foo"] = nil
        XCTAssertNil(Reports.CrashReport(crash: crash, id: "abc", architecture: "iphoneos-arm64", device: device))
        crash = try self.crash()
        crash.tweak = nil
        XCTAssertNil(Reports.CrashReport(crash: crash, id: "abc", architecture: "iphoneos-arm64", device: device))
        crash = try self.crash()
        crash.exception = nil
        crash.date = nil
        let report = try XCTUnwrap(Reports.CrashReport(crash: crash, id: "abc", architecture: "iphoneos-arm64", device: device))
        let body = try object(Reports.body(report))
        XCTAssertTrue(body["exception"] is NSNull)
        XCTAssertTrue(body["date"] is NSNull)
    }

    func testInstallResult() throws {
        let failed = Reports.InstallResult(package: "com.example.foo", version: "1.2", architecture: "iphoneos-arm64",
                                           upgrade: false, installed: false, problems: ["unmet-dependencies"], device: device)
        var body = try object(Reports.body(failed))
        XCTAssertEqual(body["action"] as? String, "install")
        XCTAssertEqual(body["result"] as? String, "failed")
        XCTAssertEqual(body["problems"] as? [String], ["unmet-dependencies"])
        XCTAssertEqual(body["device"] as? String, "iPhone11,6")
        XCTAssertEqual(body["system"] as? String, "18.1.1")
        XCTAssertTrue(body["build"] is NSNull)
        let upgraded = Reports.InstallResult(package: "com.example.foo", version: "1.3", architecture: "iphoneos-arm64",
                                             upgrade: true, installed: true, problems: ["ignored"], device: device)
        body = try object(Reports.body(upgraded))
        XCTAssertEqual(body["action"] as? String, "upgrade")
        XCTAssertEqual(body["result"] as? String, "installed")
        XCTAssertEqual(body["problems"] as? [String], [])
        XCTAssertEqual(Set(body.keys), ["format", "package", "version", "architecture", "action", "result", "problems",
                                        "device", "system", "build", "jailbreak", "loader", "client"])
    }
}
