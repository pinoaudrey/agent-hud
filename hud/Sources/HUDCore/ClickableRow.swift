import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Hover feedback for a row that acts on a click: a soft wash behind it and the
/// pointing-hand cursor, so the card shows which rows are controls.
///
/// The cursor is set, not pushed: a row can vanish under the pointer when the
/// next poll drops it, and a pushed cursor with no pop would stay a hand.
struct ClickableRow: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEnabled && isHovered ? Theme.panel2 : Color.clear)
            )
            .onHover { inside in
                guard isEnabled else { return }
                isHovered = inside
                #if canImport(AppKit)
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                #endif
            }
            .onDisappear {
                #if canImport(AppKit)
                if isHovered { NSCursor.arrow.set() }
                #endif
            }
    }
}

extension View {
    func clickableRow(isEnabled: Bool = true) -> some View {
        modifier(ClickableRow(isEnabled: isEnabled))
    }
}
