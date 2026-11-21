// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Whether the System screen is open. It opens from a gear at the top of
/// every tab, which keeps the tab bar to five tabs.
@MainActor
final class SystemSheet: ObservableObject {
    @Published var shown = false
}

/// The gear that opens the System screen.
struct SystemButton: View {
    @EnvironmentObject private var sheet: SystemSheet

    var body: some View {
        Button {
            sheet.shown = true
        } label: {
            Label("System", systemImage: "gearshape")
        }
    }
}

extension View {
    /// Puts the System gear at the top left of a tab.
    func systemButton() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                SystemButton()
            }
        }
    }
}

// MARK: Cards

/// A rounded card on the grouped background, as the System screen and a
/// source's page lay out their parts.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(cornerRadius: 22)
    }
}

/// A heading over a card: an icon and a title.
struct CardHeading: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.title3.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A short note under a card.
struct CardFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A symbol on a tinted rounded square.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A status in its color: a symbol and a few words.
struct StatusLine: View {
    let symbol: String
    let text: String
    let color: Color
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .foregroundColor(color)
    }
}

/// A wide button on a tint of the accent color, the action of a card.
struct TintedButtonStyle: ButtonStyle {
    /// The label's color; the text color unless the action needs another,
    /// such as red for removing.
    var color: Color = Palette.text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(isEnabled ? color : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 12, inset: true)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A package's action, as a full-width glass capsule with a bold label:
/// GET, UPDATE, a price or REMOVE.
struct CapsuleButtonStyle: ButtonStyle {
    var color: Color = Palette.text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(isEnabled ? color : .secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .glassSurface(cornerRadius: 22, inset: true)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A row in a card that highlights while it is pressed.
struct CardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(.systemGray4).opacity(0.5) : Color.clear)
    }
}

/// The chevron at the end of a row that opens a page.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundColor(Color(.tertiaryLabel))
            .accessibilityHidden(true)
    }
}

// MARK: Tab bar

enum AppTab: Hashable {
    case featured, sources, queue, installed, search
}

/// The tab bar before iOS 26, drawn after iOS 26's: a floating capsule of
/// tabs on a blurred background, and Search apart as a round button.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    let queueCount: Int

    static let height: CGFloat = 64

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                item(.featured, "Featured", "star")
                item(.sources, "Sources", "tray.full")
                item(.queue, "Queue", "tray.and.arrow.down", badge: queueCount)
                item(.installed, "Installed", "shippingbox")
            }
            .padding(5)
            .frame(height: Self.height)
            .glassSurface(cornerRadius: Self.height / 2)

            Button {
                selection = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: selection == .search ? .bold : .medium))
                    .foregroundColor(Palette.text)
                    .frame(width: Self.height, height: Self.height)
                    .glassSurface(cornerRadius: Self.height / 2, inset: selection == .search)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .accessibilityAddTraits(selection == .search ? .isSelected : [])
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    private func item(_ tab: AppTab, _ title: String, _ symbol: String, badge: Int = 0) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? symbol + ".fill" : symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge.formatted())
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Color.red, in: Capsule())
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(Palette.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.clear)
                        .glassSurface(cornerRadius: 30, inset: true)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// Room at the bottom of a tab for the floating tab bar, before iOS 26,
    /// so the last rows of every page in the tab scroll above it; extra is
    /// for the queue bar above the tab bar.
    @ViewBuilder
    func floatingTabBarSpace(extra: CGFloat = 0) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background(TabBarRoom(extra: extra))
        }
    }
}

/// Gives a tab's controller extra room at the bottom, in UIKit. Room made
/// with SwiftUI around a NavigationView does not reach the pages it pushes;
/// the safe area of the tab's own controller reaches all of them.
private struct TabBarRoom: UIViewControllerRepresentable {
    let extra: CGFloat

    func makeUIViewController(context: Context) -> Probe {
        let probe = Probe()
        probe.extra = extra
        return probe
    }

    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.extra = extra
        controller.apply()
    }

    final class Probe: UIViewController {
        var extra: CGFloat = 0

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        /// The controller the tab bar controller holds for this tab.
        func apply() {
            var controller: UIViewController = self
            while let parent = controller.parent, !(parent is UITabBarController) {
                controller = parent
            }
            guard controller.parent is UITabBarController else { return }
            let room = FloatingTabBar.height + 6 + extra
            if controller.additionalSafeAreaInsets.bottom != room {
                UIView.animate(withDuration: 0.3) {
                    controller.additionalSafeAreaInsets.bottom = room
                    controller.view.layoutIfNeeded()
                }
            }
        }
    }
}

