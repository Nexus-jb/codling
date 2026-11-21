// SPDX-License-Identifier: Apache-2.0

import AVKit
import SwiftUI

/// A Sileo native depiction, drawn with SwiftUI so that it follows the
/// system's text size, colors and VoiceOver.
struct NativeDepictionContent: View {
    let depiction: NativeDepiction
    @State private var tab = 0

    var body: some View {
        let index = min(tab, depiction.tabs.count - 1)
        VStack(alignment: .leading, spacing: 0) {
            if depiction.tabs.count > 1 {
                Picker("Section", selection: $tab) {
                    ForEach(depiction.tabs.indices, id: \.self) { index in
                        Text(depiction.tabs[index].name).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            if index >= 0 {
                DepictionViews(views: depiction.tabs[index].views)
            }
        }
        .environment(\.depictionTint, depiction.tintColor.map(\.color))
        .tint(depiction.tintColor.map(\.color))
    }
}

struct DepictionViews: View {
    let views: [DepictionView]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                DepictionElement(view: view)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DepictionElement: View {
    let view: DepictionView

    var body: some View {
        switch view {
        case .stack(let stack):
            Group {
                if stack.horizontal {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(stack.views.enumerated()), id: \.offset) { _, view in
                            DepictionElement(view: view)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                } else {
                    DepictionViews(views: stack.views)
                }
            }
            .background(stack.backgroundColor.map(\.color) ?? Color.clear)
        case .autoStack(let views, let itemWidth):
            if itemWidth > 0 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: itemWidth), spacing: 0, alignment: .top)], spacing: 0) {
                    ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                        DepictionElement(view: view)
                    }
                }
            } else {
                DepictionViews(views: views)
            }
        case .layer(let views):
            ZStack(alignment: .topLeading) {
                ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                    DepictionElement(view: view)
                }
            }
        case .header(let header):
            HeaderElement(header: header)
        case .label(let label):
            LabelElement(label: label)
        case .markdown(let markdown):
            MarkupView(blocks: markdown.blocks)
                .padding(.horizontal, markdown.useMargins ? 16 : 0)
                .padding(.vertical, markdown.useSpacing ? 8 : 0)
                .tint(markdown.tint.map(\.color))
        case .tableText(let title, let text):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundColor(.secondary)
                Spacer(minLength: 12)
                Text(text)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        case .tableButton(let button):
            TableButtonElement(button: button)
        case .button(let button):
            ButtonElement(button: button)
        case .screenshots(let screenshots):
            ScreenshotsElement(screenshots: screenshots)
        case .image(let media):
            MediaFrame(media: media) {
                RemoteImage(urls: [media.url], maxPixels: Self.pixels(media)) {
                    Color(.secondarySystemFill)
                }
            }
        case .video(let media):
            MediaFrame(media: media) {
                VideoTile(url: media.url)
            }
        case .web(let media):
            VideoLinkElement(url: media.watchURL)
        case .separator:
            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        case .spacer(let height):
            Color.clear
                .frame(height: height)
        case .rating(let value, let alignment):
            StarsView(rating: value)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        case .review(let review):
            ReviewElement(review: review)
        }
    }

    static func pixels(_ media: DepictionMedia) -> Int {
        Int(max(media.width ?? 600, media.height ?? 600) * 3)
    }
}

private struct HeaderElement: View {
    let header: DepictionHeader

    var body: some View {
        Text(header.title)
            .font(header.subheader ? .callout : .title3)
            .fontWeight(header.bold ? .bold : .regular)
            .foregroundColor(header.subheader ? .secondary : .primary)
            .multilineTextAlignment(header.alignment.text)
            .frame(maxWidth: .infinity, alignment: header.alignment.frame)
            .padding(.horizontal, header.useMargins ? 16 : 0)
            .padding(.top, header.subheader ? 4 : 14)
            .padding(.bottom, header.bottomMargin ? 8 : 2)
            .accessibilityAddTraits(header.subheader ? [] : .isHeader)
    }
}

private struct LabelElement: View {
    let label: DepictionLabel
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        Text(label.text)
            .font(.system(size: scaledSize, weight: weight)) // fixed: scaled with the text size below
            .foregroundColor(label.color.map(\.color) ?? .primary)
            .multilineTextAlignment(label.alignment.text)
            .frame(maxWidth: .infinity, alignment: label.alignment.frame)
            .padding(insets)
    }

    /// The label's size, scaled with the reader's text size.
    private var scaledSize: CGFloat {
        _ = sizeCategory
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(label.size ?? 17))
    }

    private var insets: EdgeInsets {
        if let margins = label.margins {
            return EdgeInsets(top: margins.top, leading: margins.left, bottom: margins.bottom, trailing: margins.right)
        }
        let horizontal: CGFloat = label.useMargins ? 16 : 0
        let vertical: CGFloat = label.usePadding ? 6 : 0
        return EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    private var weight: Font.Weight {
        switch label.weight {
        case .ultraLight?: return .ultraLight
        case .thin?: return .thin
        case .light?: return .light
        case .medium?: return .medium
        case .semibold?: return .semibold
        case .bold?: return .bold
        case .heavy?: return .heavy
        case .black?: return .black
        case .regular?, nil: return .regular
        }
    }
}

