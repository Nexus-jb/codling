// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class PiracySourcesTests: XCTestCase {
    func testMatching() {
        XCTAssertEqual(PiracySources.entry(for: "http://repo.hackyouriphone.org/")?.name, "HackYouriPhone")
        XCTAssertEqual(PiracySources.entry(for: "repo.hackyouriphone.org")?.name, "HackYouriPhone")
        XCTAssertEqual(PiracySources.entry(for: "https://REPO.HackYouriPhone.org")?.name, "HackYouriPhone")
        XCTAssertEqual(PiracySources.entry(for: "https://www.cydia.vn/")?.name, "cydia.vn")
        // A subdomain is covered too.
        XCTAssertEqual(PiracySources.entry(for: "https://mirror.cydia.iphonecake.com/")?.name, "AppCake (iPhoneCake)")
        // A path entry covers only that path.
        XCTAssertEqual(PiracySources.entry(for: "http://ihackstore.com/repo/")?.name, "iHackStore")
        XCTAssertEqual(PiracySources.entry(for: "http://ihackstore.com/repo")?.name, "iHackStore")
        XCTAssertNil(PiracySources.entry(for: "http://ihackstore.com/blog/"))
        // Names that only look alike are not.
        XCTAssertNil(PiracySources.entry(for: "https://notcydia.vn/"))
        XCTAssertNil(PiracySources.entry(for: "https://cydia.vn.example.com/"))
        // Sources people use every day.
        for source in ["https://havoc.app/", "https://repo.chariz.com/", "https://repo.nexusjb.com/",
                       "https://apt.procurs.us/", "http://limneos.net/repo/", "https://repo.packix.com/"] {
            XCTAssertNil(PiracySources.entry(for: source), source)
        }
    }

    func testEntriesAreWellFormed() {
        var hosts = Set<String>()
        for entry in PiracySources.entries {
            XCTAssertEqual(entry.host, entry.host.lowercased())
            XCTAssertFalse(entry.host.hasPrefix("www."))
            XCTAssertTrue(hosts.insert(entry.host + (entry.path ?? "")).inserted, entry.host)
            if let path = entry.path {
                XCTAssertTrue(path.hasPrefix("/") && !path.hasSuffix("/"), path)
            }
        }
    }

    func testRepositoryURI() {
        XCTAssertEqual(SourceList.repositoryURI(from: "repo.example.com"), "https://repo.example.com/")
        XCTAssertEqual(SourceList.repositoryURI(from: "  HTTP://Repo.Example.com/Path  "), "http://repo.example.com/Path/")
        XCTAssertEqual(SourceList.repositoryURI(from: "https://example.github.io/repo/"), "https://example.github.io/repo/")
        XCTAssertEqual(SourceList.repositoryURI(from: "https://example.com/~me/repo+beta"), "https://example.com/~me/repo+beta/")
        for bad in ["", "ftp://example.com/", "https://", "https://localhost/", "https://exa mple.com/",
                    "https://example.com/a b/", "https://example.com/?x=1", "https://example.com/#x",
                    "https://user@example.com/", "https://example.com/../etc/", "https://example.com/a\nb",
                    "https://example.com:8080/", "https://-example.com/", "file:///etc/"] {
            XCTAssertNil(SourceList.repositoryURI(from: bad), bad)
        }
    }
}
