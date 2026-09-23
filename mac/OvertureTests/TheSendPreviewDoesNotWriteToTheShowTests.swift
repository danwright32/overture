import Testing
import Foundation
import Observation
import SwiftData

// #4168: previewing the Send sheet must not WRITE to the show it is previewing.
//
// WHAT HAPPENED. On 2026-09-22 at about 21:44 Overture froze with its Send confirmation sheet open,
// after the contact choice on it had been changed. The process held one core at 100% and did not
// recover; Dan force quit it. Load average was 8.26, so the machine was not saturated. Two samples a few
// seconds apart both have the main thread inside `SendConfirmSheet.body`, 1762 of 4176 samples under it
// in the second, under `SendConfirmSheet.current`.
//
// THE MECHANISM, which the issue infers and this suite establishes. `current` is a computed property and
// the body reads it seven times (the From, To and Subject fields, the preview, the warning, the
// reassurance and `outgoingBody`). Once `touched` is true every one of those reads ran the `rebuild`
// closure, and that closure did this:
//
//     let was = model.sendsTogetherOverride
//     model.sendsTogetherOverride = together
//     defer { model.sendsTogetherOverride = was }
//
// Two writes to an OBSERVED SwiftData model, during a body evaluation, seven times a pass. A write to an
// observed property invalidates every view that read it, so the pass that performs it schedules the next
// one, which performs it again. That is a redraw with no fixed point, which fits one core pinned rather
// than a long stall that ends.
//
// `aWriteDuringThePreviewIsObservedByTheQueue` below is that reproduction: it holds the OLD shape and
// shows the write reaching an observer. It is kept rather than deleted, because a test that only asserts
// the new shape is silent about whether the old one was ever really the problem (L159, L681).
//
// THE FIX is to pass the choice in as a VALUE. `SendGroup.previewGroup`, `SendGroup.pendingGroup` and
// `SendConfirmation.init` now take `together:`, defaulting to the show's own stored answer, so a preview
// composes as if the choice had been made without making it. Nothing is written until Dan presses Send,
// which is what `requestSend`'s own comment already said it wanted: "the real choice is only written at
// the commit, so a preview of one email each cannot leave the show changed if he cancels".
@MainActor
@Suite("The Send preview does not write to the show (#4168)")
struct TheSendPreviewDoesNotWriteToTheShowTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A drafted show with two sendable contacts, which is the only shape that offers the choice at all.
    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k1", groupName: "Ensemble", discipline: "choral",
                         venue: "Room", performanceDate: "2099-01-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.status = .drafted
        p.draftSubject = "Photographing your January concert"
        p.draftBody = "Hello, I photograph performing arts in New York."
        ctx.insert(p)
        for (n, address) in ["ana@example.test", "ben@example.test"].enumerated() {
            let r = Recipient(id: address, email: address, provenance: .presenter)
            r.name = "Person \(n)"
            p.addRecipient(r)
        }
        return p
    }

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var didFire: Bool { lock.withLock { value } }
        func fire() { lock.withLock { value = true } }
    }

    // MARK: - The reproduction

    // THE OLD SHAPE, held here so the claim below is about a real defect rather than a rearrangement.
    // This is exactly what `QueueView.requestSend`'s rebuild closure did, run inside the observation
    // tracking a SwiftUI body sets up around itself.
    @Test("writing the choice onto the show during a preview is seen by anything watching it")
    func aWriteDuringThePreviewIsObservedByTheQueue() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let fired = Fired()

        withObservationTracking {
            _ = p.sendsTogetherOverride
        } onChange: {
            fired.fire()
        }
        // The old route: set, build, restore.
        let was = p.sendsTogetherOverride
        p.sendsTogetherOverride = false
        _ = SendConfirmation(prospect: p, approving: true, selecting: ["ana@example.test"])
        p.sendsTogetherOverride = was

        #expect(fired.didFire, Comment(rawValue:
            "writing the choice onto the live show did not reach an observer of it, so this suite is not "
            + "reproducing the redraw #4168 measured and the claim below is about nothing"))
    }

    // THE CLAIM.
    @Test("composing a preview with the choice passed in writes nothing and is seen by nobody")
    func composingAPreviewWritesNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let fired = Fired()

        withObservationTracking {
            _ = p.sendsTogetherOverride
        } onChange: {
            fired.fire()
        }
        _ = SendConfirmation(prospect: p, approving: true, selecting: ["ana@example.test"],
                             together: false)

        #expect(!fired.didFire, Comment(rawValue:
            "composing the Send preview still writes to the live show, so every one of the seven reads "
            + "of `current` in a body pass invalidates the views watching it and schedules another pass "
            + "(#4168)"))
        #expect(p.sendsTogetherOverride == nil, Comment(rawValue:
            "the show's own stored choice moved during a preview, so cancelling the sheet would leave it "
            + "changed"))
    }

    // MARK: - And it is the same preview

    // The value route must compose exactly what the write route composed, in BOTH directions, or this
    // trades a freeze for a sheet that describes a different email from the one that would leave (L70).
    @Test("the preview composed from a passed choice is the one the write route composed")
    func theValueRouteComposesTheSamePreview() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        for together in [true, false] {
            let was = p.sendsTogetherOverride
            p.sendsTogetherOverride = together
            let byWriting = SendConfirmation(prospect: p, approving: true, selecting: nil)
            p.sendsTogetherOverride = was

            let byValue = SendConfirmation(prospect: p, approving: true, selecting: nil,
                                           together: together)

            #expect(byValue == byWriting, Comment(rawValue:
                "with together=\(together) the two routes composed different previews, so passing the "
                + "choice in changes what the sheet says rather than only how it is asked"))
        }
    }

    // The two directions really are different previews, so the equality above is not two identical
    // answers agreeing by accident (L159).
    @Test("together and separately really do compose different previews")
    func theTwoChoicesDiffer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let together = try #require(SendConfirmation(prospect: p, approving: true, selecting: nil,
                                                     together: true))
        let separately = try #require(SendConfirmation(prospect: p, approving: true, selecting: nil,
                                                       together: false))
        #expect(together.recipient != separately.recipient, Comment(rawValue:
            "both choices address the same contacts (\(together.recipient)), so this fixture cannot tell "
            + "the two apart and the equality test above proves nothing"))
    }

    // Absent, it is the show's own answer, so every existing call site keeps the behaviour it had.
    @Test("a preview with no choice passed uses the show's own")
    func theDefaultIsTheShowsOwnAnswer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.sendsTogetherOverride = false
        #expect(SendConfirmation(prospect: p, approving: true, selecting: nil)
                == SendConfirmation(prospect: p, approving: true, selecting: nil, together: false))
        #expect(SendGroup.previewGroup(of: p).count == SendGroup.previewGroup(of: p, together: false).count)
    }

    // MARK: - The wiring, because built is not wired (L3)

    @Test("the queue's rebuild closure no longer writes the choice onto the show")
    func theRebuildClosureWritesNothing() {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!source.isEmpty, "QueueView could not be read, so this guard checked nothing")
        // SCOPED TO `requestSend`'S BODY, not the whole file, and that is not tidiness. The first version
        // of this guard asked the file for `together: together` and SURVIVED the mutation that removed it
        // from the rebuild closure, because `performSend(item.id, selecting: selected, together: together)`
        // sits four lines below and answered for it. A guard matching source text over a whole file is
        // satisfied by any occurrence of that text, so a second use elsewhere keeps it green while the
        // guarded region is broken (L135).
        guard let body = SourceGuardHelper.bodyOfFunction(named: "requestSend", in: source) else {
            Issue.record("expected to find requestSend's body")
            return
        }
        #expect(!body.contains("model.sendsTogetherOverride = together"), Comment(rawValue:
            "the Send sheet's rebuild closure writes the choice onto the live show again, which is the "
            + "observed write during a body evaluation that #4168 measured as a pinned core"))
        #expect(body.contains("SendConfirmation(prospect: model, approving: true,"), Comment(rawValue:
            "requestSend no longer composes its preview the way this guard knows how to read, so what "
            + "follows says nothing"))
        #expect(body.contains("together: together) else { return nil }"), Comment(rawValue:
            "the rebuild closure no longer passes the choice to the composition, so whatever it is "
            + "previewing is not the choice Dan ticked"))
    }

    // The other half of the cost, and the one the write was multiplying: `current` ran the rebuild on
    // every read, and a body pass reads it seven times.
    @Test("the sheet builds its preview once per change rather than once per read")
    func theSheetHoldsItsRebuiltPreview() {
        let source = SourceGuardHelper.source("Overture/UI/SendConfirmSheet.swift")
        #expect(!source.isEmpty, "SendConfirmSheet could not be read, so this guard checked nothing")
        #expect(source.contains("@State private var rebuilt: SendConfirmation?"), Comment(rawValue:
            "the sheet no longer holds its rebuilt preview, so `current` is computing one again on every "
            + "read and a body pass reads it seven times"))
        #expect(!source.contains("return rebuild(selected, together) ?? confirmation"), Comment(rawValue:
            "`current` runs the rebuild closure again, which is the per read cost #4168 measured"))
    }
}
