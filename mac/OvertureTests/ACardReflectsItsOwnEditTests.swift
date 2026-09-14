import Testing
import Foundation

// #2598: striking an address off a card waited for the whole queue to rebuild.
//
// A close-out makes the whole ROW leave, so #2417 could start the row leaving on the press and let the
// write and the rebuild happen behind the animation: `SendProgressState.depart` already held a snapshot
// of a leaving row, so there was somewhere for the departing card to come from.
//
// Striking an address removes ONE LINE from a card that STAYS. There is no departure to mark and no
// snapshot to draw from: the card is rebuilt from the store's answer, so until the write lands and the
// rebuild finishes, the address Dan just struck is still drawn. Measured 2026-09-06 on a hosted
// QueueView at the live shape, that wait is 860 ms (`FeltWaitCostTests`), and a control that does
// nothing visible for that long reads as broken and gets pressed again (L44).
//
// The issue offered two fixes and its own measurement chose the second: caching the whole-corpus
// derivations is worth at most 15% of a rebuild, while the cost is the per-card construction, so
// anything that rebuilds all 1,142 cards to change one line pays it whatever is cached above.
@Suite("A card reflects its own edit before the rebuild lands (#2598)")
struct ACardReflectsItsOwnEditTests {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    @MainActor private func state() -> SendProgressState { SendProgressState() }

    @Test("an address is struck the moment it is marked")
    @MainActor func anAddressIsStruckAtOnce() {
        let s = state()
        let key = SendProgressState.strikeKey(show: "row-1", email: "a@example.com")
        #expect(!s.isStruck(key, now: now))
        s.strike(key, at: now)
        #expect(s.isStruck(key, now: now))
    }

    // ONE address on TWO shows. Keyed on the address alone, striking it here would blank it on a card Dan
    // never touched, and an address really can sit on two shows: a venue's programming inbox is on every
    // show at that venue.
    @Test("striking an address on one show leaves the same address on another alone")
    @MainActor func theKeyIsTheShowAndTheAddress() {
        let s = state()
        let here = SendProgressState.strikeKey(show: "row-1", email: "programming@example.com")
        let there = SendProgressState.strikeKey(show: "row-2", email: "programming@example.com")
        s.strike(here, at: now)

        #expect(s.isStruck(here, now: now))
        #expect(!s.isStruck(there, now: now),
                "the same address on another show was struck too, so one press blanked a card Dan never touched")
    }

    // The CEILING, which is the whole of what limits a mark nothing clears. Without it a write that failed
    // would leave the address hidden for the rest of the session, which is worse than the wait it replaces
    // because the card would then be lying about what the store holds.
    @Test("a strike whose write never landed comes back")
    @MainActor func aStrikeAgesOut() {
        let s = state()
        let key = SendProgressState.strikeKey(show: "row-1", email: "a@example.com")
        s.strike(key, at: now)

        let justInside = now.addingTimeInterval(SendProgressState.departureCeiling - 1)
        let past = now.addingTimeInterval(SendProgressState.departureCeiling + 1)
        #expect(s.isStruck(key, now: justInside))
        #expect(!s.isStruck(key, now: past),
                "a strike survives past the ceiling, so a write that failed hides the address for the session")
    }

    // NOTHING CLEARS IT ON A TIMER, and that is the decision worth pinning rather than the code that
    // implements it. The obvious clear, on the timing plan a departure uses, is WRONG here: a departure's
    // row leaves for good so a clear after the hold is invisible, while a struck address is hidden from a
    // card that STAYS, and the rebuild it covers for (860 ms) outlasts the hold (0.55 s). Clearing on the
    // plan would make the address FLASH BACK and then vanish again.
    @Test("the strike outlives the departure hold, because the rebuild does")
    @MainActor func theStrikeOutlivesTheDepartureHold() {
        let s = state()
        let key = SendProgressState.strikeKey(show: "row-1", email: "a@example.com")
        s.strike(key, at: now)

        let plan = SendDelightTiming.plan(reduceMotion: false)
        let afterTheHold = now.addingTimeInterval(plan.total)
        #expect(s.isStruck(key, now: afterTheHold),
                Comment(rawValue: "the address came back after the departure hold, which is shorter than the rebuild it is "
                + "covering for, so it would flash back and vanish again"))
    }

    @Test("a strike can be cleared outright, for an undo")
    @MainActor func aStrikeCanBeCleared() {
        let s = state()
        let key = SendProgressState.strikeKey(show: "row-1", email: "a@example.com")
        s.strike(key, at: now)
        s.finishStriking(key)
        #expect(!s.isStruck(key, now: now))
    }

    // The mark does not disturb the OTHER transient state on the same object, which is the risk of adding
    // a second dictionary to a type three surfaces read.
    @Test("striking an address changes nothing about a departure or a send")
    @MainActor func theMarkIsIndependentOfTheOthers() {
        let s = state()
        let item = QueueItem(id: "row-1", groupName: "Ensemble", discipline: "music",
                             venue: "Weill Recital Hall", performanceDate: nil, sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "neutral",
                             coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
        s.depart("row-1", as: item, because: .closedOut, at: now)
        s.markSending("row-1", at: now)

        s.strike(SendProgressState.strikeKey(show: "row-1", email: "a@example.com"), at: now)

        #expect(s.departure("row-1", now: now) != nil)
        #expect(s.sendingSince("row-1") == now)
    }
}

