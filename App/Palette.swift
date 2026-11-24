// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Codling's sky glass colors, from the design handoff, in Light and Dark
/// Mode: a plain canvas, cards of glass in a blue gradient with a bright
/// edge, and text in one color.
enum Palette {
    static let canvas = color(light: 0xFFFFFF, dark: 0x080D18)
    static let text = color(light: 0x000000, dark: 0xF3F8FF)
    static let surfaceTop = color(light: 0xE8F5FF, dark: 0x142D47)
    static let surfaceBottom = color(light: 0xC6E5FF, dark: 0x10223A)
    static let insetTop = color(light: 0xE1F2FF, dark: 0x1B4160)
    static let insetBottom = color(light: 0xAED8FA, dark: 0x15304D)
    static let highlight = color(light: 0xFFFFFF, dark: 0x7FC6FA)
    static let edge = color(light: 0x91C9F4, dark: 0x3D82B7)
    static let divider = color(light: 0x8CB9DE, dark: 0x36658A)
    static let shadow = color(light: 0x3A89C3, dark: 0x00040C)
    /// Green for what fits this device.
    static let green = color(light: 0x147A35, dark: 0x4CD46F)

    /// A flat fill for places a gradient cannot go, such as List rows.
    static let card = surfaceTop
    static let inset = insetTop
    /// Secondary text, which the design draws in the text color.
    static let muted = text
    static let heading = text

    static let uiInsetBottom = uiColor(light: 0xAED8FA, dark: 0x15304D)
    static let uiText = uiColor(light: 0x000000, dark: 0xF3F8FF)
    static let uiCanvas = uiColor(light: 0xFFFFFF, dark: 0x080D18)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor(light: light, dark: dark))
    }

    private static func uiColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    /// Controls UIKit draws itself, such as segmented pickers, take the
    /// glass colors too.
    static func applyToUIKit() {
        let segments = UISegmentedControl.appearance()
        segments.selectedSegmentTintColor = uiInsetBottom
        segments.setTitleTextAttributes([.foregroundColor: uiText], for: .normal)
        segments.setTitleTextAttributes([.foregroundColor: uiText], for: .selected)
    }
}

/// A surface of glass: a blue gradient from the top left, a thin bright
/// edge, and a soft shadow. Inset surfaces, such as buttons and chips, are
/// a step deeper.
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let inset: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The shadow is the shape's alone: a shadow on the whole view would
        // draw everything in the card again, off screen, whenever anything
        // in it changes, such as an icon that loads while scrolling.
        content
            .background(
                shape.fill(LinearGradient(colors: inset ? [Palette.insetTop, Palette.insetBottom]
                                                        : [Palette.surfaceTop, Palette.surfaceBottom],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Palette.shadow.opacity(inset ? 0.13 : 0.24), radius: inset ? 3 : 7, y: inset ? 2 : 4)
            )
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Palette.highlight.opacity(0.88), Palette.edge.opacity(0.85)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// A card, button or bar of glass.
    func glassSurface(cornerRadius: CGFloat = 22, inset: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, inset: inset))
    }
}

/// The canvas behind every screen.
struct WallBackground: View {
    var body: some View {
        Palette.canvas
            .ignoresSafeArea()
    }
}

/// A banner in a glass frame: the image filling a 2.7:1 window with
/// rounded corners, on a lighter mat, inside an inset glass edge.
struct FramedPackageBanner: View {
    let url: URL
    var contentMode: ContentMode = .fill

    var body: some View {
        let imageShape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        imageShape
            .fill(Palette.insetTop)
            .aspectRatio(2.7, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    RemoteImage(urls: [url], maxPixels: 1600, contentMode: contentMode) {
                        Palette.insetTop
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipShape(imageShape)
            .padding(6)
            .background(Palette.surfaceTop, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(2)
            .glassSurface(cornerRadius: 16, inset: true)
            .overlay(NeonEdge(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

/// A band of rainbow light that runs around a rounded edge, as on a neon
/// sign, with a soft glow inside the edge. It stands still with Reduce
/// Motion, and stops drawing while off screen.
struct NeonEdge: View {
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 2
    /// Seconds for one turn around the edge.
    var period: Double = 3.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !onScreen)) { context in
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let turn = reduceMotion ? 0.1
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // The angle grows clockwise, so the band runs clockwise with
            // its orange head in front and its blue tail fading behind.
            let light = AngularGradient(gradient: Self.light, center: .center, angle: .degrees(turn * 360))
            ZStack {
                shape.strokeBorder(light, lineWidth: lineWidth * 4)
                    .blur(radius: lineWidth * 3)
                    .opacity(0.7)
                shape.strokeBorder(light, lineWidth: lineWidth)
            }
            .clipShape(shape)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private static let light = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.58),
        .init(color: Color(red: 0.25, green: 0.42, blue: 1), location: 0.68),
        .init(color: Color(red: 0.2, green: 0.82, blue: 1), location: 0.76),
        .init(color: Color(red: 0.32, green: 0.93, blue: 0.45), location: 0.84),
        .init(color: Color(red: 1, green: 0.84, blue: 0.24), location: 0.91),
        .init(color: Color(red: 1, green: 0.48, blue: 0.2), location: 0.97),
        .init(color: .clear, location: 1),
    ])
}
