// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class ControlFileTests: XCTestCase {
    func testStanzasContinuationsCommentsAndCarriageReturns() {
        let text = "# a comment\nPackage: one\r\nDescription: first\r\n second\r\n .\r\n third\r\n\r\n\n\nPackage: two\n"
        let stanzas = ControlFile.stanzas(in: text)
        XCTAssertEqual(stanzas.count, 2)
        XCTAssertEqual(stanzas[0]["package"], "one")
        XCTAssertEqual(stanzas[0]["Description"], "first\nsecond\n.\nthird")
        XCTAssertEqual(stanzas[1]["Package"], "two")
    }
}

final class SourceListTests: XCTestCase {
    // As Sileo, Procursus and Dopamine's defaults write them.
    let deb822 = """
        Types: deb
        URIs: https://havoc.app/
        Suites: ./
        Components:

        Types: deb
        URIs: http://apt.thebigboss.org/repofiles/cydia/
        Suites: stable
        Components: main

        Types: deb
        URIs: https://apt.procurs.us/
        Suites: 1900
        Components: main

        Types: deb deb-src
        URIs: https://one.example/ https://two.example/repo
        Suites: ./
        Signed-By: /var/jb/etc/apt/keys/example.gpg

        Enabled: no
        Types: deb
        URIs: https://off.example/
        Suites: ./

        Types: deb-src
        URIs: https://source.example/
        Suites: ./
        """

    func testDeb822() {
        let sources = SourceList.parseDeb822(deb822, file: "sileo.sources")
        XCTAssertEqual(sources.map(\.uri), ["https://havoc.app/", "http://apt.thebigboss.org/repofiles/cydia/",
                                            "https://apt.procurs.us/", "https://one.example/", "https://two.example/repo/"])
        XCTAssertTrue(sources[0].isFlat)
        XCTAssertEqual(sources[0].components, [])
        XCTAssertEqual(sources[1].suite, "stable")
        XCTAssertEqual(sources[1].components, ["main"])
        XCTAssertEqual(sources[2].suite, "1900")
        XCTAssertEqual(sources[3].signedBy, ["/var/jb/etc/apt/keys/example.gpg"])
        XCTAssertEqual(sources[3].file, "sileo.sources")
    }

    func testOneLine() {
        let text = """
            # comment
            deb https://repo.example/ ./
            deb [signed-by=/k.gpg trusted=yes] https://dist.example stable main extra # trailing
            deb-src https://src.example/ ./
            """
        let sources = SourceList.parseOneLine(text)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].uri, "https://repo.example/")
        XCTAssertTrue(sources[0].isFlat)
        XCTAssertEqual(sources[1].uri, "https://dist.example/")
        XCTAssertEqual(sources[1].components, ["main", "extra"])
        XCTAssertEqual(sources[1].signedBy, ["/k.gpg"])
        XCTAssertTrue(sources[1].trusted)
    }

    func testPaths() {
        let flat = Source(uri: "https://havoc.app/", suite: "./", components: [])
        XCTAssertEqual(flat.releaseDirectory, "https://havoc.app/./")
        XCTAssertEqual(flat.releaseDirectoryURL?.absoluteString, "https://havoc.app/")
        XCTAssertEqual(flat.packageIndexPaths(architecture: "iphoneos-arm64"), ["Packages"])
        let dist = Source(uri: "https://apt.procurs.us", suite: "1900", components: ["main"])
        XCTAssertEqual(dist.releaseDirectory, "https://apt.procurs.us/dists/1900/")
        XCTAssertEqual(dist.packageIndexPaths(architecture: "iphoneos-arm64"), ["main/binary-iphoneos-arm64/Packages"])
        XCTAssertEqual(dist.host, "apt.procurs.us")
    }
}

