// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The bar above the tabs while packages wait or apt is at work: what is
/// queued, and Confirm, which opens the review over the page the user is
/// on instead of the Queue tab.
struct QueueBar: View {
    @ObservedObject var queue: QueueModel
    /// Draws its own glass; false where the system draws it, as for iOS 26's
    /// tab view accessory.
    var glass = true
    let open: () -> Void

    static let height: CGFloat = 58

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold)) // fixed: the bar's symbol
                    .foregroundColor(Palette.text)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Palette.text)
                        .lineLimit(growing: 1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(growing: 1)
                    }
                }
                Spacer(minLength: 8)
                if working {
                    ProgressView()
                        .padding(.trailing, 8)
                } else {
                    Text(action)
                        .font(.footnote.weight(.heavy))
                        .foregroundColor(Palette.text)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .glassSurface(cornerRadius: 17, inset: true)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: glass ? Self.height : 44)
            .background {
                if glass {
                    Capsule()
                        .fill(Color.clear)
                        .glassSurface(cornerRadius: Self.height / 2)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(working ? "Opens the queue." : "Opens the queue to confirm.")
    }

    /// Whether the bar has something to show.
    static func shows(_ queue: QueueModel) -> Bool {
        !queue.items.isEmpty || queue.phase != .editing
    }

    private var working: Bool {
        switch queue.phase {
        case .preparing, .applying: return true
        default: return false
        }
    }

    private var symbol: String {
        switch queue.phase {
        case .finished(let succeeded, _, _, _, _): return succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
        case .blocked: return "xmark.octagon.fill"
        default: return "tray.and.arrow.down.fill"
        }
    }

    private var title: String {
        switch queue.phase {
        case .editing:
            return queue.items.count == 1 ? "1 Package Queued" : "\(queue.items.count) Packages Queued"
        case .preparing:
            return "Getting Ready"
        case .review:
            return "Ready to Confirm"
        case .blocked:
            return "apt Cannot Make This Change"
        case .applying:
            return "Installing"
        case .finished(let succeeded, _, _, _, _):
            return succeeded ? "Done" : "The Changes Were Not Applied"
        }
    }

    private var subtitle: String {
        switch queue.phase {
        case .preparing(let message), .applying(let message):
            return message
        default:
            return queue.items.map(\.name).joined(separator: ", ")
        }
    }

    private var action: String {
        switch queue.phase {
        case .editing, .review: return "CONFIRM"
        default: return "OPEN"
        }
    }
}
