// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The files dpkg lists for installed packages.
enum PackageFiles {
    /// The files of an installed package, as dpkg names them; none when it
    /// is not installed. statusPath is dpkg's status file; its info
    /// directory beside it lists each package's files.
    static func listed(_ package: String, statusPath: String) -> [String] {
        let info = ((statusPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("info")
        let list = (info as NSString).appendingPathComponent("\(package).list")
        return ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
