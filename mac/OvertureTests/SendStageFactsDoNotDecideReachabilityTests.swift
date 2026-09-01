import Testing
import Foundation
import SwiftData

// #3387 and milestone 61 Phase 0.1. Whether Dan can REACH a show and whether an email may GO OUT
// right now are two questions, and until this they were asked through one predicate.
//
// `reachabilityResultFromRecipients` gated its `emailFound` arm on `isSendablePending`, which folds in
// an uncleared calendar conflict (#901), a blank subject line (#2052), the draft lint and greeting
// holds (#2545), `pausedByReply` and this row's send state. None of those is a fact about whether a
// way to contact anybody exists, so a show holding a published address badged as unreachable because
// Dan had blocked the night.
//
// LIVE-STORE-CLAIM verified=2026-08-31 measure="prospects holding an address no research guard is holding, whose stored reachability verdict denies email_found, and how many of those carry an open calendar conflict"
// Measured 2026-08-31 against a WAL inclusive copy: 9 prospects hold an unguarded address while their
// stored verdict denies it, and 7 of the 9 carry an open calendar conflict. Exactly 4 carry a stored
// `no_email_found` over a live route.
//
// Dan's rule, 2026-08-31, given instead of choosing between the readers the plan offered him: "The
// score should be solely on if I can contact them. I can contact them if the night is blocked (even if
// I shouldn't). I can contact them if there's no subject line (I'll just write one). If it failed a
// lint check I'll just fix what's wrong, that doesn't have anything to do with the person I'm trying to
// contact. It should only be impacted by whether or not I'm physically capable of contacting them."
//
// So the split is NOT per reader: the tier moves onto the clean predicate too, which is what keeps the
// badge and the fit score answering from one list (Prospect.swift:251-252, L16).
@MainActor
@Suite("Send stage facts do not decide whether a show can be reached (#3387)")
struct SendStageFactsDoNotDecideReachabilityTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func addAddress(_ ctx: ModelContext, to p: Prospect,
                            email: String? = "booking@kestrelquartet.example",
                            formURL: String? = nil, tier: ContactTier? = .primary) -> Recipient {
        let r = Recipient(id: email ?? "form-only", email: email, name: "Kestrel Quartet", role: nil,
                          provenance: .performer, contactMethodRaw: "generic_inbox",
                          contactConfidenceRaw: "medium", contactFormURL: formURL,
                          contactSourceURL: nil)
        r.contactTier = tier
        p.addRecipient(r)
        try? ctx.save()
        return r
    }

    // The defect exactly: a blocked night is a fact about Dan's calendar, not about the quartet's inbox.
    @Test func aBlockedNightDoesNotHideAnAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p)
        p.conflictOpen = true
        try? ctx.save()

        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    // #2052 holds a subject-less draft at the send, correctly. It must not also erase the address.
    @Test func aMissingSubjectDoesNotHideAnAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p)
        p.draftBody = "A body with no subject line yet."
        p.draftSubject = ""
        try? ctx.save()

        #expect(p.draftIsMissingSubject)
        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    // Dan's rule reaches the SCORE, not only the badge: the tier is what the ranker pays route points
    // off, so leaving it on the send predicate would have the card and the score answering from two
    // different lists, which is the invariant Prospect.swift:251-252 declares.
    @Test func aBlockedNightDoesNotStripTheContactTier() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p, tier: .primary)
        p.conflictOpen = true
        try? ctx.save()

        #expect(p.contactTierFromRecipients == .primary)
    }

    // The fifth hold state, decided here rather than left to be discovered. `isHeldDownToUnverified` is
    // in NEITHER `isHeldByAGuard` nor `isSendablePending`; it drives warnings only. So it does not
    // withhold the route, which matches today's behaviour and is the right answer: the hold down
    // describes confidence in WHO is on the end, which the card already warns about, and withholding
    // the route as well would silently remove a show Dan can judge in seconds. Written down so the next
    // reader of `isHeldByAGuard`'s "every guard" comment does not conclude a case was overlooked.
    @Test func anAddressHeldDownToUnverifiedIsStillARoute() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = addAddress(ctx, to: p)
        r.heldDownToUnverified = true
        try? ctx.save()

        #expect(r.isHeldDownToUnverified)
        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    // The predicate itself, per guard, so a later reader can see which facts it does and does not read.
    @Test func hasUnguardedAddressReadsTheResearchGuardsAndNothingElse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = addAddress(ctx, to: p)
        #expect(r.hasUnguardedAddress)

        r.looksLikeVenue = true
        #expect(!r.hasUnguardedAddress)
        r.looksLikeVenueDismissed = true
        #expect(r.hasUnguardedAddress)

        r.looksLikePressContact = true
        #expect(!r.hasUnguardedAddress)
        r.looksLikePressContactDismissed = true
        #expect(r.hasUnguardedAddress)

        r.looksLikeDuplicateContact = true
        #expect(!r.hasUnguardedAddress)
        r.looksLikeDuplicateContactDismissed = true
        #expect(r.hasUnguardedAddress)

        r.looksLikeAnotherPersons = true
        #expect(!r.hasUnguardedAddress)
        r.looksLikeAnotherPersonsDismissed = true
        #expect(r.hasUnguardedAddress)
    }

    // An address that is not there at all is not an unguarded address.
    @Test func noAddressIsNotAnUnguardedAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = addAddress(ctx, to: p, email: nil, formURL: "https://kestrelquartet.example/contact")
        #expect(!r.hasUnguardedAddress)
    }
}

