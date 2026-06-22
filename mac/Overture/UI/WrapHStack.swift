import SwiftUI

// A flow layout that wraps its children onto new lines when they run out of width.
// Mirrors the role of Downbeat's WrapHStack; implemented with the Layout protocol.
struct WrapHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = layout(subviews, maxWidth: maxWidth)
        let height = rows.isEmpty ? 0 : rows.last!.maxY
        let width = rows.map(\.maxX).max() ?? 0
        rows.removeAll()
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews, maxWidth: bounds.width)
        for placement in rows {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Placement { let index: Int; let x: CGFloat; let y: CGFloat; let size: CGSize
        var maxX: CGFloat { x + size.width }; var maxY: CGFloat { y + size.height } }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> [Placement] {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placements.append(Placement(index: index, x: x, y: y, size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return placements
    }
}
