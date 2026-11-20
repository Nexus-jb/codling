// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Blocks of formatted text from a depiction, in the system's fonts.
struct MarkupView: View {
    let blocks: [MarkupBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkupBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown: bold, italics, code and links.
    static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

private struct MarkupBlockView: View {
    let block: MarkupBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkupView.inline(text))
                .font(Self.font(level))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(MarkupView.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Text(MarkupView.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(depth, 6)) * 18)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(MarkupView.inline(text))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.secondarySystemBackground)))
        case .rule:
            Divider()
        case .image(let url, let alt, let link):
            MarkupImage(url: url, alt: alt, link: link)
        }
    }

    private static func font(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}

/// An image in text, at its own size or the width available, whichever is
/// smaller.
private struct MarkupImage: View {
    let url: URL
    let alt: String
    let link: URL?
    @EnvironmentObject private var router: DepictionRouter
    @State private var loaded: LoadedImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                if let link {
                    Button {
                        router.open(link, base: nil)
                    } label: {
                        picture(loaded)
                    }
                    .buttonStyle(.plain)
                } else {
                    picture(loaded)
                }
            } else if failed {
                if !alt.isEmpty {
                    Text(alt)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: 120, height: 60)
            }
        }
        .task(id: url) {
            loaded = await MediaLoader.shared.image([url], maxPixels: 2048)
            failed = loaded == nil
        }
    }

    private func picture(_ loaded: LoadedImage) -> some View {
        Image(uiImage: loaded.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: max(loaded.pixelSize.width, 1))
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }
}
