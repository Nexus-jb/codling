// SPDX-License-Identifier: Apache-2.0

import SafariServices
import SwiftUI

/// Performs what depiction buttons and links ask for: web pages open in a
/// browser sheet, linked depictions and packages open as new pages, and mail
/// or telephone links go to the system.
@MainActor
final class DepictionRouter: ObservableObject {
    struct WebPage: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    struct LinkedDepiction {
        let url: URL
        let title: String
    }

    @Published var package: String?
    @Published var depiction: LinkedDepiction?
    @Published var webPage: WebPage?

    func perform(_ action: DepictionAction, title: String = "") {
        switch action {
        case .web(let url):
            webPage = WebPage(url: url)
        case .depiction(let url):
            depiction = LinkedDepiction(url: url, title: title)
        case .package(let identifier):
            package = identifier
        case .system(let url):
            UIApplication.shared.open(url)
        }
    }

    /// A link tapped in text or in a web depiction; false when Codling cannot
    /// open it.
    @discardableResult
    func open(_ url: URL, base: URL?) -> Bool {
        guard let action = DepictionAction.parse(url.absoluteString, base: base) else {
            return false
        }
        perform(action)
        return true
    }
}

extension View {
    /// Lets the depictions and links inside this view open pages.
    func depictionRouting(_ router: DepictionRouter, base: URL?) -> some View {
        modifier(DepictionRouting(router: router, base: base))
    }
}

private struct DepictionRouting: ViewModifier {
    @ObservedObject var router: DepictionRouter
    let base: URL?

    func body(content: Content) -> some View {
        content
            .environmentObject(router)
            .environment(\.openURL, OpenURLAction { url in
                router.open(url, base: base) ? .handled : .discarded
            })
            .background(
                VStack {
                    NavigationLink(isActive: Binding(get: { router.package != nil },
                                                     set: { if !$0 { router.package = nil } })) {
                        if let identifier = router.package {
                            PackageLookupView(identifier: identifier)
                        }
                    } label: {
                        EmptyView()
                    }
                    NavigationLink(isActive: Binding(get: { router.depiction != nil },
                                                     set: { if !$0 { router.depiction = nil } })) {
                        if let linked = router.depiction {
                            DepictionPageView(url: linked.url, title: linked.title)
                        }
                    } label: {
                        EmptyView()
                    }
                }
                .hidden()
            )
            .sheet(item: $router.webPage) { page in
                SafariView(url: page.url)
                    .ignoresSafeArea()
            }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension DepictionColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension DepictionAlignment {
    var frame: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct DepictionTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The depiction's tint color, for links and buttons.
    var depictionTint: Color? {
        get { self[DepictionTintKey.self] }
        set { self[DepictionTintKey.self] = newValue }
    }
}

/// A symbol for a package without an icon, from its section.
enum SectionSymbol {
    static func name(for section: String?) -> String {
        let text = (section ?? "").lowercased()
        if text.contains("theme") { return "paintbrush.fill" }
        if text.contains("tweak") { return "wand.and.stars" }
        if text.contains("widget") { return "square.grid.2x2.fill" }
        if text.contains("app") { return "app.fill" }
        if text.contains("keyboard") { return "keyboard" }
        if text.contains("util") || text.contains("develop") || text.contains("system") || text.contains("terminal")
            || text.contains("admin") || text.contains("devel") || text.contains("shell") {
            return "terminal.fill"
        }
        if text.contains("librar") || text.contains("framework") { return "books.vertical.fill" }
        return "shippingbox.fill"
    }
}

/// Five stars, filled to a rating out of five.
struct StarsView: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(index))
            }
        }
        .foregroundColor(.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%.1f out of 5 stars", rating))
    }

    private func symbol(_ index: Int) -> String {
        let value = rating - Double(index)
        if value >= 0.75 { return "star.fill" }
        if value >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// "Paid", for packages that are sold.
struct PaidBadge: View {
    var body: some View {
        Text("Paid")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(.white)
            .background(Capsule().fill(Color.orange))
    }
}
