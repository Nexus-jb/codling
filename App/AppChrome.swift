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
    /// Puts the System gear at the top right of a tab.
    func systemButton() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
