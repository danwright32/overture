import Testing
import Foundation

// #3654: there is no array of cards for a surface to reach for, so a drawn row has to ask the store.
//
// WHY THIS IS STRUCTURAL AND NOT A RULE. The plan's own wording is that the render path REGISTERS the
// keys it draws and does not opt in, because a behaviour each call site must remember is enforceable by
// nothing: a surface that never registers is indistinguishable from one where the condition never arises
// (L621). What makes that true here is an ABSENCE. `RenderData` used to carry `items` and `visible`, one
// card per show in scope, and any surface could take a card out of either without anybody noticing. Both
// are gone. What is left is the store, and asking it is what records the key.
//
// THE LIMIT OF THIS GUARD, said plainly. It reads source, so it cannot prove a card is resolved when the
// app actually draws, and no test in this repository can: the one hosted rig that brings a real
// `QueueView` up in a real window never orders it front (#3480), so its `LazyVStack` realizes no rows and
// `FeltWaitCostTests` reports `felt-wait-cards-drawn: 0` on every run. That is a fact about the rig, and
// it is printed rather than hidden. What this can do is hold the shape the mechanism needs.
@MainActor
@Suite("A drawn row gets its card from the pass's store (#3654)")
struct RenderPathGetsCardsFromTheStoreTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func theRenderDataCarriesNoArrayOfCards() {
        #expect(!queueView.isEmpty, "QueueView.swift could not be read, so this measured nothing")
        guard let render = SourceGuardHelper.propertyBody("struct RenderData {", in: queueView) else {
            Issue.record("expected to find QueueView.RenderData")
            return
        }
        let code = SwiftSource.scannableLines(in: render).map(\.code).joined(separator: "\n")
        #expect(!code.contains("[QueueItem]"), Comment(rawValue:
            "RenderData carries an array of cards again. That is one card per show in scope built on "
            + "every redraw, which is the whole cost #3654 removed, and a surface can take one out of it "
            + "without ever coming through the store, so nothing records the key and nothing counts a "
            + "miss."))
        #expect(code.contains("let cards: QueueModel.CardStore"),
                "the store is gone, so there is nothing for a drawn row to ask")
    }

    @Test func theRowRequestGoesThroughTheStore() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "prospectRow", in: queueView) else {
            Issue.record("expected to find QueueView.prospectRow, the one row-request site")
            return
        }
        #expect(body.contains("data.cards.card(for: row)"), Comment(rawValue:
            "the one place a drawn row becomes a card no longer asks the store. Whatever it asks instead "
            + "does not record the key, so the next pass prebuilds nothing and every row misses."))
        // A DEPARTING row takes the snapshot instead, and must: the send has already changed what the
        // show is, and the leaving delight draws the card as it was when Dan pressed.
        #expect(body.contains("departingCard ?? data.cards.card(for: row)"))
    }

    // The pass hands its own registry down and reads it back, which is what carries frame N's keys to
    // frame N+1. Asserted as a PAIR, because either half alone is inert: a registry nothing writes to
    // makes every frame prebuild nothing, and one nothing reads makes every frame prebuild everything.
    @Test func thePassReadsTheRegistryItAlsoWritesTo() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "makeRenderData", in: queueView) else {
            Issue.record("expected to find QueueView.makeRenderData")
            return
        }
        #expect(body.contains("requestedCardKeys: cardKeys.takeKeys()"), Comment(rawValue:
            "the pass no longer reads what the last frame drew, so it prebuilds nothing and every row on "
            + "screen is an on-the-spot build"))
        #expect(body.contains("cardKeyRegistry: cardKeys"), Comment(rawValue:
            "the render path has nowhere to record what it drew, so the next pass prebuilds nothing"))
    }
}
