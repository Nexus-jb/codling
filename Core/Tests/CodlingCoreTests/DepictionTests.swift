// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class DebianVersionTests: XCTestCase {
    func testOrdering() {
        func less(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertLessThan(DebianVersion(a), DebianVersion(b), file: file, line: line)
            XCTAssertGreaterThan(DebianVersion(b), DebianVersion(a), file: file, line: line)
        }
        less("1.0", "1.0.1")
        less("1.0~beta", "1.0")
        less("1.0~beta1", "1.0~beta2")
        less("1.9", "1.10")
        less("1.0", "1.0a")
        less("1.0a", "1.0+")
        less("1.0-1", "1.0-2")
        less("2.0", "1:0.9")
        less("0.9.9-1", "0.10")
        XCTAssertEqual(DebianVersion("1.0"), DebianVersion("1.00"))
        XCTAssertEqual(DebianVersion("0:1.2.3"), DebianVersion("1.2.3"))
        XCTAssertEqual(DebianVersion("1:2.0-3").epoch, 1)
        XCTAssertEqual(DebianVersion("1:2.0-3").upstream, "2.0")
        XCTAssertEqual(DebianVersion("1:2.0-3").revision, "3")
    }
}

final class DepictionValueTests: XCTestCase {
    func testColors() {
        XCTAssertEqual(DepictionColor(css: "#fff"), DepictionColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(DepictionColor(css: " #FF0000 "), DepictionColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(DepictionColor(css: "#00ff0080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(DepictionColor(css: "rgb(255, 0, 0)"), DepictionColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(DepictionColor(css: "rgba(0,0,255,0.5)"), DepictionColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        XCTAssertEqual(DepictionColor(css: "White"), DepictionColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(DepictionColor(css: "123456")?.blue ?? 0, Double(0x56) / 255, accuracy: 0.0001)
        XCTAssertNil(DepictionColor(css: "#12345"))
        XCTAssertNil(DepictionColor(css: "nope"))
        XCTAssertNil(DepictionColor(css: nil))
    }

    func testSizesAndInsets() {
        XCTAssertEqual(DepictionSize(.string("{263, 148}")), DepictionSize(width: 263, height: 148))
        XCTAssertEqual(DepictionSize(.object(["x": .number(10), "y": .string("20")])), DepictionSize(width: 10, height: 20))
        XCTAssertEqual(DepictionSize(.array([.number(3), .number(4)])), DepictionSize(width: 3, height: 4))
        XCTAssertNil(DepictionSize(.string("{0, 10}")))
        XCTAssertNil(DepictionSize(.string("big")))
        XCTAssertEqual(DepictionInsets(.string("{1, 2, 3, 4}")), DepictionInsets(top: 1, left: 2, bottom: 3, right: 4))
        XCTAssertEqual(DepictionAlignment(.number(1)), .center)
        XCTAssertEqual(DepictionAlignment(.string("2")), .trailing)
        XCTAssertEqual(DepictionAlignment(nil), .leading)
    }

    func testActions() {
        let base = URL(string: "https://repo.example/pkg/depiction.json")
        XCTAssertEqual(DepictionAction.parse("https://example.com/a", base: base), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(DepictionAction.parse("page.html", base: base), .web(URL(string: "https://repo.example/pkg/page.html")!))
        XCTAssertEqual(DepictionAction.parse("depiction-https://repo.example/d.json", base: base),
                       .depiction(URL(string: "https://repo.example/d.json")!))
        XCTAssertEqual(DepictionAction.parse("depiction-/changes.json", base: base),
                       .depiction(URL(string: "https://repo.example/changes.json")!))
        XCTAssertEqual(DepictionAction.parse("sileo://package/com.example.tweak", base: base), .package("com.example.tweak"))
        XCTAssertEqual(DepictionAction.parse("cydia://package/com.example.tweak?ref=x", base: base), .package("com.example.tweak"))
        XCTAssertEqual(DepictionAction.parse("zbra://packages/com.example.tweak", base: base), .package("com.example.tweak"))
        XCTAssertEqual(DepictionAction.parse("cydia://url/https://example.com/x", base: base), .web(URL(string: "https://example.com/x")!))
        XCTAssertEqual(DepictionAction.parse("mailto:dev@example.com", base: base), .system(URL(string: "mailto:dev@example.com")!))
        XCTAssertNil(DepictionAction.parse("form-https://repo.example/support", base: base))
        XCTAssertNil(DepictionAction.parse("javascript:alert(1)", base: base))
        XCTAssertNil(DepictionAction.parse("sileo://source/https://repo.example", base: base))
        XCTAssertNil(DepictionAction.parse("sileo://package/bad id", base: base))
        XCTAssertNil(DepictionAction.parse("   ", base: base))
        XCTAssertEqual(DepictionAction.parse("form-x", backup: "https://b.example", base: base), .web(URL(string: "https://b.example")!))
        XCTAssertTrue(DepictionAction.isPackageName("com.example.tweak+fix"))
        XCTAssertFalse(DepictionAction.isPackageName("-x"))
        XCTAssertFalse(DepictionAction.isPackageName("a b"))
    }

    func testURLs() {
        let base = URL(string: "https://repo.example/pkg/")
        XCTAssertEqual(DepictionURL.web("shots/a b.png", base: base), URL(string: "https://repo.example/pkg/shots/a%20b.png"))
        XCTAssertEqual(DepictionURL.web("//cdn.example/x.png", base: base), URL(string: "https://cdn.example/x.png"))
        XCTAssertNil(DepictionURL.web("file:///etc/passwd", base: base))
        XCTAssertNil(DepictionURL.web("relative.png", base: nil))
    }
}

final class MarkupTests: XCTestCase {
    let base = URL(string: "https://repo.example/pkg/index.html")

    func testMarkdownBlocks() {
        let markdown = """
            # Title
            Some **bold** text
            on two lines.

            - one
            - two
              - nested
            1. first

            > quoted
            ---
            ![Shot](img/shot.png)

            Subtitle
            ========
            ```
            let x = 1
            ```
            """
        XCTAssertEqual(Markup.blocks(markdown: markdown, base: base), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\non two lines."),
            .listItem(marker: "•", depth: 0, text: "one"),
            .listItem(marker: "•", depth: 0, text: "two"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .listItem(marker: "1.", depth: 0, text: "first"),
            .quote("quoted"),
            .rule,
            .image(URL(string: "https://repo.example/pkg/img/shot.png")!, alt: "Shot", link: nil),
            .heading(level: 1, text: "Subtitle"),
            .code("let x = 1"),
        ])
    }

    func testImagesInText() {
        XCTAssertEqual(Markup.blocks(markdown: "Before ![a](https://x.example/a.png) after", base: base), [
            .paragraph("Before"),
            .image(URL(string: "https://x.example/a.png")!, alt: "a", link: nil),
            .paragraph("after"),
        ])
        XCTAssertEqual(Markup.blocks(markdown: "[![Badge](https://img.example/b.png)](https://example.com)", base: base), [
            .image(URL(string: "https://img.example/b.png")!, alt: "Badge", link: URL(string: "https://example.com")!),
        ])
    }

    func testMarkdownWithHTML() {
        let markdown = "Line one<br>Line <b>two</b>\n\n<p align=\"center\">Centered</p>\n<https://example.com> and 3 < 4"
        XCTAssertEqual(Markup.blocks(markdown: markdown, base: base), [
            .paragraph("Line one\nLine **two**"),
            .paragraph("Centered"),
            .paragraph("<https://example.com> and 3 < 4"),
        ])
    }

    func testHTML() {
        let html = """
            <h2>Features</h2><p>Hello <b>world</b> &amp; <a href="/more">more</a>.</p>
            <ul><li>One</li><li>Two <i>it</i></li></ul>
            <p><img src="shot.png" alt="Shot"><img src="pixel.gif" width="1" height="1"></p>
            <script>alert("<b>no</b>")</script><style>p { color: red }</style>
            <p>5. not a list</p>
            """
        XCTAssertEqual(Markup.blocks(html: html, base: base), [
            .heading(level: 2, text: "Features"),
            .paragraph("Hello **world** \\& [more](https://repo.example/more)."),
            .listItem(marker: "•", depth: 0, text: "One"),
            .listItem(marker: "•", depth: 0, text: "Two *it*"),
            .image(URL(string: "https://repo.example/pkg/shot.png")!, alt: "Shot", link: nil),
            .paragraph("5\\. not a list"),
        ])
    }

    func testHTMLLinkedImagesNestedListsAndCode() {
        let html = "<a href=\"https://example.com\"><img src=\"https://img.example/b.png\"></a>"
            + "<ol><li>A<ul><li>B</li></ul></li><li>C</li></ol><pre>let  x = 1\n  y</pre>"
            + "<p><b> spaced </b>end</p><iframe src=\"x\" /><p>after</p>"
        XCTAssertEqual(Markup.blocks(html: html, base: base), [
            .image(URL(string: "https://img.example/b.png")!, alt: "", link: URL(string: "https://example.com")!),
            .listItem(marker: "1.", depth: 0, text: "A"),
            .listItem(marker: "•", depth: 1, text: "B"),
            .listItem(marker: "2.", depth: 0, text: "C"),
            .code("let  x = 1\n  y"),
            .paragraph("**spaced** end"),
            .paragraph("after"),
        ])
    }

    func testEntities() {
        XCTAssertEqual(Entities.decode("&lt;a&gt; &#65;&#x42; &copy; &unknown; &"), "<a> AB © &unknown; &")
    }
}

final class NativeDepictionTests: XCTestCase {
    let base = URL(string: "https://repo.example/pkg/depiction.json")

    func testTabsAndViews() throws {
        let json = """
            {
              "class": "DepictionTabView",
              "minVersion": "0.1",
              "headerImage": "https://repo.example/header.png",
              "tintColor": "#ff6600",
              "tabs": [
                {
                  "tabname": "Details",
                  "class": "DepictionStackView",
                  "views": [
                    {"class": "DepictionHeaderView", "title": "What's new", "useBottomMargin": true},
                    {"class": "DepictionMarkdownView", "markdown": "Fixes **crashes**."},
                    {"class": "DepictionScreenshotsView", "itemSize": "{160, 284}", "itemCornerRadius": "8",
                     "screenshots": [{"url": "shots/1.png", "accessibilityText": "Home"}, {"url": "", "accessibilityText": "Bad"}],
                     "ipad": {"itemSize": "{320, 240}", "itemCornerRadius": 6,
                              "screenshots": [{"url": "https://repo.example/ipad.png", "accessibilityText": "iPad"}]}},
                    {"class": "DepictionTableTextView", "title": "Version", "text": "1.2"},
                    {"class": "DepictionTableButtonView", "title": "Support", "action": "form-https://repo.example/support"},
                    {"class": "DepictionTableButtonView", "title": "Changelog", "action": "depiction-changelog.json"},
                    {"class": "DepictionAdmobView", "adUnitID": "x"},
                    {"class": "DepictionSpacerView", "spacing": 8},
                    {"class": "DepictionSeparatorView"},
                    {"class": "DepictionButtonView", "text": "Twitter", "action": "https://twitter.com/x", "tintColor": "#1da1f2"},
                    {"class": "DepictionImageView", "URL": "https://repo.example/banner.png", "width": 300, "height": 100,
                     "cornerRadius": 10, "alignment": 1},
                    {"class": "DepictionWebView", "URL": "https://evil.example/frame", "width": 300, "height": 200},
                    {"class": "DepictionWebView", "URL": "https://www.youtube.com/embed/abc", "width": 300, "height": 200},
                    {"class": "DepictionRatingView", "rating": 7, "alignment": 2}
                  ]
                },
                {"tabname": "Empty", "class": "DepictionStackView", "views": []}
              ]
            }
            """
        let depiction = try NativeDepiction.parse(Data(json.utf8), base: base)
        XCTAssertEqual(depiction.headerImage, URL(string: "https://repo.example/header.png"))
        XCTAssertEqual(depiction.tintColor, DepictionColor(red: 1, green: 0.4, blue: 0))
        XCTAssertEqual(depiction.tabs.map(\.name), ["Details"])
        let views = depiction.tabs[0].views
        XCTAssertEqual(views.count, 11)
        XCTAssertEqual(views[0], .header(DepictionHeader(title: "What's new", subheader: false, bold: true, alignment: .leading,
                                                         useMargins: true, bottomMargin: true)))
        XCTAssertEqual(views[1], .markdown(DepictionMarkdown(blocks: [.paragraph("Fixes **crashes**.")], tint: nil,
                                                             useSpacing: true, useMargins: true)))
        guard case .screenshots(let screenshots) = views[2] else {
            return XCTFail("expected screenshots, got \(views[2])")
        }
        XCTAssertEqual(screenshots.all.items, [DepictionScreenshot(url: URL(string: "https://repo.example/pkg/shots/1.png")!,
                                                                   accessibilityText: "Home", isVideo: false)])
        XCTAssertEqual(screenshots.all.itemSize, DepictionSize(width: 160, height: 284))
        XCTAssertEqual(screenshots.all.cornerRadius, 8)
        XCTAssertEqual(screenshots.set(forPad: true).itemSize, DepictionSize(width: 320, height: 240))
        XCTAssertEqual(screenshots.set(forPad: false), screenshots.all)
        XCTAssertEqual(views[3], .tableText(title: "Version", text: "1.2"))
        XCTAssertEqual(views[4], .tableButton(DepictionButton(title: "Changelog",
                                                              action: .depiction(URL(string: "https://repo.example/pkg/changelog.json")!),
                                                              tint: nil, label: nil)))
        XCTAssertEqual(views[5], .spacer(8))
        XCTAssertEqual(views[6], .separator)
        XCTAssertEqual(views[7], .button(DepictionButton(title: "Twitter", action: .web(URL(string: "https://twitter.com/x")!),
                                                         tint: DepictionColor(css: "#1da1f2"), label: nil)))
        XCTAssertEqual(views[8], .image(DepictionMedia(url: URL(string: "https://repo.example/banner.png")!, width: 300,
                                                       height: 100, cornerRadius: 10, alignment: .center)))
        guard case .web(let embed) = views[9] else {
            return XCTFail("expected an embedded player, got \(views[9])")
        }
        XCTAssertEqual(embed.url.host, "www.youtube.com")
        XCTAssertEqual(views[10], .rating(value: 5, alignment: .trailing))
    }

    func testStackRootAndLabel() throws {
        let json = """
            {"class": "DepictionStackView", "views": [
              {"class": "DepictionLabelView", "text": "Hi", "fontWeight": "bold", "fontSize": "14", "margins": "{1, 2, 3, 4}"},
              {"class": "DepictionStackView", "orientation": "landscape", "views": [{"class": "DepictionSeparatorView"}]},
              {"class": "DepictionButtonView", "action": "https://example.com",
               "view": {"class": "DepictionImageView", "URL": "https://example.com/i.png", "width": 20, "height": 20, "cornerRadius": 0}}
            ]}
            """
        let depiction = try NativeDepiction.parse(Data(json.utf8), base: base)
        XCTAssertEqual(depiction.tabs.count, 1)
        XCTAssertEqual(depiction.tabs[0].views[0], .label(DepictionLabel(text: "Hi", weight: .bold, size: 14, color: nil,
                                                                         alignment: .leading,
                                                                         margins: DepictionInsets(top: 1, left: 2, bottom: 3, right: 4),
                                                                         useMargins: true, usePadding: true)))
        XCTAssertEqual(depiction.tabs[0].views[1], .stack(DepictionStack(views: [.separator], horizontal: true, backgroundColor: nil)))
        guard case .button(let button) = depiction.tabs[0].views[2], case .image? = button.label else {
            return XCTFail("expected a button with an image")
        }
        XCTAssertEqual(button.title, "")
    }

    func testRejectsWhatIsNotADepiction() {
        XCTAssertThrowsError(try NativeDepiction.parse(Data("not json".utf8), base: base)) {
            XCTAssertEqual($0 as? NativeDepiction.ParseError, .notJSON)
        }
        XCTAssertThrowsError(try NativeDepiction.parse(Data("[]".utf8), base: base)) {
            XCTAssertEqual($0 as? NativeDepiction.ParseError, .notADepiction)
        }
        XCTAssertThrowsError(try NativeDepiction.parse(Data(#"{"class": "DepictionTabView", "tabs": []}"#.utf8), base: base))
        // Views nested deeper than the limit are left out, without overflowing.
        var view = #"{"class": "DepictionSeparatorView"}"#
        for _ in 0..<40 {
            view = #"{"class": "DepictionStackView", "views": ["# + view + "]}"
        }
        XCTAssertThrowsError(try NativeDepiction.parse(Data(view.utf8), base: base))
    }
}

final class FeaturedBannersTests: XCTestCase {
    func testParse() throws {
        let json = """
            {"class": "FeaturedBannersView", "itemSize": "{263, 148}", "itemCornerRadius": 10, "banners": [
              {"url": "https://repo.example/b1.png", "title": "One", "package": "com.example.one", "hideShadow": false},
              {"url": "banners/b2.png", "title": "Two", "package": "bad id!"},
              {"title": "No image"}
            ]}
            """
        let featured = try XCTUnwrap(FeaturedBanners.parse(Data(json.utf8), base: URL(string: "https://repo.example/sileo-featured.json")))
        XCTAssertEqual(featured.itemSize, DepictionSize(width: 263, height: 148))
        XCTAssertEqual(featured.cornerRadius, 10)
        XCTAssertEqual(featured.banners, [
            .init(image: URL(string: "https://repo.example/b1.png")!, title: "One", package: "com.example.one", hideShadow: false),
            .init(image: URL(string: "https://repo.example/banners/b2.png")!, title: "Two", package: nil, hideShadow: false),
        ])
        XCTAssertNil(FeaturedBanners.parse(Data(#"{"banners": []}"#.utf8), base: nil))
        XCTAssertNil(FeaturedBanners.parse(Data("<html>".utf8), base: nil))
    }
}

final class PackageCatalogTests: XCTestCase {
    func testNewestAndSections() {
        let rows = [
            PackageSummary(source: "src1", package: "a", version: "1.0", name: "Alpha", section: "Tweaks"),
            PackageSummary(source: "src1", package: "a", version: "1.2", name: "Alpha", section: "Tweaks"),
            PackageSummary(source: "src2", package: "a", version: "0.9", name: "Alpha", section: "Themes_(SnowBoard)"),
            PackageSummary(source: "src1", package: "b", version: "2.0~beta", name: "beta"),
            PackageSummary(source: "src1", package: "b", version: "2.0", name: "beta"),
        ]
        let newest = PackageCatalog.newest(rows)
        XCTAssertEqual(newest.map { "\($0.source) \($0.package) \($0.version)" }, ["src1 a 1.2", "src2 a 0.9", "src1 b 2.0"])
        let sections = PackageCatalog.sections(newest)
        XCTAssertEqual(sections.map(\.name), ["Other", "Themes (SnowBoard)", "Tweaks"])
        XCTAssertEqual(sections.map(\.count), [1, 1, 1])
    }

    func testRankAndPatterns() {
        let packages = [
            PackageSummary(source: "s", package: "com.example.x", version: "1", name: "Let It Snow"),
            PackageSummary(source: "s", package: "com.snow.y", version: "1", name: "Y"),
            PackageSummary(source: "s", package: "com.example.board", version: "1", name: "Snowboard"),
            PackageSummary(source: "s", package: "snow", version: "1"),
            PackageSummary(source: "s", package: "com.example.z", version: "1", name: "Z", author: "Snowy <s@example.com>"),
        ]
        XCTAssertEqual(PackageCatalog.rank(packages, query: "Snow").map(\.displayName), ["snow", "Snowboard", "Let It Snow", "Y", "Z"])
        XCTAssertEqual(PackageCatalog.likePattern("50%_off\\"), "%50\\%\\_off\\\\%")
        XCTAssertEqual(PackageCatalog.searchWords("  Snow  Board "), ["snow", "board"])
    }

    func testFields() {
        let paid = PackageSummary(source: "s", package: "p", version: "1", maintainer: "Jane Doe <jane@example.com>",
                                  tag: "purpose::extension, cydia::commercial")
        XCTAssertTrue(paid.isPaid)
        XCTAssertEqual(paid.displayAuthor, "Jane Doe")
        XCTAssertFalse(PackageSummary(source: "s", package: "p", version: "1", tag: "purpose::extension").isPaid)
        var record = PackageRecord()
        record.description = "Summary\nLine one\n.\nLine two"
        XCTAssertEqual(record.details, "Line one\n\nLine two")
        XCTAssertEqual(Person.name("Jane Doe <jane@example.com>"), "Jane Doe")
        XCTAssertEqual(Person.name("<jane@example.com>"), "<jane@example.com>")
    }
}
