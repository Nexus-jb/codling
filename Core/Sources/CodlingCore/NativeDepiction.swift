// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A Sileo native depiction: a package page written as JSON, as documented
/// at developer.getsileo.app/native-depictions. Views Codling does not know,
/// and buttons whose action it cannot perform, are left out.
public struct NativeDepiction: Equatable {
    public var tabs: [DepictionTab]
    public var headerImage: URL?
    public var tintColor: DepictionColor?
    public var backgroundColor: DepictionColor?

    public enum ParseError: Error, Equatable {
        case notJSON
        case notADepiction
    }

    /// The deepest views may nest, and the most views one depiction may hold.
    static let depthLimit = 12
    static let viewLimit = 2000

    /// Parses a depiction; base is its address, which relative links and
    /// images are resolved against.
    public static func parse(_ data: Data, base: URL?) throws -> NativeDepiction {
        guard let root = try? JSONValue.decode(data) else {
            throw ParseError.notJSON
        }
        return try parse(root, base: base)
    }

    public static func parse(_ root: JSONValue, base: URL?) throws -> NativeDepiction {
        guard root.isObject else {
            throw ParseError.notADepiction
        }
        var parser = Parser(base: base)
        var tabs: [DepictionTab] = []
        let kind = root["class"]?.string
        if let pages = root["tabs"]?.array, kind == nil || kind == "DepictionTabView" {
            for page in pages where page.isObject {
                let name = page["tabname"]?.string ?? "Details"
                tabs.append(DepictionTab(name: name, views: parser.views(page["views"], depth: 1)))
            }
        } else if root["views"] != nil, kind == nil || kind == "DepictionStackView" || kind == "DepictionAutoStackView" {
            tabs.append(DepictionTab(name: root["tabname"]?.string ?? "Details", views: parser.views(root["views"], depth: 1)))
        } else {
            throw ParseError.notADepiction
        }
        tabs.removeAll { $0.views.isEmpty }
        guard !tabs.isEmpty else {
            throw ParseError.notADepiction
        }
        return NativeDepiction(tabs: tabs,
                               headerImage: DepictionURL.web(root["headerImage"]?.string, base: base),
                               tintColor: DepictionColor(css: root["tintColor"]?.string),
                               backgroundColor: DepictionColor(css: root["backgroundColor"]?.string))
    }

    private struct Parser {
        let base: URL?
        var count = 0

        mutating func views(_ value: JSONValue?, depth: Int) -> [DepictionView] {
            guard let items = value?.array, depth <= NativeDepiction.depthLimit else { return [] }
            var result: [DepictionView] = []
            for item in items {
                guard count < NativeDepiction.viewLimit else { break }
                if let view = view(item, depth: depth) {
                    count += 1
                    result.append(view)
                }
            }
            return result
        }