final class ReleaseFileTests: XCTestCase {
    func testEntriesAndPreferredFile() throws {
        let text = """
            Origin: Example
            Label: Example Repo
            Suite: stable
            MD5Sum:
             0123456789abcdef0123456789abcdef 1000 Packages
             fedcba9876543210fedcba9876543210 400 Packages.gz
            SHA256:
             AAAA 1000 Packages
             bbbb  400 Packages.gz
             cccc 300 Packages.xz
            """
        let release = try XCTUnwrap(ReleaseFile(text: text))
        XCTAssertEqual(release.label, "Example Repo")
        XCTAssertEqual(release.entries["Packages"]?.digests["SHA256"], "aaaa")
        XCTAssertEqual(release.entries["Packages.gz"]?.size, 400)
        let preferred = try XCTUnwrap(release.preferredFile(for: "Packages"))
        XCTAssertEqual(preferred.path, "Packages.xz")
        XCTAssertEqual(preferred.compression, "xz")
        XCTAssertNil(release.preferredFile(for: "main/binary-iphoneos-arm64/Packages"))
    }

    func testMD5Only() throws {
        let release = try XCTUnwrap(ReleaseFile(text: "Origin: Old\nMD5Sum:\n 0123 20 Packages.bz2\n"))
        XCTAssertEqual(release.preferredFile(for: "Packages")?.entry.digests, ["MD5Sum": "0123"])
    }
}

final class AptNamingTests: XCTestCase {
    func testListFileNames() {
        XCTAssertEqual(AptNaming.listFileName(for: "https://havoc.app/./Packages"), "havoc.app_._Packages")
        XCTAssertEqual(AptNaming.listFileName(for: "https://apt.procurs.us/dists/1900/main/binary-iphoneos-arm64/Packages"),
                       "apt.procurs.us_dists_1900_main_binary-iphoneos-arm64_Packages")
        XCTAssertEqual(AptNaming.listFileName(for: "https://api.nexusjb.com/repos/beta/./InRelease"),
                       "api.nexusjb.com_repos_beta_._InRelease")
        XCTAssertEqual(AptNaming.listFileName(for: "https://user:secret@host.example:8443/a_b~c/Release"),
                       "host.example:8443_a%5fb%7ec_Release")
    }
}

final class PackageIndexTests: XCTestCase {
    func testParse() {
        let text = """
            Package: com.example.one
            Version: 1.0
            Architecture: iphoneos-arm64
            Name: One
            Author: Jane <jane@example.com>
            Description: First line
             more text
             .
             last
            SileoDepiction: https://example.com/one.json
            Filename: ./debs/one.deb
            Size: 1234
            SHA256: ABCD
            Unknown-Field: kept out
             continued

            Package: com.example.arm
            Version: 2.0
            Architecture: iphoneos-arm

            Package: com.example.all
            Version: 3.0
            Architecture: all

            Package: com.example.noversion

            Package: com.example.last\r
            Version: 4.0\r
            """
        let records = PackageIndex.parse(Data(text.utf8), architecture: "iphoneos-arm64")
        XCTAssertEqual(records.map(\.package), ["com.example.one", "com.example.all", "com.example.last"])
        let one = records[0]
        XCTAssertEqual(one.name, "One")
        XCTAssertEqual(one.description, "First line\nmore text\n.\nlast")
        XCTAssertEqual(one.summary, "First line")
        XCTAssertEqual(one.sileoDepiction, "https://example.com/one.json")
        XCTAssertEqual(one.size, 1234)
        XCTAssertEqual(one.sha256, "abcd")
        XCTAssertEqual(records[2].version, "4.0")
    }
}

final class AptDiagnosticsTests: XCTestCase {
    private func ids(_ output: String) -> [String] {
        AptDiagnostics.diagnose(output).map(\.id)
    }

