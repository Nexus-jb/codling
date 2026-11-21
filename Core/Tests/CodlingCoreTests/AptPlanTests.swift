// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class AptPlanTests: XCTestCase {
    func testSimulation() {
        let output = """
            Reading package lists...
            Building dependency tree...
            Reading state information...
            The following NEW packages will be installed:
              jq libjq1 libonig5
            0 upgraded, 3 newly installed, 0 to remove and 12 not upgraded.
            WARNING: The following packages cannot be authenticated!
              com.example.tweak com.example.same
            Inst libonig5 (6.9.9-1 Procursus:1900 [iphoneos-arm64])
            Inst libjq1 (1.7.1-1 Procursus:1900 [iphoneos-arm64])
            Inst jq (1.7.1-1 Procursus:1900 [iphoneos-arm64])
            Inst com.example.tweak [1.0] (1.2 Example Repo:./ [iphoneos-arm64]) []
            Inst com.example.same [2.0] (2.0 Example:./ [iphoneos-arm64])
            Inst com.example.old [3.0] (2.5 Example:./ [iphoneos-arm64])
            Inst local.package (1.0 [iphoneos-arm64])
            Conf libonig5 (6.9.9-1 Procursus:1900 [iphoneos-arm64])
            Remv com.example.gone [0.9]
            Purg com.example.purged [1.1] [com.example.other ]
            """
        let plan = AptPlan.parse(output)
        XCTAssertEqual(plan.unauthenticated, ["com.example.tweak", "com.example.same"])
        XCTAssertEqual(plan.changes, [
            .init(kind: .install, package: "libonig5", version: "6.9.9-1", origin: "Procursus:1900"),
            .init(kind: .install, package: "libjq1", version: "1.7.1-1", origin: "Procursus:1900"),
            .init(kind: .install, package: "jq", version: "1.7.1-1", origin: "Procursus:1900"),
            .init(kind: .upgrade, package: "com.example.tweak", version: "1.2", previousVersion: "1.0", origin: "Example Repo:./"),
            .init(kind: .reinstall, package: "com.example.same", version: "2.0", previousVersion: "2.0", origin: "Example:./"),
            .init(kind: .downgrade, package: "com.example.old", version: "2.5", previousVersion: "3.0", origin: "Example:./"),
            .init(kind: .install, package: "local.package", version: "1.0"),
            .init(kind: .remove, package: "com.example.gone", version: "0.9"),
            .init(kind: .remove, package: "com.example.purged", version: "1.1"),
        ])
        XCTAssertTrue(plan.removesPackages)
        XCTAssertEqual(plan.changes(.install).map(\.package), ["libonig5", "libjq1", "jq", "local.package"])
        XCTAssertTrue(AptPlan.parse("Reading package lists...\n0 upgraded, 0 newly installed.").isEmpty)
    }

    func testInstallProblems() {
        func ids(_ text: String) -> [String] { AptDiagnostics.diagnose(text).map(\.id) }
        XCTAssertEqual(ids("E: There were unauthenticated packages and -y was used without --allow-unauthenticated"),
                       ["unauthenticated"])
        XCTAssertEqual(ids("E: Packages need to be removed but remove is disabled."), ["removals-not-reviewed"])
        XCTAssertEqual(ids("WARNING: The following essential packages will be removed.\nThis should NOT be done unless you know exactly what you are doing!\nE: Essential packages were removed and -y was used without --allow-remove-essential.\nYou are about to do something potentially harmful."),
                       ["essential-package"])
        XCTAssertEqual(ids("E: Failed to fetch https://repo.example/debs/paid.deb  403  Forbidden [IP: 1.2.3.4 443]"),
                       ["refused-download"])
        XCTAssertEqual(ids("E: Failed to fetch https://repo.example/debs/gone.deb  404  Not Found [IP: 1.2.3.4 443]"),
                       ["not-found"])
    }

    func testUndo() {
        let before = ["a": "1.0", "b": "2.0", "c": "3.0", "kept": "1"]
        let after = ["a": "1.1", "c": "3.0", "kept": "1", "new": "0.1", "dep": "5"]
        let plan = UndoPlanner.plan(before: before, after: after, backups: ["a": "1.0", "b": "1.9"])
        XCTAssertEqual(plan.operations, [.remove("dep"), .remove("new"), .restore("a", version: "1.0")])
        XCTAssertEqual(plan.missing, ["b"])
        XCTAssertEqual(UndoPlanner.plan(before: before, after: before, backups: [:]), .init(operations: [], missing: []))
        XCTAssertEqual(PackageOperation.restore("a", version: "1:2.0-1").helperArgument, "@a=1:2.0-1")
        XCTAssertTrue(PackageOperation.restore("a.b", version: "1:2.0~beta1+x").isValid)
        XCTAssertFalse(PackageOperation.restore("a.b", version: "v1").isValid)
        XCTAssertFalse(PackageOperation.restore("a.b", version: "1 0").isValid)
        XCTAssertFalse(PackageOperation.restore("a.b", version: "1/../x").isValid)
        XCTAssertEqual(PackageOperation.purchased("com.example.paid", version: "1:1.2.5").helperArgument,
                       "$com.example.paid=1:1.2.5")
        XCTAssertTrue(PackageOperation.purchased("com.example.paid", version: "1.2.5").isValid)
        XCTAssertFalse(PackageOperation.purchased("com.example.paid", version: "1.2.5 x").isValid)
        XCTAssertFalse(PackageOperation.purchased("-paid", version: "1.0").isValid)
        XCTAssertEqual(PackageOperation.purchased("com.example.paid", version: "1.0").package, "com.example.paid")
    }

    func testOperations() {
        XCTAssertEqual(PackageOperation.install("jq").helperArgument, "+jq")
        XCTAssertEqual(PackageOperation.remove("com.example.tweak").helperArgument, "-com.example.tweak")
        for name in ["jq", "com.example.tweak", "libstdc++", "Aemulo2", "a-b.c"] {
            XCTAssertTrue(PackageOperation.isValidName(name), name)
        }
        for name in ["j", "-jq", "jq-", "jq.", "a b", "a/b", "*", "--yes", "jq=1.0", "ålib", String(repeating: "a", count: 129)] {
            XCTAssertFalse(PackageOperation.isValidName(name), name)
        }
    }
}
