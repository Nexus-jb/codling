// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

/// Asks before a change, in a glass card in the middle of the screen over a
/// dimmed backdrop, in place of the system's action sheet. It covers
/// whatever is on screen, sheets and bars included, like an alert.
@MainActor
enum ConfirmPopup {
    struct Content {
        var symbol: String
        var color: Color
        var title: String
        var message: String
        var confirmTitle: String
        /// Draws the confirm button in red, for removing or clearing.
        var destructive = false
        var cancelTitle = "Cancel"
    }

    /// Shows the popup; onConfirm runs once it has gone, only when the user
    /// confirms.
    static func show(_ content: Content, onConfirm: @escaping () -> Void) {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        weak var weakHost = host
        host.rootView = AnyView(
            ConfirmPopupView(content: content) { confirmed in
                weakHost?.dismiss(animated: true) {
                    if confirmed {
                        onConfirm()
                    }
                }
            }
            .tint(Palette.text)
            .accentColor(Palette.text)
        )
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        Task { await Presenter.present(host) }
    }
}

private struct ConfirmPopupView: View {
    let content: ConfirmPopup.Content
    let finish: (Bool) -> Void
    @State private var shown = false
    @State private var finished = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { close(confirmed: false) }
                .accessibilityHidden(true)
            card
                .padding(.horizontal, 28)
                .scaleEffect(shown ? 1 : 0.92)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { shown = true }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: content.symbol)
                .font(.title2.weight(.semibold))
                .foregroundColor(content.color)
                .frame(width: 54, height: 54)
                .background(Circle().fill(content.color.opacity(0.14)))
                .accessibilityHidden(true)
            Text(content.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(content.message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            buttons
                .padding(.top, 6)
        }
        .padding(22)
        .frame(maxWidth: 360)
        .glassSurface(cornerRadius: 28)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close(confirmed: false) }
    }

    @ViewBuilder
    private var buttons: some View {
        let cancel = Button(content.cancelTitle) { close(confirmed: false) }
            .buttonStyle(TintedButtonStyle())
        let confirm = Button(content.confirmTitle) { close(confirmed: true) }
            .buttonStyle(TintedButtonStyle(color: content.destructive ? .red : Palette.text))
        // Side by side, or one over the other when the text is large.
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                confirm
                cancel
            }
        } else {
            HStack(spacing: 10) {
                cancel
                confirm
            }
        }
    }

    private func close(confirmed: Bool) {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: 0.15)) { shown = false }
        finish(confirmed)
    }
}
