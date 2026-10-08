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

    // #4358 slice E4d: the row request is `card(for:in:)`, which notes the key for the next pass and asks the drawn
    // pass's store, then draws the engine's corrected card where its check at publish replaced one (C1).
    @Test func theRowRequestGoesThroughTheStore() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "prospectRow", in: queueView),
              let request = SourceGuardHelper.bodyOfFunction(named: "card", in: queueView) else {
            Issue.record("expected to find QueueView.prospectRow and its row request")
            return
        }
        // A DEPARTING row takes the snapshot instead, and must: the send has already changed what the
        // show is, and the leaving delight draws the card as it was when Dan pressed.
        #expect(body.contains("departingCard ?? card(for: row, in: data)"), Comment(rawValue:
            "the one place a drawn row becomes a card no longer goes through the row request"))
        #expect(request.contains("cardKeys.note(row.id)") && request.contains("data.cards.card(for: row, resolving: engine)"),
                Comment(rawValue: "the row request no longer records the key or asks the store, so the next pass "
                    + "prebuilds nothing and every row misses"))
        #expect(request.contains("published.corrected[row.id] ?? built"), Comment(rawValue:
            "the row request no longer draws the card the engine's check at publish corrected (C1)"))
    }

    // What the last frame drew reaches the next pass: the body takes the registry once and hands it to the engine as
    // its view (`QueueEngine.setViewInputs`), which the next pass prebuilds. Asserted as a PAIR with the note above,
    // because either half alone is inert.
    @Test func thePassReadsTheRegistryItAlsoWritesTo() {
        guard let hand = SourceGuardHelper.bodyOfFunction(named: "handTheEngineThisView", in: queueView),
              let body = SourceGuardHelper.propertyBody("var body: some View {", in: queueView) else {
            Issue.record("expected to find QueueView.handTheEngineThisView and the body that calls it")
            return
        }
        #expect(hand.contains("let drawn = cardKeys.takeKeys()") && hand.contains("engine.setViewInputs("),
                Comment(rawValue: "the engine is no longer told what the last frame drew, so it prebuilds nothing"))
        #expect(body.contains("handTheEngineThisView()"), "the body never hands the engine its view")
    }
}
