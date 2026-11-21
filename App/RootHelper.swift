// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Codling's root helper, `codling-helper` inside the app bundle. Codling starts
/// it as root and it does only the commands it knows (see Helper/codling-helper.c).
enum RootHelper {
    /// What `codling-helper check` reports.
    struct Identity: Decodable, Equatable {
        let uid: UInt32
        let euid: UInt32
        let gid: UInt32
        let egid: UInt32
        let dpkgWritable: Bool

        var isRoot: Bool { uid == 0 && euid == 0 }
    }

    enum Failure: Error, Equatable {
        case missing
        case couldNotStart(String)
        case timedOut
        case failed(status: Int32, message: String)
        case unreadable(String)

        var message: String {
            switch self {
            case .missing:
                return "The helper is missing from Codling.app. Reinstall Codling."
            case .couldNotStart(let reason):
                return "The helper could not start: \(reason)."
            case .timedOut:
                return "The helper did not answer in time."
            case .failed(let status, let message):
                return message.isEmpty ? "The helper stopped with status \(status)." : message
            case .unreadable(let output):
                return "The helper's answer could not be read: \(output)"
            }
        }
    }

    /// What a program the helper ran printed, and how it ended.
    struct CommandResult: Decodable, Equatable {
        let status: Int32
        let output: String
    }

    /// What `codling-helper audit` reports: dpkg --audit and apt-get check.
    struct Audit: Decodable, Equatable {
        let dpkgAudit: CommandResult
        let aptCheck: CommandResult
    }

    static var path: String? {
        Bundle.main.path(forAuxiliaryExecutable: "codling-helper")
    }

    /// Runs `codling-helper check` as root. Blocks until it ends, so call it off
    /// the main thread.
    static func check() -> Result<Identity, Failure> {
        run(["check"]).flatMap { output in
            if let identity = try? JSONDecoder().decode(Identity.self, from: output) {
                return .success(identity)
            }
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let reported = try? JSONDecoder().decode([String: String].self, from: output),
               let error = reported["error"] {
                return .failure(.failed(status: 0, message: error))
            }
            return .failure(.unreadable(text))
        }
    }

    /// Runs dpkg --audit and apt-get check as root; they only read.
    static func audit() -> Result<Audit, Failure> {
        run(["audit"], timeoutMilliseconds: 120_000).flatMap { decode(Audit.self, from: $0) }
    }

    /// Runs dpkg --configure -a as root. It can take a while: a package's
    /// setup script may do real work. It has no time limit, as stopping it
    /// half way would leave packages half set up.
    static func configurePending() -> Result<CommandResult, Failure> {
        run(["configure-pending"], timeoutMilliseconds: noTimeLimit).flatMap { decode(CommandResult.self, from: $0) }
    }

    /// For commands that change packages: the helper is not stopped while
    /// dpkg works. Killing it would leave apt writing to a closed pipe, and
    /// apt and dpkg could stop half way through a change.
    private static let noTimeLimit: Int32 = 0

    /// Runs apt-get update as root, so that apt knows what Codling shows.
    static func updateLists() -> Result<CommandResult, Failure> {
        run(["update-lists"], timeoutMilliseconds: 600_000).flatMap { decode(CommandResult.self, from: $0) }
    }

    /// Asks apt what the operations would do; changes nothing.
    static func simulate(_ operations: [PackageOperation]) -> Result<CommandResult, Failure> {
        guard let arguments = arguments(for: operations) else {
            return .failure(.failed(status: 64, message: "A package name is not one apt accepts."))
        }
        return run(["simulate"] + arguments, timeoutMilliseconds: 120_000).flatMap { decode(CommandResult.self, from: $0) }
    }

    /// Makes the change. trustUnsigned allows packages from sources that are
    /// not signed; allowRemovals allows apt to remove packages the operations
    /// do not name, as the reviewed plan showed.
    static func apply(_ operations: [PackageOperation], trustUnsigned: Bool, allowRemovals: Bool) -> Result<CommandResult, Failure> {
        install("apply", operations, trustUnsigned: trustUnsigned, allowRemovals: allowRemovals)
    }

    /// Downloads what apply would install and changes nothing else. apt
    /// checks signatures here, as it does not in a simulation: without
    /// trustUnsigned it stops at packages from sources that are not
    /// signed, before downloading, and names them.
    static func download(_ operations: [PackageOperation], trustUnsigned: Bool, allowRemovals: Bool) -> Result<CommandResult, Failure> {
        install("download", operations, trustUnsigned: trustUnsigned, allowRemovals: allowRemovals)
    }

    private static func install(_ command: String, _ operations: [PackageOperation], trustUnsigned: Bool,
                                allowRemovals: Bool) -> Result<CommandResult, Failure> {
        guard let arguments = arguments(for: operations) else {
            return .failure(.failed(status: 64, message: "A package name is not one apt accepts."))
        }
        var options: [String] = []
        if trustUnsigned {
            options.append("--trust-unsigned")
        }
        if allowRemovals {
            options.append("--allow-removals")
        }
        // A download can be stopped safely; a change cannot.
        return run([command] + options + arguments, timeoutMilliseconds: command == "apply" ? noTimeLimit : 1_800_000)
            .flatMap { decode(CommandResult.self, from: $0) }
    }