/// Rows in one card with a line between them, as a source's sections are
/// shown. The rows are made as they scroll into view, for long lists.
struct CardRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// Where the line between rows starts, past the icon.
    var dividerInset: CGFloat = 70
    @ViewBuilder let row: (Item) -> Row

    /// Past this many rows the card is drawn row by row (CardSlice), so
    /// that scrolling draws only the rows on screen; one card around
    /// hundreds of rows is drawn whole, and clipped, whenever a row appears.
    static var slicedFrom: Int { 21 }

    var body: some View {
        if items.count >= Self.slicedFrom {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    SlicedRow(first: index == 0, last: index == items.count - 1, dividerInset: dividerInset) {
                        row(item)
                    }
                }
            }
        } else {
            Card(padding: 0) {
                DividedRows(items: items, dividerInset: dividerInset, row: row)
            }
        }
    }
}

/// A row of a long card: its share of the card behind it, the line above
/// it, and rounded outer corners on the first and last rows.
private struct SlicedRow<Content: View>: View {
    let first: Bool
    let last: Bool
    let dividerInset: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if first || last {
                lined.clipShape(CornerRoundedRectangle(radius: 22, corners: CardSlice.corners(first: first, last: last)))
            } else {
                lined
            }
        }
        .background(CardSlice(first: first, last: last))
    }

    private var lined: some View {
        content()
            .overlay(alignment: .top) {
                if !first {
                    Divider()
                        .padding(.leading, dividerInset)
                }
            }
    }
}

/// One row's share of a glass card: the fill and the edge, with the outer
/// corners rounded on the first and last rows. Both run from left to right,
/// so that the rows join into one card.
struct CardSlice: View {
    let first: Bool
    let last: Bool

    var body: some View {
        CornerRoundedRectangle(radius: 22, corners: Self.corners(first: first, last: last))
            .fill(LinearGradient(colors: [Palette.surfaceTop, Palette.surfaceBottom],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(
                SliceEdge(first: first, last: last, radius: 22)
                    .stroke(LinearGradient(colors: [Palette.highlight.opacity(0.88), Palette.edge.opacity(0.85)],
                                           startPoint: .leading, endPoint: .trailing),
                            lineWidth: 1)
            )
    }

    static func corners(first: Bool, last: Bool) -> UIRectCorner {
        var corners: UIRectCorner = []
        if first { corners.formUnion([.topLeft, .topRight]) }
        if last { corners.formUnion([.bottomLeft, .bottomRight]) }
        return corners
    }
}

/// The edge of a CardSlice: both sides, and the top or the bottom with
/// their rounded corners on the first or last row.
struct SliceEdge: Shape {
    let first: Bool
    let last: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: 0.5, dy: 0)
        let top = first ? frame.minY + 0.5 : frame.minY
        let bottom = last ? frame.maxY - 0.5 : frame.maxY
        let ends = (first ? 1 : 0) + (last ? 1 : 0)
        let radius = max(0, min(self.radius, frame.width / 2, ends > 0 ? (bottom - top) / CGFloat(ends) : self.radius))
        var path = Path()
        path.move(to: CGPoint(x: frame.minX, y: last ? bottom - radius : bottom))
        if first {
            path.addLine(to: CGPoint(x: frame.minX, y: top + radius))
            path.addArc(tangent1End: CGPoint(x: frame.minX, y: top), tangent2End: CGPoint(x: frame.minX + radius, y: top),
                        radius: radius)
            path.addLine(to: CGPoint(x: frame.maxX - radius, y: top))
            path.addArc(tangent1End: CGPoint(x: frame.maxX, y: top), tangent2End: CGPoint(x: frame.maxX, y: top + radius),
                        radius: radius)
        } else {
            path.addLine(to: CGPoint(x: frame.minX, y: top))
            path.move(to: CGPoint(x: frame.maxX, y: top))
        }
        if last {
            path.addLine(to: CGPoint(x: frame.maxX, y: bottom - radius))
            path.addArc(tangent1End: CGPoint(x: frame.maxX, y: bottom), tangent2End: CGPoint(x: frame.maxX - radius, y: bottom),
                        radius: radius)
            path.addLine(to: CGPoint(x: frame.minX + radius, y: bottom))
            path.addArc(tangent1End: CGPoint(x: frame.minX, y: bottom), tangent2End: CGPoint(x: frame.minX, y: bottom - radius),
                        radius: radius)
        } else {
            path.addLine(to: CGPoint(x: frame.maxX, y: bottom))
        }
        return path
    }
}

