// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit

/// The jailbreak layout Codling is running under.
enum JailbreakScheme: Equatable {
    /// Packages live under /var/jb (Dopamine, palera1n rootless).
    case rootless
    /// Packages live in a hidden, randomised root (RootHide).
    case roothide
    /// Codling is installed somewhere it does not recognise.
    case unknown

    var title: String {
        switch self {
        case .rootless: return "Rootless"
        case .roothide: return "RootHide"
        case .unknown: return "Not detected"
        }
    }
}

/// Facts about the device and the installation that the rest of the app builds on.
struct RuntimeEnvironment {
    let appVersion: String
    let buildNumber: String
    let systemVersion: String
    let deviceModel: String
    let bundlePath: String
    let scheme: JailbreakScheme

    static func current(bundle: Bundle = .main, fileManager: FileManager = .default) -> RuntimeEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let path = bundle.bundlePath
        return RuntimeEnvironment(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            buildNumber: info["CFBundleVersion"] as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModel(),
            bundlePath: path,
            scheme: detectScheme(bundlePath: path, fileManager: fileManager)
        )
    }

    /// Works out the scheme from where the app bundle was installed.
    static func detectScheme(bundlePath: String, fileManager: FileManager) -> JailbreakScheme {
        // RootHide installs into a randomised ".jbroot-" directory.
        if bundlePath.contains("/.jbroot-") {
            return .roothide
        }
        // Rootless installs under /var/jb, which resolves into /private/preboot.
        let resolved = (bundlePath as NSString).resolvingSymlinksInPath
        if bundlePath.hasPrefix("/var/jb/") || resolved.contains("/procursus/") {
            return .rootless
        }
        if fileManager.fileExists(atPath: "/var/jb/Applications/Codling.app") {
            return .rootless
        }
        return .unknown
    }

    /// The hardware model identifier, for example "iPhone15,3".
    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