// The wiring, which is the half no value test can reach: `QueueView` cannot be evaluated in a unit test,
// so what is asserted here is the SHAPE, and it is the same shape #2417's own guard asserts one control
// over (`ClosingAPitchOutFromTheRowTests`).
@Suite("The card's own edit is wired the way the departure is (#2598)")
struct ACardReflectsItsOwnEditWiringTests {

    private var factory: String { SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift") }
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var rowView: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }
    private var wrapper: String { SourceGuardHelper.source("Overture/UI/QueueSendAwareViews.swift") }

    // THE ORDER IS THE FIX, not either half of it: marking after the write would put the line's
    // disappearance behind the rebuild it exists to hide.
    //
    // Each handler is named with a LITERAL marker rather than an interpolated one, and that is
    // `SourceGuardMarkerIntegrityTests`'s requirement rather than a style choice: it checks every
    // `propertyBody` marker in the suite against the source that guard reads, and a marker assembled at
    // run time matches nothing it can see, so the check meant to catch a marker that has stopped matching
    // would itself stop working (#2192, L1).
    private func markedBeforeTheWrite(_ handler: String, named name: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        guard let marked = handler.range(of: "markAddressStruck("),
              let written = handler.range(of: "ProspectMutations.") else {
            Issue.record(Comment(rawValue: "\(name) no longer both marks the address struck and writes. "
                                 + "Without the mark the line stays on the card until the rebuild lands "
                                 + "(#2598); without the write nothing happens at all."),
                         sourceLocation: sourceLocation)
            return
        }
        #expect(marked.lowerBound < written.lowerBound,
                Comment(rawValue: "\(name) marks the strike AFTER its write, so the screen still waits "
                        + "for the rebuild (#2417's order, one control over)"),
                sourceLocation: sourceLocation)
    }

    @Test("striking a researched contact marks it BEFORE the write")
    func removingARecipientMarksBeforeTheWrite() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "row", in: factory))
        let handler = try #require(SourceGuardHelper.propertyBody("onRemoveRecipient: {", in: body))
        markedBeforeTheWrite(handler, named: "onRemoveRecipient")
    }

    @Test("striking any address on the card marks it BEFORE the write")
    func removingAContactAddressMarksBeforeTheWrite() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "row", in: factory))
        let handler = try #require(SourceGuardHelper.propertyBody("onRemoveContactAddress: {", in: body))
        markedBeforeTheWrite(handler, named: "onRemoveContactAddress")
        // The mark sits AHEAD of the branch, so a researched contact and an inherited one cannot answer
        // differently about what the screen does (L16).
        let marked = try #require(handler.range(of: "markAddressStruck("))
        let branched = try #require(handler.range(of: "if let rid = address.recipientId"))
        #expect(marked.lowerBound < branched.lowerBound,
                "the mark is inside one arm of the branch, so one kind of address strikes and the other does not")
    }

    // ONE mechanism rather than an optimistic path per control, which is what the issue asks for by name:
    // "once, shared, rather than twenty-five optimistic paths that can each drift from what the write
    // really did".
    @Test("the two paths mark the same thing rather than each inventing a rule")
    func thereIsOneMechanism() {
        let marks = factory.components(separatedBy: "markAddressStruck(").count - 1
        #expect(marks == 2, "the factory marks a strike \(marks) times; two controls strike an address")
        #expect(!factory.contains("private var struckHere"),
                "a second local notion of a struck address has appeared beside the shared one")
    }

    // Read INSIDE the address's own row, which is what makes striking one address redraw that address
    // rather than the card, and what keeps the dependency below QueueView's derivation (#1922, #1916).
    @Test("the strike is read below the derivation, not at the call site")
    func theStrikeIsReadBelowTheDerivation() {
        #expect(wrapper.contains("_ isAddressStruck: @escaping (String) -> Bool"),
                Comment(rawValue: "the wrapper no longer hands the strike lookup down, so whoever wants it reads it in "
                + "QueueView's body, which is the dependency #1922 removed"))
        #expect(wrapper.contains("sendState.isStruck(SendProgressState.strikeKey(show: key, email: email))"))
        #expect(rowView.contains("item.displayedContactAddresses.filter { !isAddressStruck($0.email) }"),
                "the address list no longer hides a struck address, so the mark is written and never read")
    }

    // The DEFAULTS are the safe direction, which matters because every other surface that draws this row
    // takes them: one can only ever show what the store says, and the other does nothing at all.
    @Test("a surface with no transient state draws what the store says")
    func theDefaultsAreSafe() {
        #expect(rowView.contains("var isAddressStruck: (_ email: String) -> Bool = { _ in false }"))
        #expect(factory.contains("isAddressStruck: @escaping (String) -> Bool = { _ in false }"))
        #expect(factory.contains("markAddressStruck: @escaping (String) -> Void = { _ in }"))
    }

    // And the queue really passes them, or every guard above is about code nothing reaches (L3).
    @Test("the queue wires both halves")
    func theQueueWiresBothHalves() {
        #expect(queueView.contains("isAddressStruck: isAddressStruck,"))
        #expect(queueView.contains("sendState.strike(SendProgressState.strikeKey("))
        #expect(queueView.contains("replySince, isAddressStruck in"),
                Comment(rawValue: "the queue does not take the strike lookup from the wrapper, so it is reading it "
                + "somewhere else or not at all"))
    }
}
