// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A source's featured banners: the sileo-featured.json file at the top of
/// a repository, as documented at developer.getsileo.app/sileo-featured.
public struct FeaturedBanners: Equatable {
    public struct Banner: Equatable {
        public var image: URL
        public var title: String
        /// The identifier of the package the banner features.
        public var package: String?
        public var hideShadow: Bool
    }

    public var itemSize: DepictionSize
    public var cornerRadius: Double
    public var banners: [Banner]

    /// The most banners shown for one source.
    static let limit = 30

    /// Parses the file; base is its address. Nil when it holds no banner
    /// with an image.
    public static func parse(_ data: Data, base: URL?) -> FeaturedBanners? {
        guard let root = try? JSONValue.decode(data), root.isObject, let list = root["banners"]?.array else {
            return nil
        }
        let banners = list.compactMap { item -> Banner? in
            guard let image = DepictionURL.web(item["url"]?.string, base: base) else { return nil }
            let package = item["package"]?.string?.trimmingCharacters(in: .whitespaces)
            return Banner(image: image, title: item["title"]?.string ?? "",
                          package: package.flatMap { DepictionAction.isPackageName($0) ? $0 : nil },
                          hideShadow: item["hideShadow"]?.bool ?? false)
        }
        guard !banners.isEmpty else { return nil }
        let size = DepictionSize(root["itemSize"]) ?? DepictionSize(width: 263, height: 148)
        return FeaturedBanners(itemSize: size, cornerRadius: max(root["itemCornerRadius"]?.number ?? 10, 0),
                               banners: Array(banners.prefix(limit)))
    }
}