        mutating func view(_ item: JSONValue, depth: Int) -> DepictionView? {
            guard item.isObject, let kind = item["class"]?.string else { return nil }
            switch kind {
            case "DepictionStackView":
                let views = views(item["views"], depth: depth + 1)
                guard !views.isEmpty else { return nil }
                return .stack(DepictionStack(views: views, horizontal: item["orientation"]?.string?.lowercased() == "landscape",
                                             backgroundColor: DepictionColor(css: item["backgroundColor"]?.string)))
            case "DepictionAutoStackView":
                let views = views(item["views"], depth: depth + 1)
                guard !views.isEmpty else { return nil }
                let width = item["horizontalSpacing"]?.number ?? 0
                return .autoStack(views: views, itemWidth: width > 0 && width < 2000 ? width : 0)
            case "DepictionLayerView":
                let views = views(item["views"], depth: depth + 1)
                return views.isEmpty ? nil : .layer(views)
            case "DepictionHeaderView", "DepictionSubheaderView":
                guard let title = nonEmpty(item["title"]) else { return nil }
                let subheader = kind == "DepictionSubheaderView"
                return .header(DepictionHeader(title: title, subheader: subheader,
                                               bold: item["useBoldText"]?.bool ?? !subheader,
                                               alignment: DepictionAlignment(item["alignment"]),
                                               useMargins: item["useMargins"]?.bool ?? true,
                                               bottomMargin: item["useBottomMargin"]?.bool ?? subheader))
            case "DepictionLabelView":
                guard let text = nonEmpty(item["text"]) else { return nil }
                let size = item["fontSize"]?.number
                return .label(DepictionLabel(text: text, weight: DepictionFontWeight(item["fontWeight"]?.string),
                                             size: size.flatMap { $0 > 0 && $0 <= 120 ? $0 : nil },
                                             color: DepictionColor(css: item["textColor"]?.string),
                                             alignment: DepictionAlignment(item["alignment"]),
                                             margins: DepictionInsets(item["margins"]),
                                             useMargins: item["useMargins"]?.bool ?? true,
                                             usePadding: item["usePadding"]?.bool ?? true))
            case "DepictionMarkdownView":
                guard let text = nonEmpty(item["markdown"]) else { return nil }
                let html = item["useRawFormat"]?.bool ?? false
                let blocks = html ? Markup.blocks(html: text, base: base) : Markup.blocks(markdown: text, base: base)
                guard !blocks.isEmpty else { return nil }
                return .markdown(DepictionMarkdown(blocks: blocks, tint: DepictionColor(css: item["tintColor"]?.string),
                                                   useSpacing: item["useSpacing"]?.bool ?? true,
                                                   useMargins: item["useMargins"]?.bool ?? true))
            case "DepictionTableTextView":
                guard let title = nonEmpty(item["title"]), let text = item["text"]?.string else { return nil }
                return .tableText(title: title, text: text)
            case "DepictionTableButtonView", "DepictionButtonView":
                let table = kind == "DepictionTableButtonView"
                guard let action = DepictionAction.parse(item["action"]?.string, backup: item["backupAction"]?.string, base: base) else {
                    return nil
                }
                var label: DepictionView?
                if !table, let inner = item["view"] {
                    label = view(inner, depth: depth + 1)
                }
                let title = nonEmpty(table ? item["title"] : item["text"])
                guard title != nil || label != nil else { return nil }
                let button = DepictionButton(title: title ?? "", action: action,
                                             tint: DepictionColor(css: item["tintColor"]?.string), label: label)
                return table ? .tableButton(button) : .button(button)
            case "DepictionScreenshotsView":
                guard let all = screenshotSet(item) else { return nil }
                var phone: DepictionScreenshotSet?
                var pad: DepictionScreenshotSet?
                if let value = item["iphone"] {
                    phone = screenshotSet(value)
                }
                if let value = item["ipad"] {
                    pad = screenshotSet(value)
                }
                return .screenshots(DepictionScreenshots(all: all, phone: phone, pad: pad))
            case "DepictionImageView":
                return media(item).map(DepictionView.image)
            case "DepictionVideoView":
                return media(item).map(DepictionView.video)
            case "DepictionWebView":
                guard let media = media(item), DepictionMedia.isEmbeddable(media.url) else { return nil }
                return .web(media)
            case "DepictionSeparatorView":
                return .separator
            case "DepictionSpacerView":
                guard let spacing = item["spacing"]?.number, spacing > 0 else { return nil }
                return .spacer(min(spacing, 500))
            case "DepictionRatingView":
                guard let rating = item["rating"]?.number else { return nil }
                return .rating(value: min(max(rating, 0), 5), alignment: DepictionAlignment(item["alignment"]))
            case "DepictionReviewView":
                guard let title = nonEmpty(item["title"]) else { return nil }
                let text = item["markdown"]?.string ?? ""
                return .review(DepictionReview(title: title, author: item["author"]?.string ?? "",
                                               blocks: Markup.blocks(markdown: text, base: base),
                                               rating: item["rating"]?.number.map { min(max($0, 0), 5) }))
            default:
                // Including DepictionAdmobView: Codling shows no ads.
                return nil
            }
        }

        func screenshotSet(_ item: JSONValue) -> DepictionScreenshotSet? {
            guard let list = item["screenshots"]?.array else { return nil }
            let shots = list.compactMap { shot -> DepictionScreenshot? in
                guard let url = DepictionURL.web(shot["url"]?.string, base: base) else { return nil }
                return DepictionScreenshot(url: url, accessibilityText: shot["accessibilityText"]?.string ?? "",
                                           isVideo: shot["video"]?.bool ?? false)
            }
            guard !shots.isEmpty else { return nil }
            let size = DepictionSize(item["itemSize"]) ?? DepictionSize(width: 160, height: 284)
            return DepictionScreenshotSet(items: Array(shots.prefix(50)), itemSize: size,
                                          cornerRadius: max(item["itemCornerRadius"]?.number ?? 8, 0))
        }