/// Rows with a line between them, made as they scroll into view.
struct DividedRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var dividerInset: CGFloat = 70
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                    .overlay(alignment: .top) {
                        if item.id != items.first?.id {
                            Divider()
                                .padding(.leading, dividerInset)
                        }
                    }
            }
        }
    }
}

/// A package's icon when it loads; until then, or when it has none, its
/// section's symbol on its section's color.
struct PackageIcon: View {
    let urls: [URL]
    let section: String?
    var size: CGFloat = 44

    var body: some View {
        let tile = IconTile(symbol: SectionSymbol.name(for: section), color: SectionSymbol.color(for: section), size: size)
        if urls.isEmpty {
            tile
        } else {
            RemoteImage(urls: urls, maxPixels: Int(size * 3)) { tile }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: Tool cards

/// The top of a tool card, as on the System screen and the Queue: an icon,
/// a title, and what is under it (a status, a note).
struct ToolHeader<Content: View>: View {
    let symbol: String
    var color: Color = .accentColor
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What a tool does, in a card.
struct ToolNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Tool cards in a column of moderate width, centered on wide screens.
    func toolColumn() -> some View {
        frame(maxWidth: 380)
            .frame(maxWidth: .infinity)
    }
}

/// A card whose first row opens and folds the rest, as a source's sections
/// look: an icon, the title, how many it holds, and a chevron that turns
/// down when it opens.
struct CollapsibleCard<Content: View>: View {
    let title: String
    let symbol: String
    var color: Color = .accentColor
    let count: Int
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Card(padding: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 14) {
                    IconTile(symbol: symbol, color: color, size: 36)
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(count.formatted())
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(CardRowButtonStyle())
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            .accessibilityHint(expanded ? "Hides the list." : "Shows the list.")
            if expanded {
                Divider()
                    .padding(.leading, 66)
                content()
            }
        }
    }
}

/// The background of a row in a List drawn as a card: the first and last
/// rows round their outer corners as cards do. A List keeps its swipe
/// actions and selection, which a card of rows cannot.
struct CardCellBackground: View {
    let first: Bool
    let last: Bool

    var body: some View {
        CornerRoundedRectangle(radius: 22, corners: corners)
            .fill(LinearGradient(colors: [Palette.surfaceTop, Palette.surfaceBottom.opacity(0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var corners: UIRectCorner {
        var corners: UIRectCorner = []
        if first { corners.formUnion([.topLeft, .topRight]) }
        if last { corners.formUnion([.bottomLeft, .bottomRight]) }
        return corners
    }
}

/// A rectangle with some corners rounded.
struct CornerRoundedRectangle: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

// MARK: Launch

/// The first screen at launch: Codling's icon while the sources refresh,
/// so that Featured opens with what the sources have now. It can be
/// skipped; the refresh goes on.
struct LaunchView: View {
    @ObservedObject var sources: SourcesModel
    let skip: () -> Void
    @State private var canSkip = false

    var body: some View {
        let total = sources.rows.count
        let done = sources.rows.filter { $0.activity == .idle }.count
        VStack(spacing: 18) {
            Spacer()
            Image("CodlingIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("Codling")
                .font(.largeTitle.bold())
            VStack(spacing: 8) {
                if total > 0 && sources.isRefreshing {
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(maxWidth: 220)
                    Text("Refreshing sources · \(done) of \(total)")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                    Text("Reading your sources")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 50)
            Spacer()
            Button("Skip", action: skip)
                .font(.body.weight(.semibold))
                .opacity(canSkip ? 1 : 0)
                .disabled(!canSkip)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WallBackground())
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { canSkip = true }
        }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Lets the warm wall show behind a List. Before iOS 16 a List draws a
    /// table view, whose background the app clears at launch.
    @ViewBuilder
    func hiddenListBackground() -> some View {
        if #available(iOS 16, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
