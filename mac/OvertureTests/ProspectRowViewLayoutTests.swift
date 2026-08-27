import Testing
import SwiftUI

// #379: visual/layout regression coverage for ProspectRowView, using the proven ImageRenderer
// technique (documented from live-verifying #379/#489: render a SwiftUI view to a real laid-out
// size at a fixed width, no live app or store needed). Rather than a full pixel-diff against a
// checked-in reference image (needs hand-regenerated references on every real design change, and
// risks false positives from font-rendering differences across machines), these assert on
// RELATIVE rendered height: a row with much more wrapping text renders meaningfully taller than
// one with little, proving wrapping is actually happening instead of clipping or silently staying
// flat. No hardcoded absolute pixel value to keep in sync with font rendering quirks.
@MainActor
@Suite("ProspectRowView layout (#379)")
struct ProspectRowViewLayoutTests {
    // Matches the real queue's max row width (see the #379/#489 diagnostic precedent).
    private static let rowWidth: CGFloat = 760

    private func renderedHeight(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: Self.rowWidth).background(Color.white))
        renderer.scale = 1
        return CGFloat(renderer.cgImage?.height ?? 0)
    }

    private func item(groupName: String = "Aurora Strings", fitReason: String = "Strong fit") -> QueueItem {
        QueueItem(id: "k", groupName: groupName, discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: fitReason,
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    @Test func aRowWithAPathologicallyLongGroupNameRendersMeaningfullyTallerThanAShortOne() {
        let short = ProspectRowView(item: item(groupName: "Aurora Strings"), today: "2026-07-09",
                                    onKeep: {}, onDismiss: { _ in })
        // A long, unbroken hyphenated string (no spaces to wrap on except the hyphens), mirroring
        // the exact pathological case the #379/#489 diagnostic already confirmed wraps cleanly.
        let longName = String(repeating: "Aurora-Chamber-Strings-Ensemble-Ensemble-", count: 4)
        let long = ProspectRowView(item: item(groupName: longName), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let shortHeight = renderedHeight(short)
        let longHeight = renderedHeight(long)

        #expect(shortHeight > 0)
        #expect(longHeight > shortHeight * 1.3)
    }

    @Test func aRowWithALongFitReasonRendersMeaningfullyTallerThanAShortOne() {
        let short = ProspectRowView(item: item(fitReason: "Strong fit"), today: "2026-07-09",
                                    onKeep: {}, onDismiss: { _ in })
        let longReason = String(repeating: "This performance matches Dan's usual coverage profile closely and merits a look. ", count: 6)
        let long = ProspectRowView(item: item(fitReason: longReason), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let shortHeight = renderedHeight(short)
        let longHeight = renderedHeight(long)

        #expect(shortHeight > 0)
        #expect(longHeight > shortHeight * 1.3)
    }
}