        func media(_ item: JSONValue) -> DepictionMedia? {
            guard let url = DepictionURL.web(item["URL"]?.string, base: base) else { return nil }
            let width = item["width"]?.number ?? 0
            let height = item["height"]?.number ?? 0
            return DepictionMedia(url: url, width: width > 0 && width < 10_000 ? width : nil,
                                  height: height > 0 && height < 10_000 ? height : nil,
                                  cornerRadius: max(item["cornerRadius"]?.number ?? 0, 0),
                                  alignment: DepictionAlignment(item["alignment"]))
        }

        func nonEmpty(_ value: JSONValue?) -> String? {
            guard let text = value?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }
}

public struct DepictionTab: Equatable {
    public var name: String
    public var views: [DepictionView]
}

public indirect enum DepictionView: Equatable {
    case stack(DepictionStack)
    /// Views side by side, each itemWidth wide, wrapping onto more rows.
    case autoStack(views: [DepictionView], itemWidth: Double)
    /// Views on top of each other.
    case layer([DepictionView])
    case header(DepictionHeader)
    case label(DepictionLabel)
    case markdown(DepictionMarkdown)
    case tableText(title: String, text: String)
    case tableButton(DepictionButton)
    case button(DepictionButton)
    case screenshots(DepictionScreenshots)
    case image(DepictionMedia)
    case video(DepictionMedia)
    /// An embedded YouTube or Vimeo player.
    case web(DepictionMedia)
    case separator
    case spacer(Double)
    case rating(value: Double, alignment: DepictionAlignment)
    case review(DepictionReview)
}

public struct DepictionStack: Equatable {
    public var views: [DepictionView]
    public var horizontal: Bool
    public var backgroundColor: DepictionColor?
}

public struct DepictionHeader: Equatable {
    public var title: String
    public var subheader: Bool
    public var bold: Bool
    public var alignment: DepictionAlignment
    public var useMargins: Bool
    public var bottomMargin: Bool
}

public enum DepictionFontWeight: Equatable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    init?(_ text: String?) {
        switch text?.lowercased() {
        case "ultralight": self = .ultraLight
        case "thin": self = .thin
        case "light": self = .light
        case "regular", "normal": self = .regular
        case "medium": self = .medium
        case "semibold": self = .semibold
        case "bold": self = .bold
        case "heavy": self = .heavy
        case "black": self = .black
        default: return nil
        }
    }
}

public struct DepictionLabel: Equatable {
    public var text: String
    public var weight: DepictionFontWeight?
    public var size: Double?
    public var color: DepictionColor?
    public var alignment: DepictionAlignment
    public var margins: DepictionInsets?
    public var useMargins: Bool
    public var usePadding: Bool
}

public struct DepictionMarkdown: Equatable {
    public var blocks: [MarkupBlock]
    public var tint: DepictionColor?
    public var useSpacing: Bool
    public var useMargins: Bool
}

public struct DepictionButton: Equatable {
    public var title: String
    public var action: DepictionAction
    public var tint: DepictionColor?
    /// A view shown in place of the title.
    public var label: DepictionView?
}

public struct DepictionScreenshot: Equatable {
    public var url: URL
    public var accessibilityText: String
    public var isVideo: Bool
}

public struct DepictionScreenshotSet: Equatable {
    public var items: [DepictionScreenshot]
    public var itemSize: DepictionSize
    public var cornerRadius: Double
}

public struct DepictionScreenshots: Equatable {
    public var all: DepictionScreenshotSet
    /// Sets meant for iPhone or iPad only, used there in place of all.
    public var phone: DepictionScreenshotSet?
    public var pad: DepictionScreenshotSet?

    public func set(forPad: Bool) -> DepictionScreenshotSet {
        (forPad ? pad : phone) ?? all
    }
}

public struct DepictionMedia: Equatable {
    public var url: URL
    public var width: Double?
    public var height: Double?
    public var cornerRadius: Double
    public var alignment: DepictionAlignment

    /// As in Sileo, embedded pages come from YouTube or Vimeo only.
    public static func isEmbeddable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let allowed = ["youtube.com", "youtube-nocookie.com", "vimeo.com"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

public struct DepictionReview: Equatable {
    public var title: String
    public var author: String
    public var blocks: [MarkupBlock]
    public var rating: Double?
}
