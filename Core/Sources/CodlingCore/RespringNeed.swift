// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether a change to packages takes effect only once SpringBoard restarts:
/// one of them has a tweak, a theme, or a library or framework that tweaks
/// load. A keyring, an app or a command-line tool does not need it.
public enum RespringNeed {
    /// files: what dpkg lists for each package the change installed,
    /// upgraded or removed, as it names them.
    public static func needed(files: [String]) -> Bool {
        files.contains(where: needs)
    }

    static func needs(_ file: String) -> Bool {
        // An app's own libraries load into the app only.
        if file.contains(".app/") {
            return false
        }
        let folders = ["/Library/MobileSubstrate/DynamicLibraries/", "/usr/lib/TweakInject/", "/Library/TweakInject/",
                       "/Library/Themes/"]
        if folders.contains(where: file.contains) {
            return true
        }
        if file.hasSuffix(".dylib") {
            return true
        }
        return file.contains("/Library/Frameworks/") && file.contains(".framework/")
    }
}
