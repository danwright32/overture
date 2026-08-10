import Testing
import Foundation
import SwiftUI

// #1929: Dan, walking the Debug build 2026-08-01, screenshot: the line
//
//   "Possible match to a show you dismissed in Overture: Thomas F. Hulbert Music International Piano
//    Competition Winners Recital?"
//
// ran straight off the right edge of the card and out of the row. It is rendered as a pill in the flow
// layout, alongside short labels like "Self-produced", and the flow wraps BETWEEN pills: a single pill
// wider than the whole row had nowhere to go.
//
// The rule this pins is the one a person would state after seeing that screenshot, and it is about
// every child, not about that sentence: nothing a flow layout places may end up past the width it was
// given. A length problem only shows itself when the data happens to be long, which is exactly why it
// sat unnoticed and why the guard is written about the arithmetic rather than about the one string.
@Suite("Nothing a flow layout places runs off the edge it was given (#1929)")
struct WrapHStackPackingTests {

    private static func pack(_ widths: [CGFloat], maxWidth: CGFloat) -> [WrapHStack.Placement] {
        WrapHStack.pack(sizes: widths.map { CGSize(width: $0, height: 20) },
                        maxWidth: maxWidth, spacing: 8, lineSpacing: 8)
    }

    // MARK: - The invariant

    @Test func noChildIsPlacedPastTheAvailableWidth() {
        let placements = Self.pack([90, 120, 640, 70], maxWidth: 300)

        #expect(!placements.isEmpty)
        for placement in placements {
            #expect(placement.maxX <= 300,
                    "a child at x \(placement.x) is \(placement.size.width) wide, ending at \(placement.maxX) in a 300 wide row: it would run off the card")
        }
    }

    // The one that reproduces the screenshot: a single child far wider than the row it sits in.
    @Test func aChildWiderThanTheWholeRowIsHeldInsideIt() {
        let placements = Self.pack([700], maxWidth: 260)

        #expect(placements.count == 1)
        #expect(placements[0].x == 0)
        #expect(placements[0].size.width == 260)
    }

    // MARK: - And the ordinary case is unchanged

    @Test func shortLabelsStillShareOneLine() {
        let placements = Self.pack([80, 90, 70], maxWidth: 400)

        #expect(placements.map(\.y) == [0, 0, 0])
        #expect(placements.map(\.x) == [0, 88, 186])
    }

    @Test func labelsThatDoNotFitMoveToTheNextLine() {
        let placements = Self.pack([180, 180, 180], maxWidth: 400)

        #expect(placements.map(\.y) == [0, 0, 28], "the third should drop to a second line")
        #expect(placements[2].x == 0)
    }

    // A child that exactly fills the row is not pushed onto a line of its own for the sake of a
    // rounding error, and it is still inside the row.
    @Test func aChildThatExactlyFillsTheRowStaysOnIt() {
        let placements = Self.pack([300], maxWidth: 300)

        #expect(placements[0].x == 0)
        #expect(placements[0].maxX == 300)
    }

    @Test func nothingToPlaceIsNotACrash() {
        #expect(Self.pack([], maxWidth: 300).isEmpty)
    }

    // An unbounded proposal is what `sizeThatFits` sees before a width is known. Nothing may be clamped
    // to zero or dropped there, or the layout would measure itself as empty and never get a width.
    @Test func anUnboundedRowKeepsEveryChildAtItsOwnWidth() {
        let placements = Self.pack([90, 700], maxWidth: .infinity)

        #expect(placements.map(\.size.width) == [90, 700])
        #expect(placements.map(\.y) == [0, 0])
    }
}