// The cascade `hasUnguardedAddress` is substituted into is FIVE way, and revision 2 of the plan would
// have collapsed it: a route bearing predicate in the FIRST arm reports every form-only and social-only
// show as `emailFound`, which then drives the org ledger's address list, the send path, the ranker's
// route points and the hand pitch control. One fixture per arm, so that substitution cannot be made
// again without three of these going red.
@MainActor
@Suite("The verdict cascade still has five distinct arms (#3387)")
struct VerdictCascadeArmsTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func add(_ ctx: ModelContext, to p: Prospect, id: String, email: String? = nil,
                     formURL: String? = nil) -> Recipient {
        let r = Recipient(id: id, email: email, name: "Kestrel Quartet", role: nil,
                          provenance: .performer, contactMethodRaw: "generic_inbox",
                          contactConfidenceRaw: "medium", contactFormURL: formURL, contactSourceURL: nil)
        p.addRecipient(r)
        try? ctx.save()
        return r
    }

    @Test func anUnguardedAddressIsEmailFound() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(ctx, to: p, id: "a", email: "booking@kestrelquartet.example")
        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    @Test func aGuardedAddressIsWeakContactOnly() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = add(ctx, to: p, id: "a", email: "press@rowanhall.example")
        r.looksLikePressContact = true
        try? ctx.save()
        #expect(p.reachabilityResultFromRecipients == .weakContactOnly)
    }

    @Test func aFormOnTheActsOwnSiteIsContactFormOnly() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(ctx, to: p, id: "a", formURL: "https://kestrelquartet.example/contact")
        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
    }

    @Test func aSocialProfileIsSocialOnly() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(ctx, to: p, id: "a", formURL: "https://instagram.com/kestrelquartet")
        #expect(p.reachabilityResultFromRecipients == .socialOnly)
    }

    @Test func nothingAtAllIsNoEmailFound() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // `hasAnyRoute` is DERIVED from the cascade, so it must answer yes on all four route arms and no on
    // the fifth. Written as one test over the set rather than five, because the claim is about the
    // relationship between the two, not about any one arm.
    @Test func hasAnyRouteIsTrueOnEveryArmButTheLast() throws {
        let ctx = ModelContext(try container())

        let withAddress = show(ctx)
        add(ctx, to: withAddress, id: "a", email: "booking@kestrelquartet.example")
        #expect(withAddress.hasAnyRoute)

        let bare = show(ctx)
        #expect(!bare.hasAnyRoute)
    }
}

// #3387 removes the hand pitch control from a row whose only address was held by an open calendar
// conflict, because that row now reads `emailFound` and goes through Overture's own send path. That is
// correct on FormOutreach's own stated scope (Dan, 2026-07-28: forms only, and only where the form is
// the ONLY way through), but it is a control VANISHING from a card, which no existing assertion covered.
@MainActor
@Suite("The hand pitch control leaves a row that has a working address (#3387)")
struct HandPitchControlFollowsTheCleanPredicateTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func showWithAddressFormAndBlockedNight(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        let r = Recipient(id: "a", email: "booking@kestrelquartet.example", name: "Kestrel Quartet",
                          role: nil, provenance: .performer, contactMethodRaw: "generic_inbox",
                          contactConfidenceRaw: "medium",
                          contactFormURL: "https://kestrelquartet.example/contact", contactSourceURL: nil)
        p.addRecipient(r)
        p.conflictOpen = true
        try? ctx.save()
        return p
    }

    @Test func aBlockedNightOverAWorkingAddressOffersNoHandPitch() throws {
        let ctx = ModelContext(try container())
        let p = showWithAddressFormAndBlockedNight(ctx)

        // Both halves, because the second is WHY the first is right: the row is emailFound now, so the
        // form is not the only way through and the control correctly does not belong to it.
        #expect(p.reachabilityResultFromRecipients == .emailFound)
        #expect(FormPitch.state(of: p) == .unavailable)
    }

    // The control is still there for the case it exists for: a form and no address at all.
    @Test func aFormWithNoAddressStillOffersTheHandPitch() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet", performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        let r = Recipient(id: "a", email: nil, name: "Kestrel Quartet", role: nil,
                          provenance: .performer, contactMethodRaw: "contact_form",
                          contactConfidenceRaw: "medium",
                          contactFormURL: "https://kestrelquartet.example/contact", contactSourceURL: nil)
        p.addRecipient(r)
        try? ctx.save()

        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
        #expect(FormPitch.state(of: p) == .ready(recipientId: "a",
                                                 formURL: "https://kestrelquartet.example/contact"))
    }
}