private struct TableButtonElement: View {
    let button: DepictionButton
    @EnvironmentObject private var router: DepictionRouter
    @Environment(\.depictionTint) private var tint

    var body: some View {
        Button {
            router.perform(button.action, title: button.title)
        } label: {
            HStack {
                Text(button.title)
                    .foregroundColor(button.tint.map(\.color) ?? tint ?? .accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ButtonElement: View {
    let button: DepictionButton
    @EnvironmentObject private var router: DepictionRouter
    @Environment(\.depictionTint) private var tint

    var body: some View {
        Button {
            router.perform(button.action, title: button.title)
        } label: {
            if let label = button.label {
                DepictionElement(view: label)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            } else {
                Text(button.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(button.tint.map(\.color) ?? tint ?? .accentColor))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Media of a fixed size, scaled down to fit the width, with rounded corners.
private struct MediaFrame<Content: View>: View {
    let media: DepictionMedia
    @ViewBuilder var content: () -> Content

    var body: some View {
        let width = media.width ?? 320
        let height = media.height ?? width * 9 / 16
        Color.clear
            .aspectRatio(width / height, contentMode: .fit)
            .frame(maxWidth: width)
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: media.cornerRadius, style: .continuous))
            .frame(maxWidth: .infinity, alignment: media.alignment.frame)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/// A video that plays when the reader asks: never on its own.
private struct VideoTile: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil {
                    player = AVPlayer(url: url)
                }
            }
            .onDisappear {
                player?.pause()
            }
    }
}

private struct ScreenshotsElement: View {
    let screenshots: DepictionScreenshots
    @State private var gallery: GalleryStart?

    struct GalleryStart: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        let set = screenshots.set(forPad: UIDevice.current.userInterfaceIdiom == .pad)
        let size = fitted(set.itemSize)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(set.items.indices, id: \.self) { index in
                    let item = set.items[index]
                    Group {
                        if item.isVideo {
                            VideoTile(url: item.url)
                        } else {
                            Button {
                                gallery = GalleryStart(index: index)
                            } label: {
                                RemoteImage(urls: [item.url], maxPixels: Int(max(size.width, size.height) * 3)) {
                                    Color(.secondarySystemFill)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: set.cornerRadius, style: .continuous))
                    .accessibilityLabel(item.accessibilityText.isEmpty ? "Screenshot \(index + 1)" : item.accessibilityText)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .fullScreenCover(item: $gallery) { start in
            ScreenshotGallery(items: set.items.filter { !$0.isVideo }, start: start.index, all: set.items)
        }
    }

    /// The item size, scaled down when it is wider than the screen.
    private func fitted(_ size: DepictionSize) -> CGSize {
        let available = UIScreen.main.bounds.width - 48
        let scale = min(1, available / size.width)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private struct ScreenshotGallery: View {
    let items: [DepictionScreenshot]
    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(items: [DepictionScreenshot], start: Int, all: [DepictionScreenshot]) {
        self.items = items
        // The tapped screenshot, counted among the images only.
        let url = all.indices.contains(start) ? all[start].url : nil
        _selection = State(initialValue: items.firstIndex { $0.url == url } ?? 0)
    }

    var body: some View {
        NavigationView {
            TabView(selection: $selection) {
                ForEach(items.indices, id: \.self) { index in
                    RemoteImage(urls: [items[index].url], maxPixels: 2400, contentMode: .fit) {
                        ProgressView()
                    }
                    .accessibilityLabel(items[index].accessibilityText.isEmpty ? "Screenshot \(index + 1)" : items[index].accessibilityText)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// A YouTube or Vimeo video, opened in the browser sheet: a player inside
/// Codling would need a web view, which does not run there.
private struct VideoLinkElement: View {
    let url: URL
    @EnvironmentObject private var router: DepictionRouter
    @Environment(\.depictionTint) private var tint

    var body: some View {
        Button {
            router.perform(.web(url))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundColor(tint ?? .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch Video")
                        .font(.body.weight(.semibold))
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct ReviewElement: View {
    let review: DepictionReview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(review.title)
                .font(.headline)
            HStack(spacing: 8) {
                if let rating = review.rating {
                    StarsView(rating: rating)
                        .font(.caption)
                }
                if !review.author.isEmpty {
                    Text(review.author)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            MarkupView(blocks: review.blocks)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