    // Each line as apt or dpkg prints it.
    func testCommonErrors() {
        let cases: [(String, String, AptDiagnosis.Fix?)] = [
            ("E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem.", "dpkg-interrupted", .configurePending),
            ("The following packages are only half configured, probably due to problems", "half-configured", .configurePending),
            ("The following packages have been unpacked but not yet configured. They must be configured using", "half-configured", .configurePending),
            ("dpkg: error processing package com.example (--configure): package is in a very bad inconsistent state; you should", "needs-reinstall", nil),
            ("E: Could not get lock /var/jb/var/lib/dpkg/lock-frontend. It is held by process 412 (Sileo)", "lock-held", .retry),
            ("E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?", "lock-held", .retry),
            ("dpkg: error processing archive /tmp/x.deb (--install): package architecture (iphoneos-arm) does not match system (iphoneos-arm64)", "architecture-mismatch", nil),
            ("Codling needs an Apple A12 chip or newer: iPhone XS, iPhone XR or a later device.", "old-chip", nil),
            ("dpkg: error processing archive /tmp/b.deb (--unpack): trying to overwrite '/var/jb/usr/lib/libfoo.dylib', which is also in package com.example.a 1.0", "file-conflict", nil),
            ("E: Unmet dependencies. Try 'apt --fix-broken install' with no packages (or specify a solution).", "unmet-dependencies", .refreshSources),
            (" com.example.b : Depends: com.example.c (>= 2.0) but it is not going to be installed", "unmet-dependencies", .refreshSources),
            ("E: Unable to locate package com.example.missing", "unknown-package", .refreshSources),
            ("E: Failed to fetch https://repo.example/./Packages.xz  Hash Sum mismatch", "hash-mismatch", .retry),
            ("W: GPG error: https://repo.example ./ InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF", "missing-key", nil),
            ("W: GPG error: https://repo.example ./ InRelease: The following signatures were invalid: BADSIG 0123456789ABCDEF", "bad-signature", nil),
            ("E: Release file for https://repo.example/./InRelease is not valid yet (invalid for another 2d 3h).", "not-valid-yet", .refreshSources),
            ("E: Release file for https://repo.example/./InRelease is expired (invalid since 12d 4h).", "expired", nil),
            ("Err:3 https://repo.example ./ InRelease  Temporary failure resolving 'repo.example'", "no-network", .retry),
            ("E: Failed to fetch https://repo.example/debs/a.deb  404  Not Found", "not-found", .refreshSources),
            ("E: You don't have enough free space in /var/jb/var/cache/apt/archives/.", "disk-full", .retry),
            ("dpkg-deb: error: '/tmp/a.deb' is not a Debian format archive", "damaged-archive", .retry),
            ("E: Malformed entry 3 in list file /var/jb/etc/apt/sources.list.d/x.list (Component)", "malformed-sources", nil),
            ("E: Sub-process /var/jb/usr/bin/dpkg returned an error code (1)", "dpkg-failed", .configurePending),
        ]
        for (line, id, fix) in cases {
            let found = AptDiagnostics.diagnose(line)
            XCTAssertEqual(found.map(\.id), [id], line)
            XCTAssertEqual(found.first?.fix, fix, line)
        }
    }

    func testDetailsFromTheLine() {
        let conflict = AptDiagnostics.diagnose("trying to overwrite '/a/b', which is also in package com.example.a 1.0")[0]
        XCTAssertTrue(conflict.explanation.contains("/a/b"))
        XCTAssertTrue(conflict.advice.contains("com.example.a"))
        let architecture = AptDiagnostics.diagnose("package architecture (iphoneos-arm) does not match system (iphoneos-arm64)")[0]
        XCTAssertTrue(architecture.explanation.contains("iphoneos-arm,"))
        XCTAssertTrue(architecture.advice.contains("iphoneos-arm64 version"))
    }

    func testSpecificProblemsHideTheGenericFailure() {
        let output = """
            Selecting previously unselected package com.example.b.
            dpkg: error processing archive /tmp/b.deb (--unpack):
             trying to overwrite '/var/jb/usr/lib/libfoo.dylib', which is also in package com.example.a 1.0
            Errors were encountered while processing:
             /tmp/b.deb
            E: Sub-process /var/jb/usr/bin/dpkg returned an error code (1)
            """
        XCTAssertEqual(ids(output), ["file-conflict"])
        XCTAssertEqual(ids("E: Sub-process /usr/bin/dpkg returned an error code (1)\nErrors were encountered while processing:"),
                       ["dpkg-failed"])
    }

    func testCleanOutput() {
        XCTAssertEqual(ids("Reading package lists...\nBuilding dependency tree...\nReading state information..."), [])
    }
}
