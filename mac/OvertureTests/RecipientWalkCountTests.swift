import Testing
import Foundation
import SwiftData

// #3653 step 3d (milestone #80): how many times building a card reaches for a show's contacts, COUNTED.
//
// WHY COUNTED AND NOT NAME-LISTED, which is the whole point of this step. A source guard forbidding
// `DraftCheck`, `SendGroup`, `RecipientSnapshot` and `draftLintBlockers` in the tier-one file asserts a
// PROXY for the quantity it protects (L63): it would pass unchanged while tier one took three walks per
// row, none of them naming any forbidden symbol. That is the exact shape #2033 used in this same file to
// triple per-card work while the sweep counter did not move.
//
// So the claim #3654 has to make is a NUMBER, and the number has to exist before the change that is
// supposed to move it. That is this milestone's own discipline, and it has already paid twice: the gate
// (#3662) and the honest baselines (#3664, #3665) both found the instruments saying something other than
// what the plan assumed.
//
// WHAT IT COUNTS: reaches, not rows walked. Every one of the twelve sites below walks the contacts, so
// the reach count is what must fall to one when tier one gathers the facts once. Counting rows walked
// instead would move with the store's contact spread as well as with the code, and this has to answer
// one question only (L63).
@MainActor
@Suite("How many times building a card reaches for a show's contacts (#3653)")
struct RecipientWalkCountTests {

