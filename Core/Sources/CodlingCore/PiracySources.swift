// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Sources that published articles describe as handing out paid packages, or
/// cracked apps, without their developers' permission. Codling warns before
/// one is added and marks one that is there; it never blocks, hides or slows
/// a source. docs/piracy-sources.md gives the evidence for each entry and how
/// to propose or contest one.
public enum PiracySources {
    public struct Entry: Equatable {
        /// The host, which also covers its subdomains.
        public let host: String
        /// The path the repository lives under, when the host serves other
        /// things too.
        public let path: String?
        public let name: String

        public init(host: String, path: String? = nil, name: String) {
            self.host = host
            self.path = path
            self.name = name
        }
    }

    public static let entries: [Entry] = [
        Entry(host: "cydia.iphonecake.com", name: "AppCake (iPhoneCake)"),
        Entry(host: "cydia.hackulo.us", name: "Hackulous"),
        Entry(host: "cydia.vn", name: "cydia.vn"),
        Entry(host: "cydia.xsellize.com", name: "xSellize"),
        Entry(host: "ihackstore.com", path: "/repo", name: "iHackStore"),
        Entry(host: "ihacksrepo.com", name: "iHacks"),
        Entry(host: "p0dulo.com", name: "P0dulo"),
        Entry(host: "repo.biteyourapple.net", name: "BiteYourApple"),
        Entry(host: "repo.hackyouriphone.org", name: "HackYouriPhone"),
        Entry(host: "repo.insanelyi.com", name: "iNSANELYi"),
        Entry(host: "sinfuliphonerepo.com", name: "Sinful iPhone"),
    ]

    /// The entry a repository address falls under, if any. The address may
    /// lack its scheme, and "www." is ignored.
    public static func entry(for address: String) -> Entry? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "http://" + text),
              var host = url.host?.lowercased() else {
            return nil
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let path = url.path.lowercased()
        return entries.first { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else {
                return false
            }
            guard let prefix = entry.path else {
                return true
            }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }
}
