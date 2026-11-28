// SPDX-License-Identifier: Apache-2.0

/// Rootless packages on RootHide.
///
/// RootHide's dpkg takes only iphoneos-arm64e packages. A rootless
/// (iphoneos-arm64) package must first be converted with RootHide Patcher,
/// RootHide's own app, as Sileo does there: Codling downloads the package,
/// hands it to RootHide Patcher, where the user chooses how to convert it,
/// and installs the converted file the user shares back to Codling. Codling
/// does not convert anything itself: the way that works differs from tweak
/// to tweak, and some cannot be converted.
public enum RootlessConversion {
    /// The architecture of rootless packages.
    public static let rootlessArchitecture = "iphoneos-arm64"
    /// RootHide's architecture.
    public static let roothideArchitecture = "iphoneos-arm64e"
    /// RootHide Patcher's package, in RootHide's repository.
    public static let patcherPackage = "com.roothide.patcher"

    /// The architecture whose packages a device with deviceArchitecture can
    /// install after converting them: rootless ones on RootHide, none
    /// elsewhere.
    public static func convertibleArchitecture(on deviceArchitecture: String) -> String? {
        deviceArchitecture == roothideArchitecture ? rootlessArchitecture : nil
    }

    /// Whether a package of architecture must be converted before a device
    /// with deviceArchitecture can install it.
    public static func needsConversion(_ architecture: String?, on deviceArchitecture: String) -> Bool {
        guard let architecture, let convertible = convertibleArchitecture(on: deviceArchitecture) else { return false }
        return architecture == convertible
    }

    /// The suffix RootHide Patcher adds to a version it converts with
    /// dynamic patches.
    public static let patchedSuffix = "~roothide"

    /// An installed version as the source's rootless build would have it:
    /// without the suffix RootHide Patcher may have added, which sorts
    /// before the plain version.
    public static func rootlessVersion(ofInstalled version: String) -> String {
        version.hasSuffix(patchedSuffix) ? String(version.dropLast(patchedSuffix.count)) : version
    }

    /// Whether a rootless build of version is newer than the installed
    /// version, which RootHide Patcher may have marked.
    public static func isNewer(_ version: String, thanInstalled installed: String) -> Bool {
        DebianVersion(version) > DebianVersion(rootlessVersion(ofInstalled: installed))
    }

    /// The offers to find updates in. A rootless build counts only when no
    /// source has a build for the device, so that converting is never
    /// suggested over RootHide's own build, and only when it is newer than
    /// the installed version as rootlessVersion reads it.
    public static func offersForUpdates(_ offers: [PackageSummary], installed: [String: String],
                                        on deviceArchitecture: String) -> [PackageSummary] {
        guard convertibleArchitecture(on: deviceArchitecture) != nil else { return offers }
        let native = Set(offers.lazy.filter { !needsConversion($0.architecture, on: deviceArchitecture) }.map(\.package))
        return offers.filter { offer in
            guard needsConversion(offer.architecture, on: deviceArchitecture) else { return true }
            guard !native.contains(offer.package) else { return false }
            return installed[offer.package].map { isNewer(offer.version, thanInstalled: $0) } ?? true
        }
    }

    /// The name to give the download, for RootHide Patcher, which names the
    /// converted file after it with the architecture changed: the record's
    /// own file name when it is a plain .deb name, or one made from the
    /// package, version and architecture.
    public static func fileName(package: String, version: String, filename: String?) -> String {
        if let last = filename?.split(separator: "/").last.map(String.init), last.hasSuffix(".deb"),
           last.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._+~-%".contains($0)) }),
           !last.hasPrefix(".") {
            return last
        }
        let safeVersion = version.replacingOccurrences(of: ":", with: "%3a")
        return "\(package)_\(safeVersion)_\(rootlessArchitecture).deb"
    }
}
