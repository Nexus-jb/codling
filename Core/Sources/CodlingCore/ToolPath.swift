// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Paths as the jailbreak's own programs see them.
///
/// Codling works with real paths. RootHide's programs, such as gpgv, see the
/// hidden jailbreak root as / and the system volume under /rootfs, so a path
/// given to one of them on its command line or in its environment must be
/// written their way: a path inside the root loses the root's own path, and
/// any other path gains /rootfs. Rootless programs see real paths, so nothing
/// changes there. Helper/tool-path.h does the same for the helper.
public enum ToolPath {
    /// Whether root is a RootHide root: a directory whose name starts with
    /// ".jbroot-".
    public static func isRootHide(root: String) -> Bool {
        guard let name = root.split(separator: "/", omittingEmptySubsequences: true).last else { return false }
        return name.hasPrefix(".jbroot-") && name.count > ".jbroot-".count
    }

    /// The path that the programs of the jailbreak rooted at root see for the
    /// real path. The root may be written with or without /private in front,
    /// and so may the path.
    public static func convert(_ path: String, root: String) -> String {
        guard isRootHide(root: root) else { return path }
        let forms = root.hasPrefix("/private/") ? [root, String(root.dropFirst("/private".count))] : [root, "/private" + root]
        for form in forms {
            if path == form {
                return "/"
            }
            if path.hasPrefix(form + "/") {
                return String(path.dropFirst(form.count))
            }
        }
        return "/rootfs" + path
    }
}
