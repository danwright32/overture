import Testing
import Foundation
import SwiftData

// #3707 (milestone 82, Phase 1): making the reply link REACHABLE on a pitch Overture emailed.
//
// The case is #3706's: the pitch went out to one contact, that contact forwarded it, and somebody else
// wrote back on a thread of their own. Every existing route refuses, each for a reason that is correct
// about the case it was written for, and together they leave the shape with no control at all. The row
// then reads as silent, and `PostEventPrompt` closes it out as `neverHeardBack`, which is the false row
// this milestone exists to stop reaching the funnel.
//
// This phase adds no writing. It only decides WHERE the question can be asked from, so the tests here are
// about the gate and about the wiring that puts it on a menu Dan already opens.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Offering the reply link from the reached-out row's menu (#3707)")
struct LinkReplyFromAnotherThreadTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // The shape #3706 measured on the live store: sent, a thread of its own, no reply recorded.
    @discardableResult
    private func emailedPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "them@act.example", email: "them@act.example", name: "Corin Hale",
                          provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-9 * 86_400)
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        p.addRecipient(r)
        return r
    }

    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    // MARK: the gate

    // The whole point of the phase: the case that had no control anywhere now has one.
    @Test("offered on an emailed pitch with no reply recorded")
    func offeredOnAnEmailedPitchWithNoReplyYet() throws {
        let ctx = ModelContext(try container())
        let r = emailedPitch(ctx, on: show(ctx))

        #expect(LinkReplyFromAnotherThread.isOffered(r))
    }

    // Asked of the same predicate the rest of the product asks (L16), rather than of `sentAt`, which
    // #331/#378 already established is true of staged and corrupt records that were never sent.
    @Test("not offered before the pitch has provably gone out")
    func notOfferedBeforeThePitchWentOut() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.example", email: "them@act.example", provenance: .act)
        p.addRecipient(r)

        #expect(LinkReplyFromAnotherThread.isOffered(r) == false)
    }

    // Overture already knows. Offering to link one here would be a second writer racing detection.
    @Test("not offered once a reply has been detected")
    func notOfferedOnceAReplyIsDetected() throws {
        let ctx = ModelContext(try container())
        let r = emailedPitch(ctx, on: show(ctx))
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-3600)

        #expect(LinkReplyFromAnotherThread.isOffered(r) == false)
    }

    // #2711's route. Dan has already told Overture a reply arrived, so the question is answered.
    @Test("not offered once Dan has marked a reply by hand")
    func notOfferedOnceMarkedByHand() throws {
        let ctx = ModelContext(try container())
        let r = emailedPitch(ctx, on: show(ctx))
        r.replyMarkedByHandAt = now.addingTimeInterval(-3600)

        #expect(LinkReplyFromAnotherThread.isOffered(r) == false)
    }

    // The pitch is over. Linking a conversation onto a closed contact would reopen a question Dan has
    // already answered on the row beside this one.
    @Test("not offered once the contact has been closed out")
    func notOfferedOnceResolved() throws {
        let ctx = ModelContext(try container())
        let r = emailedPitch(ctx, on: show(ctx))
        r.resolution = .declinedHard

        #expect(LinkReplyFromAnotherThread.isOffered(r) == false)
    }

    // ONE route to the picker per row. #2718's inline control already offers exactly this on a hand-sent
    // pitch with no conversation, and a row carrying both would state one fact twice (L605).
    @Test("not offered where the inline control (#2718) already offers the same picker")
    func notOfferedWhereTheInlineControlAlreadyDoes() throws {
        let ctx = ModelContext(try container())
        let r = formPitch(ctx, on: show(ctx))

        #expect(ProposedConversation.offersManualLink(r), "the premise of this test")
        #expect(LinkReplyFromAnotherThread.isOffered(r) == false)
    }

    // The other half of that: once a form pitch holds a conversation the inline control withdraws, and
    // this shape is then as unreachable as the emailed one. The gate is about the conversation, not the
    // channel.
    @Test("offered on a form pitch that already holds a conversation")
    func offeredOnAFormPitchHoldingAConversation() throws {
        let ctx = ModelContext(try container())
        let r = formPitch(ctx, on: show(ctx))
        r.gmailThreadId = "t9"
        r.conversationAttachedAt = now.addingTimeInterval(-86_400)

        #expect(ProposedConversation.offersManualLink(r) == false, "the premise of this test")
        #expect(LinkReplyFromAnotherThread.isOffered(r))
    }

    // MARK: where it is offered from

    // Dan's call, 2026-09-08: inside the menu he already opens, under a separator, rather than a control
    // sitting on every reached-out row at rest. Inside `CloseOutMenu` and not spelled out at the call
    // site, for that view's own stated reason: a Menu written inline puts its items' buttons into the
    // trailing column, where `ReachedOutRowSlots` counts them, so a person would see one control and the
    // guard would count several.
    @Test("the item lives inside CloseOutMenu, under a separator")
    func theItemLivesInsideTheMenu() throws {
        let menu = SourceGuardHelper.source("Overture/UI/CloseOutMenu.swift")
        #expect(!menu.isEmpty)
        // Asked as booleans, never as `#expect(source.contains(...))`, because a failing expectation
        // renders its own operands and the operand here is a whole file: the message saying what broke
        // would arrive under it (L445).
        let offersTheItem = menu.contains("LinkReplyFromAnotherThread.menuLabel")
        let separatesIt = menu.contains("Divider()")
        #expect(offersTheItem, "the link item is not in the menu at all")
        #expect(separatesIt,
                "the item is not separated from the endings, so it reads as one of them")
    }

    // It costs the row no new control, which is what makes it fit under a ceiling that is already stated
    // (#2167). Asserted rather than assumed: the count guard in ReachedOutRowSlotsTests reads the trailing
    // column, and an item added there instead would pass every test in this file while failing that one.
    @Test("the row grows no new slot")
    func theRowGrowsNoNewSlot() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try String(SourceGuard.functionBody(named: "reachedOutRow", in: source))
        let column = try #require(
            SourceGuardHelper.between("VStack(alignment: .trailing, spacing: 6) {", and: "\n        }",
                                      in: body))

        // The GATE has to decide it, not merely the parameter be present. Written as `onLinkReply:`
        // alone this passed with the argument replaced by `false`, which is an item offered on no row at
        // all: the needle proved the call site had a parameter and said nothing about what fills it
        // (measured by mutation, 2026-09-08).
        let offersTheItem = column.contains("onLinkReply: LinkReplyFromAnotherThread.isOffered(")
        let drawsItsOwnControl = column.contains("Button(LinkReplyFromAnotherThread")
        #expect(offersTheItem, "the row does not ask the gate whether to offer the item")
        #expect(!drawsItsOwnControl,
                "the item is drawn as its own control in the column, which is a fourth slot")
    }

    // #3651/#3690: a control on this row resolves its press against the LIVE list by identity, never
    // against the model the pass captured, because deletes run on the main context with a window open and
    // a captured model read at press time is a crash rather than a stale row.
    @Test("the press resolves by identity, not from the captured model")
    func thePressResolvesByIdentity() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try String(SourceGuard.functionBody(named: "linkReplyFromAnotherThread", in: source))

        let resolvesByIdentity = body.contains("ReachedOutSnapshot.resolve")
        let saysWhyItRefused = body.contains("feedback.acknowledge")
        #expect(resolvesByIdentity, "the press does not resolve against the live list")
        #expect(saysWhyItRefused,
                "a refusal says nothing, so the control reads as broken (L148)")
    }

    // The sibling, covered with it rather than left for a later sweep (the class, not the instance). The
    // Follow-ups row is where `PostEventPrompt` asks how the show ended, so it is the surface where
    // #3706's false `neverHeardBack` is actually recorded.
    @Test("the Follow-ups row offers it too")
    func theFollowUpsRowOffersItToo() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!source.isEmpty)
        let offersTheItem = source.contains("LinkReplyFromAnotherThread.isOffered")
        let canOpenThePicker = source.contains("LinkReplyPicker(")
        #expect(offersTheItem,
                "the row that asks how the show ended cannot say a reply arrived elsewhere")
        #expect(canOpenThePicker, "the item is offered there with nothing to open")
    }
}
