// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The warm colors of a package's page, from the Codling design handoff. In
/// Dark Mode each falls back to the system color in its place, until the
/// design has dark colors of its own.
enum PackagePalette {
    static let wallTop = color(0xE8D0BE, dark: .systemGroupedBackground)
    static let wallBottom = color(0xEAD2C1, dark: .systemGroupedBackground)
    static let card = color(0xFAEFE8, dark: .secondarySystemGroupedBackground)
    static let inset = color(0xF0E1D6, dark: .tertiarySystemGroupedBackground)
    static let separator = color(0xEADAD0, dark: .separator)
    static let mat = color(0xEDDDD2, dark: .tertiarySystemGroupedBackground)
    static let frameHighlight = color(0xF8E7DA, dark: .systemGray3)
    static let frameMetal = color(0xC4A995, dark: .systemGray2)
    static let frameShade = color(0xB98A65, dark: .systemGray)
    static let metadataCard = color(0xF8F3ED, dark: .secondarySystemGroupedBackground)
    static let versionsCard = color(0xF7F2EC, dark: .secondarySystemGroupedBackground)
    static let versionChip = color(0xE7DED2, dark: .tertiarySystemFill)
    static let metadataDivider = color(0xE8E0DA, dark: .separator)
    static let text = color(0x191715, dark: .label)
    static let muted = color(0x766B63, dark: .secondaryLabel)
    static let heading = color(0x494038, dark: .secondaryLabel)
    static let green = color(0x147A35, dark: .systemGreen)
    static let paid = color(0xFF9B00, dark: .systemOrange)

    private static func color(_ hex: UInt32, dark: UIColor) -> Color {
        let light = UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                            green: CGFloat((hex >> 8) & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// A banner in a frame: the image filling an ivory mat, inside a thin metal
/// edge with a highlight, and a soft shadow, as the design handoff draws it.
struct FramedPackageBanner: View {
    let url: URL
    var contentMode: ContentMode = .fill

    var body: some View {
        let imageShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let frameShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        imageShape
            .fill(PackagePalette.mat)
            .aspectRatio(2.7, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    RemoteImage(urls: [url], maxPixels: 1600, contentMode: contentMode) {
                        PackagePalette.mat
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipShape(imageShape)
            .padding(6)
            .background(PackagePalette.mat, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(2)
            .background(
                LinearGradient(colors: [PackagePalette.frameHighlight, PackagePalette.frameMetal,
                                        PackagePalette.frameShade, PackagePalette.frameHighlight],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: frameShape
            )
            .overlay {
                frameShape.strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: PackagePalette.frameShade.opacity(0.30), radius: 7, y: 5)
            .accessibilityHidden(true)
    }
}
