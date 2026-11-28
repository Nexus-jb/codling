// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation
import SwiftUI
import UIKit

/// Finds the pages an installed tweak adds to the Settings app, and opens
/// them there. iOS 18 moved them to the end of General, where few people
/// look for them.
enum TweakSettings {
    /// The pages an installed package adds, from the PreferenceLoader plists
    /// among its files; none when it is not installed. statusPath is dpkg's
    /// status file; its info directory beside it lists each package's files.
    static func panes(package: String, installed: String?, statusPath: String?) async -> [SettingsPane] {
        guard installed != nil, let statusPath else { return [] }
        return await Task.detached(priority: .userInitiated) {
            TweakSettings.panes(package: package, statusPath: statusPath)
        }.value
    }

    private static func panes(package: String, statusPath: String) -> [SettingsPane] {
        let dpkg = (statusPath as NSString).deletingLastPathComponent
        let info = (dpkg as NSString).appendingPathComponent("info")
        let root = dpkg.replacingOccurrences(of: "/var/lib/dpkg", with: "")
        let list = (info as NSString).appendingPathComponent("\(package).list")
        let files = ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var panes: [SettingsPane] = []
        for file in files.sorted() where SettingsPane.isEntryFile(file) {
            guard let plist = SettingsCleanup.readPlist(SettingsCleanup.path(file, root: root)),
                  let pane = SettingsPane.pane(in: plist, coreFoundationVersion: kCFCoreFoundationVersionNumber),
                  !panes.contains(pane) else { continue }
            panes.append(pane)
        }
        return panes
    }

    /// Opens the page in Settings. Returns false when the system would not
    /// open it.
    @MainActor
    static func open(_ pane: SettingsPane, systemVersion: String) async -> Bool {
        guard let address = SettingsPane.address(of: pane, systemVersion: systemVersion),
              let url = URL(string: address) else { return false }
        // Settings addresses are sensitive: an app opens them through
        // LaunchServices with com.apple.springboard.opensensitiveurl. The
        // class is private, so it is looked up at run time.
        if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type {
            let defaultWorkspace = NSSelectorFromString("defaultWorkspace")
            let openSensitive = NSSelectorFromString("openSensitiveURL:withOptions:")
            if workspaceClass.responds(to: defaultWorkspace),
               let workspace = workspaceClass.perform(defaultWorkspace)?.takeUnretainedValue() as? NSObject,
               workspace.responds(to: openSensitive) {
                typealias OpenSensitive = @convention(c) (NSObject, Selector, NSURL, NSDictionary?) -> Bool
                let method = unsafeBitCast(workspace.method(for: openSensitive), to: OpenSensitive.self)
                if method(workspace, openSensitive, url as NSURL, nil) {
                    return true
                }
            }
        }
        return await UIApplication.shared.open(url)
    }
}

/// The buttons that open an installed tweak's pages in Settings: Settings
/// for one page, each page's title for more.
struct TweakSettingsButtons: View {
    let panes: [SettingsPane]
    @Environment(\.device) private var device
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panes, id: \.identifier) { pane in
                Button {
                    Task {
                        failed = !(await TweakSettings.open(pane, systemVersion: device.systemVersion))
                    }
                } label: {
                    Label(panes.count == 1 ? "Settings" : pane.title, systemImage: "gearshape")
                }
                .buttonStyle(TintedButtonStyle())
            }
            if SettingsPane.inGeneral(systemVersion: device.systemVersion) {
                Text(panes.count == 1 ? "Its page is at the end of General in Settings."
                     : "Its pages are at the end of General in Settings.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Settings Did Not Open", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The system did not let Codling open the page.")
        }
    }
}
