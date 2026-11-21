// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit

/// The jailbreak layout Codling is running under.
enum JailbreakScheme: Equatable {
    /// Packages live under /var/jb (Dopamine).
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
    /// The package version, such as 0.1.0~dev.6, which the packaging script
    /// writes into Info.plist; the app's own version when it is missing.
    let version: String
    let systemVersion: String
    let deviceModel: String
    let bundlePath: String
    let scheme: JailbreakScheme
    /// The jailbreak root as people know it: /var/jb when rootless, the hidden
    /// root when RootHide; nil when not detected.
    let jailbreakRoot: String?

    static func current(bundle: Bundle = .main, fileManager: FileManager = .default) -> RuntimeEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let path = bundle.bundlePath
        let scheme = detectScheme(bundlePath: path, fileManager: fileManager)
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return RuntimeEnvironment(
            version: info["CodlingPackageVersion"] as? String ?? "\(short) (\(build))",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModel(),
            bundlePath: path,
            scheme: scheme,
            jailbreakRoot: jailbreakRoot(bundlePath: path, scheme: scheme)
        )
    }

    /// Where the app is installed, written from the jailbreak root: rootless
    /// /var/jb resolves into /private/preboot, which tells people nothing.
    var displayPath: String {
        guard scheme == .rootless else {
            return bundlePath
        }
        let resolved = ("/var/jb" as NSString).resolvingSymlinksInPath
        for prefix in [resolved, "/private" + resolved] where bundlePath.hasPrefix(prefix + "/") {
            return "/var/jb" + bundlePath.dropFirst(prefix.count)
        }
        return bundlePath
    }

    /// The package architecture of this jailbreak's scheme.
    var architecture: String {
        scheme == .roothide ? "iphoneos-arm64e" : "iphoneos-arm64"
    }

    /// The dpkg status file of this jailbreak.
    var dpkgStatusPath: String? {
        jailbreakRoot.map { $0 + "/var/lib/dpkg/status" }
    }

    static func jailbreakRoot(bundlePath: String, scheme: JailbreakScheme) -> String? {
        switch scheme {
        case .rootless:
            return "/var/jb"
        case .roothide:
            // The hidden root is the directory named .jbroot-<random>.
            guard let range = bundlePath.range(of: "/.jbroot-") else {
                return nil
            }
            let rest = bundlePath[range.upperBound...]
            let end = rest.firstIndex(of: "/") ?? rest.endIndex
            return String(bundlePath[..<end])
        case .unknown:
            return nil
        }
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