    // ONE, since the contacts are read once per card and every fact reads that local.
    //
    // CORRECTING WHAT #3671 IMPLIED. That change counted twelve reaches and treated the number as a cost
    // to be driven down. Measured, driving it to one changed nothing: felt wait 1,135.2 ms against
    // 1,133.6 ms, card build within run-to-run noise. SwiftData faults a to-many relationship once and
    // caches it, so eleven of the twelve were array accesses over a collection whose median size is one.
    //
    // What the pin is FOR, therefore, is not a saving. It is that the number now counts FAULTS rather
    // than reads, so a genuine second fault added by the tier-one split shows up as two instead of
    // hiding among eleven cheap ones. That is worth pinning; a cost claim here would not be (L102, L107).
    private static let reachesPerCard = 1

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String, contacts: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Ensemble", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-10-01",
                         sourceListingURL: nil, priorRelationship: "none", production: "presenter",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        for n in 0..<contacts {
            let r = Recipient(id: "\(key)-c\(n)", email: "c\(n)@example.com", name: "Contact \(n)",
                              role: "programming", provenance: .presenter)
            r.prospect = p
            ctx.insert(r)
        }
        return p
    }

    // THE POSITIVE CONTROL, first, because a pin at any number is satisfied by a counter nothing
    // increments (L171, L98). It is the same trap #3664 found in the fixtures beside this one.
    @Test func theCounterMovesAtAll() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "show-1", contacts: 2)
        try ctx.save()

        let tally = QueueRenderPass.WorkTally.measure { _ = QueueItem(p) }

        #expect(tally.recipientReaches > 0,
                Comment(rawValue: "building a card recorded no reach for the contacts at all, so the pin "
                        + "below is a bound on nothing and would pass with the counter deleted."))
    }

    // THE PIN. One card, one show's worth of contacts, a known number of reaches.
    @Test func oneCardReachesForTheContactsAKnownNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "show-1", contacts: 2)
        try ctx.save()

        let tally = QueueRenderPass.WorkTally.measure { _ = QueueItem(p) }

        #expect(tally.recipientReaches == Self.reachesPerCard,
                Comment(rawValue: "building one card reached for its contacts \(tally.recipientReaches) "
                        + "times against a pinned \(Self.reachesPerCard). Moving this number is a "
                        + "decision about what a card costs: DOWN is #3654 landing, and up is per-card "
                        + "work being added where nothing else would report it (#2033's shape)."))
    }

    // AND IT SCALES WITH CARDS, not with contacts, which is what makes it the right quantity to pin
    // against a change that reduces how many CARDS get built (L63).
    @Test func theCountScalesWithCardsRatherThanWithContacts() throws {
        let ctx = ModelContext(try container())
        let few = show(ctx, key: "few", contacts: 1)
        let many = show(ctx, key: "many", contacts: 9)
        try ctx.save()

        let one = QueueRenderPass.WorkTally.measure { _ = QueueItem(few) }
        let other = QueueRenderPass.WorkTally.measure { _ = QueueItem(many) }
        let two = QueueRenderPass.WorkTally.measure { _ = QueueItem(few); _ = QueueItem(many) }

        #expect(one.recipientReaches == other.recipientReaches,
                Comment(rawValue: "a show with 9 contacts reached \(other.recipientReaches) times against "
                        + "\(one.recipientReaches) for a show with 1, so this counts rows walked rather "
                        + "than reaches and would move with the store's contact spread as well as with "
                        + "the code (L63)."))
        #expect(two.recipientReaches == one.recipientReaches * 2,
                "two cards must cost twice one card, or this cannot judge a change that builds fewer")
    }

    // The L96 half: a new reach added later must go through the counted accessor, or the pin above
    // silently stops covering it. A hand-maintained list of call sites is exempt from exactly the thing
    // it is written to catch.
    @Test("the card build reaches for contacts only through the counted accessor")
    func theCardBuildCannotReachTheContactsUncounted() throws {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        // #3653: the initialiser gained a `contacts:` parameter (the render pass reads them once and
        // hands the same array to the row and the card), so the marker is the signature's CLOSING line
        // rather than its opening one. Still signature-pinned, and deliberately so: a marker that stops
        // mid-signature would start the brace scan inside the parameter list, which is the hollow-guard
        // shape `SourceGuardMarkerIntegrityTests` exists to refuse (L70).
        let opening = "contacts: [Recipient]? = nil) {"
        let start = try #require(model.range(of: opening),
                                 "the card initialiser is gone, so this guard is about nothing (L98)")
        let rest = model[start.upperBound...]
        let close = try #require(rest.range(of: "\n    }"))
        let body = String(rest[..<close.lowerBound])

        #expect(!body.contains("p.recipients"),
                Comment(rawValue: "the card build reads `p.recipients` directly, so that reach is not "
                        + "counted and the pin above no longer measures what a card costs. Go through "
                        + "`p.countedRecipients` (L96: a guard driven by a hand-written registry checks "
                        + "only what the registry lists)."))
        #expect(body.contains("countedRecipients"),
                "the card build no longer reaches for the contacts at all, so the pin is about nothing")
        // #3653: and the handed-in arm is the SAME array, never a second read dressed as a fallback.
        #expect(body.contains("contacts ?? p.countedRecipients"),
                Comment(rawValue: "the card no longer takes the contacts the render pass already read, "
                        + "so a pass that builds a row and a card walks every show's contacts twice"))
    }

    // AND ONLY ONCE. The pin above says how many reaches happen at run time; this says the card build
    // holds ONE binding rather than a dozen, so a reader can see the rule at the call site rather than
    // having to run the suite to discover it. Kept as a second, cheaper net and named as one: the pin is
    // the proof (L63).
    @Test("the card build faults the contacts exactly once")
    func theCardBuildBindsTheContactsOnce() throws {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        // #3653: the initialiser gained a `contacts:` parameter (the render pass reads them once and
        // hands the same array to the row and the card), so the marker is the signature's CLOSING line
        // rather than its opening one. Still signature-pinned, and deliberately so: a marker that stops
        // mid-signature would start the brace scan inside the parameter list, which is the hollow-guard
        // shape `SourceGuardMarkerIntegrityTests` exists to refuse (L70).
        let opening = "contacts: [Recipient]? = nil) {"
        let start = try #require(model.range(of: opening),
                                 "the card initialiser is gone, so this guard is about nothing (L98)")
        let rest = model[start.upperBound...]
        let close = try #require(rest.range(of: "\n    }"))
        let body = String(rest[..<close.lowerBound])

        let reaches = body.components(separatedBy: "p.countedRecipients").count - 1
        #expect(reaches == 1,
                Comment(rawValue: "the card build reaches for the contacts \(reaches) times in source. "
                        + "One binding is what makes `recipientReaches` count FAULTS rather than reads, "
                        + "which is the only thing that lets the pin notice a second fault the split "
                        + "adds. It is not a cost claim: driving this from twelve to one was measured "
                        + "and changed nothing."))
    }

}
