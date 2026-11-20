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

/// A section header that folds its section away: the title, how many rows
/// the section holds, and an arrow that turns when it opens.
struct CollapsibleHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.toggle()
            }
        } label: {
            HStack {
                Text("\(title) · \(count.formatted())")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(expanded ? "Shown" : "Hidden")
        .accessibilityHint(expanded ? "Hides the list." : "Shows the list.")
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
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body.weight(.semibold))
        .foregroundColor(color)
    }
}

/// A wide button on a tint of the accent color, the action of a card.
struct TintedButtonStyle: ButtonStyle {
    var color: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(isEnabled ? color : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)

            Button {
                selection = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selection == .search ? .accentColor : .primary)
                    .frame(width: Self.height, height: Self.height)
                    .background(selection == .search ? Color.accentColor.opacity(0.15) : Color.clear, in: Circle())
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
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
            .foregroundColor(selected ? .accentColor : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// Room at the bottom of a tab for the floating tab bar, before iOS 26,
    /// so the last rows of every page in the tab scroll above it.
    @ViewBuilder
    func floatingTabBarSpace() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background(TabBarRoom())
        }
    }
}

/// Gives a tab's controller extra room at the bottom, in UIKit. Room made
/// with SwiftUI around a NavigationView does not reach the pages it pushes;
/// the safe area of the tab's own controller reaches all of them.
private struct TabBarRoom: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe {
        Probe()
    }

    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.apply()
    }

    final class Probe: UIViewController {
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
            let room = FloatingTabBar.height + 6
            if controller.additionalSafeAreaInsets.bottom != room {
                controller.additionalSafeAreaInsets.bottom = room
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

    var body: some View {
        Card(padding: 0) {
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
