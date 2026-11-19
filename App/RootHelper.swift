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
                return "The helper did not answer within 10 seconds."
            case .failed(let status, let message):
                return message.isEmpty ? "The helper stopped with status \(status)." : message
            case .unreadable(let output):
                return "The helper's answer could not be read: \(output)"
            }
        }
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