    /// What `codling-helper backup` reports for each package.
    struct BackupReport: Decodable, Equatable {
        struct Entry: Decodable, Equatable {
            let package: String
            let version: String
            let file: String?
            let error: String?
        }

        let backups: [Entry]
    }

    /// Rebuilds the installed packages' .debs into the helper's backups, so
    /// that undo can put them back.
    static func backup(_ packages: [String]) -> Result<BackupReport, Failure> {
        guard !packages.isEmpty, packages.allSatisfy(PackageOperation.isValidName) else {
            return .failure(.failed(status: 64, message: "A package name is not one apt accepts."))
        }
        return run(["backup"] + packages, timeoutMilliseconds: 900_000).flatMap { decode(BackupReport.self, from: $0) }
    }

    /// Stops SpringBoard, which launchd starts again: what Respring falls
    /// back to when Codling cannot signal SpringBoard itself.
    static func respring() -> Result<CommandResult, Failure> {
        run(["respring"], timeoutMilliseconds: 30_000).flatMap { decode(CommandResult.self, from: $0) }
    }

    /// What add-source and remove-source report.
    struct SourceChange: Decodable, Equatable {
        let changed: Bool
    }

    /// Adds a flat repository to codling.sources. uri must be as
    /// SourceList.repositoryURI writes it; the helper checks it again.
    static func addSource(_ uri: String) -> Result<SourceChange, Failure> {
        run(["add-source", uri], timeoutMilliseconds: 30_000).flatMap { decode(SourceChange.self, from: $0) }
    }

    /// Takes a repository out of every sources file apt reads.
    static func removeSource(_ uri: String) -> Result<SourceChange, Failure> {
        run(["remove-source", uri], timeoutMilliseconds: 30_000).flatMap { decode(SourceChange.self, from: $0) }
    }

    /// What take-purchase reports about the download it checked and kept.
    struct PurchaseCopy: Decodable, Equatable {
        let package: String
        let version: String
        let sha256: String
    }

    /// Has the helper take the package Codling downloaded after a purchase
    /// (PurchaseInbox), check it against the SHA256 hash apt lists for the
    /// version, and keep it for a $package=version operation. apt installs
    /// it from its own cache, after checking the source's signature as it
    /// does for any package.
    static func takePurchase(_ package: String, version: String) -> Result<PurchaseCopy, Failure> {
        guard PackageOperation.purchased(package, version: version).isValid else {
            return .failure(.failed(status: 64, message: "The package name or version is not one apt accepts."))
        }
        return run(["take-purchase", package, version], timeoutMilliseconds: 120_000)
            .flatMap { decode(PurchaseCopy.self, from: $0) }
    }

    /// Runs Burrow's `burrowctl json`, which reports the tweak loader, the
    /// loader settings, every tweak and Safe Mode's events. It changes nothing.
    static func burrowState() -> Result<CommandResult, Failure> {
        run(["burrow-state"], timeoutMilliseconds: 30_000).flatMap { decode(CommandResult.self, from: $0) }
    }

    /// Turns a tweak back on or off with burrowctl, in one process, named by
    /// its bundle identifier or executable name, or everywhere.
    static func burrowTweak(on: Bool, tweak: String, process: String?) -> Result<CommandResult, Failure> {
        run(["burrow-tweak", on ? "on" : "off", tweak] + (process.map { [$0] } ?? []), timeoutMilliseconds: 30_000)
            .flatMap { decode(CommandResult.self, from: $0) }
    }

    /// Makes Burrow's or ElleKit's loader load the tweaks into new processes.
    static func burrowLoader(burrow: Bool) -> Result<CommandResult, Failure> {
        run(["burrow-loader", burrow ? "burrow" : "ellekit"], timeoutMilliseconds: 60_000)
            .flatMap { decode(CommandResult.self, from: $0) }
    }

    private static func arguments(for operations: [PackageOperation]) -> [String]? {
        guard !operations.isEmpty, operations.allSatisfy(\.isValid) else {
            return nil
        }
        return operations.map(\.helperArgument)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: Data) -> Result<T, Failure> {
        if let value = try? JSONDecoder().decode(type, from: output) {
            return .success(value)
        }
        if let reported = try? JSONDecoder().decode([String: String].self, from: output), let error = reported["error"] {
            return .failure(.failed(status: 0, message: error))
        }
        return .failure(.unreadable(String(decoding: output, as: UTF8.self)))
    }

    private static func run(_ arguments: [String], timeoutMilliseconds: Int32 = 10_000) -> Result<Data, Failure> {
        guard let path else {
            return .failure(.missing)
        }
        let strings = ([path] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } } + [nil]

        var result = codling_result()
        let started = pointers.withUnsafeBufferPointer { list in
            codling_run_as_root(path, list.baseAddress, timeoutMilliseconds, &result)
        }
        defer { codling_result_free(&result) }

        if started != 0 {
            return .failure(.couldNotStart(String(cString: strerror(result.spawn_error))))
        }
        if result.timed_out {
            return .failure(.timedOut)
        }
        let output = result.output.map { Data(bytes: $0, count: result.output_length) } ?? Data()
        if result.status != 0 {
            let errors = result.errors.map { String(cString: $0) } ?? ""
            var message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty,
               let reported = try? JSONDecoder().decode([String: String].self, from: output) {
                message = reported["error"] ?? ""
            }
            return .failure(.failed(status: result.status, message: message))
        }
        return .success(output)
    }
}
