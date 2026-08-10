import SwiftUI

// A flow layout that wraps its children onto new lines when they run out of width.
// Mirrors the role of Downbeat's WrapHStack; implemented with the Layout protocol.
struct WrapHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = Self.pack(sizes: sizes(of: subviews, maxWidth: maxWidth), maxWidth: maxWidth,
                             spacing: spacing, lineSpacing: lineSpacing)
        let height = rows.last?.maxY ?? 0
        let width = rows.map(\.maxX).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = Self.pack(sizes: sizes(of: subviews, maxWidth: bounds.width), maxWidth: bounds.width,
                             spacing: spacing, lineSpacing: lineSpacing)
        for placement in rows {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    // One child's place in the flow.
    struct Placement: Equatable {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
        var maxX: CGFloat { x + size.width }
        var maxY: CGFloat { y + size.height }
    }

    // How big each child wants to be, given the width there actually is.
    //
    // #1929: a child asked only for its UNSPECIFIED size answers with the width it would like on one
    // line, which for a pill carrying a show's name is wider than the card it sits in. Asking again,
    // this time proposing the available width, is what lets it wrap inside itself instead. Only
    // oversized children are re-measured, so an ordinary short pill costs nothing extra and keeps the
    // size it asked for.
    private func sizes(of subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let intrinsic = subview.sizeThatFits(.unspecified)
            guard intrinsic.width > maxWidth else { return intrinsic }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    // Where each child goes, as a pure function over sizes.
    //
    // Pure, and internal rather than private, because the thing that went wrong here is not visible
    // from any other angle: Dan saw a sentence run straight off the right edge of a card, and the only
    // statement of what should be true is "no child ends up past the width it was given". That is an
    // assertion about arithmetic, so it is kept somewhere arithmetic can be asserted.
    //
    // The clamp is belt to the re-measure's braces. A child that cannot narrow itself (a fixed-width
    // image, a Text with line breaking turned off) answers the second measurement with the same
    // oversized width, and without this it would still be placed running off the edge. Clamped, it is
    // truncated at the boundary instead, which is a visible loss rather than an invisible one.
    static func pack(sizes: [CGSize], maxWidth: CGFloat,
                     spacing: CGFloat, lineSpacing: CGFloat) -> [Placement] {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, wanted) in sizes.enumerated() {
            let size = CGSize(width: min(wanted.width, maxWidth), height: wanted.height)
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
