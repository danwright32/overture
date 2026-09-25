import Testing
import Foundation
import SwiftData

// #4110: the follow-ups due count is rebuilt when it COULD have changed, not every two seconds.
//
// WHAT WAS MEASURED, and it is not what the issue's write-up infers. Dan changed one card's genre and the
// freeze log recorded 6.81s at 19:24:36Z and 6.45s at 19:24:42Z on a QUIET Mac (load 3.7). In the samples
// `RootView.followUpsDue` carried 9.1%, `DueWork.rows` 8.0%, `ProposedConversation.dueRecipients` 7.1%,
// `ProposedConversation.state(of:now:)` 7.0% and `ScopeMemo.value` 8.8%, so the memo was MISSING and
// paying its whole-store build.
//
// The write-up's explanation is that the build "runs under `withObservationTracking`, so ANY observed
// change to ANY prospect sets the stale flag, and an edit is precisely such a change". Driven against the
// code, that is false: `aGenreEditDoesNotRebuildTheCount` below writes `Prospect.discipline` through the
// shipping path and the memo holds, because observation tracking is per PROPERTY and `DueWork` never
// reads `discipline`. `aRelevantEditRebuildsTheCount` is the control that makes that reading mean
// something rather than being a memo that never invalidates at all (L159).
//
// What DOES rebuild it, on a store nothing has touched, is the two second TTL. That is the cost: the
// build is a whole-store sweep over every prospect and every recipient's conversation state, and it ran
// again on the first render pass more than two seconds after the last, which during any burst of activity
// is most of them. Two freezes six seconds apart is two expiries.
//
// THE FIX IS NOT A LONGER WINDOW. A window is the wrong shape for a derivation that can say when its own
// answer could next change, and this one can: `DueWork.nextChange` has answered "the earliest future
// moment at which a rule ALREADY IN PLAY comes due" since #3474, which built it for this very number.
// So the count now carries its own expiry and `ScopeMemo.Staleness.at` is how the memo is told it.
//
// AND THE EXPIRY IS WORKED OUT INSIDE THE BUILD. `nextChange` is itself a whole-store sweep, so asking it
// on the cheap path to decide whether the cheap path may be taken would cost exactly what the memo saves
// (L431). `DueWork.countAndNextChange` returns both from one pass for that reason, and because a count
// and the moment it stops being the answer are one fact rather than two (L544).
@MainActor
@Suite("The due count holds until it could have changed (#4110)")
struct DueCountHoldsUntilItCouldChangeTests {

    private static let corpusSize = 50
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Contacts on every row, with a send stamp, because `DueWork` reaches through `recipients` and a
    // corpus with none would short circuit before reading the fields these tests are about (L101).
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 5)", performanceDate: "2099-01-01",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: n % 10,
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil)
            ctx.insert(p)
            let r = Recipient(id: "person\(n)@example.test", email: "person\(n)@example.test",
                              provenance: .presenter)
            // SENT and silent, which is what puts a nudge on the list at all: `Recipient.isSilent` is
            // `sendState == .sent && !replied && !bounced`, and a contact that is merely stamped with a
            // `sentAt` is still `.pending` and nudges nobody. Without this the corpus produces no due
            // work, `nextChange` names no moment, and the expiry below cannot be exercised (L159).
            r.sendState = .sent
            // HALF already overdue and half not yet, which is the ordinary shape of the real list and the
            // only one that exercises both halves of this suite: the overdue ones make the count non
            // zero, and the recent ones give `nextChange` a future moment to name. A corpus where
            // everything is already due names no moment at all, because every rule's instant has passed.
            r.sentAt = Self.now.addingTimeInterval(n % 2 == 0 ? -30 * 86_400 : -2 * 86_400)
            p.addRecipient(r)
            out.append(p)
        }
        return out
    }

    // EXACTLY what `RootView.followUpsDue` does, so what is measured is the shipping shape rather than a
    // rig that happens to agree with it (L472). The one thing it cannot carry is SwiftUI's own `@State`,
    // which changes nothing about the memo.
    @discardableResult
    private func read(_ memo: ScopeMemo<DueWork.CountAndNextChange>, prospects: [Prospect],
                      inquiries: [Inquiry], now: Date) -> Int {
        var fingerprint = ScopeFingerprint()
        fingerprint.add(prospects)
        fingerprint.add(inquiries)
        fingerprint.add(value: false)
        let staleAfter: ScopeMemo<DueWork.CountAndNextChange>.Staleness =
            memo.held.flatMap(\.couldChangeAt).map { .at($0) } ?? .never
        return memo.value(fingerprint: fingerprint.finalized(), cardKeys: [], now: now,
                          staleAfter: staleAfter, savesIn: nil) {
            DueWork.countAndNextChange(prospects: prospects, inquiries: inquiries, now: now,
                                       replyRunAlive: false)
        }.total
    }

    // MARK: - The controls, first, because every claim below is a build count that did not move

    // Without this, a memo that never invalidated at all would satisfy every other test here, and that
    // would be a far worse defect than the one under repair (L159, L98).
    @Test("a change the count IS derived from rebuilds it")
    func aRelevantEditRebuildsTheCount() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let memo = ScopeMemo<DueWork.CountAndNextChange>()

        read(memo, prospects: rows, inquiries: [], now: Self.now)
        #expect(memo.builds == 1)
        rows[7].recipients.first?.sentAt = Self.now.addingTimeInterval(-400 * 86_400)
        read(memo, prospects: rows, inquiries: [], now: Self.now)

        #expect(memo.builds == 2, Comment(rawValue:
            "the count did not rebuild after a change to the very field it is derived from, so it never "
            + "invalidates and every other test in this suite is vacuous"))
    }

    // The fixture really produces work, so every "it did not rebuild" below is about a count that had
    // something to count. A corpus with nothing due would make the whole suite vacuous (L98).
    @Test("the corpus really has follow-ups due, and a moment when more come due")
    func theCorpusIsNotEmpty() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let both = DueWork.countAndNextChange(prospects: rows, inquiries: [], now: Self.now,
                                              replyRunAlive: false)
        #expect(both.total > 0, Comment(rawValue:
            "the corpus has nothing due at all, so the memo under test is holding a zero and this suite "
            + "measures nothing"))
        #expect(both.couldChangeAt != nil, Comment(rawValue:
            "the corpus names no future moment, so the expiry cannot be exercised and the hold tests "
            + "would pass over a memo that simply never expires"))
    }

    // MARK: - The claim

    @Test("a quiet store does not rebuild the count as the clock moves")
    func theClockAloneDoesNotRebuildIt() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let memo = ScopeMemo<DueWork.CountAndNextChange>()

        read(memo, prospects: rows, inquiries: [], now: Self.now)
        #expect(memo.builds == 1)
        // Well past the two second window that used to expire it, and nothing about the store has moved.
        read(memo, prospects: rows, inquiries: [], now: Self.now.addingTimeInterval(2.5))
        read(memo, prospects: rows, inquiries: [], now: Self.now.addingTimeInterval(30))

        #expect(memo.builds == 1, Comment(rawValue:
            "the count was rebuilt \(memo.builds) times on a store nothing touched, so every render pass "
            + "more than two seconds after the last one still pays a whole-store sweep (#4110)"))
    }

    // The issue's own stated cause, checked rather than assumed. It does not hold, and the test says so
    // in its name so nobody re-derives the wrong explanation from a green suite.
    @Test("an edit the count is not derived from does not rebuild it")
    func aGenreEditDoesNotRebuildTheCount() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let memo = ScopeMemo<DueWork.CountAndNextChange>()

        read(memo, prospects: rows, inquiries: [], now: Self.now)
        #expect(memo.builds == 1)
        // Through the shipping writer, which is the only thing allowed to set a genre.
        GenreVisibility.write(.music, to: rows[7])
        read(memo, prospects: rows, inquiries: [], now: Self.now)

        #expect(memo.builds == 1, Comment(rawValue:
            "a genre change rebuilt the due count, which reads every prospect and every recipient's "
            + "conversation state and never reads a discipline"))
    }

    // AND IT STILL EXPIRES, which is the half a longer window would have bought at the cost of showing a
    // stale number. The moment is the derivation's own.
    @Test("the count expires at the instant it says it could change")
    func itExpiresAtItsOwnNextChange() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let memo = ScopeMemo<DueWork.CountAndNextChange>()

        read(memo, prospects: rows, inquiries: [], now: Self.now)
        let moment = try #require(memo.held?.couldChangeAt, Comment(rawValue:
            "this corpus names no future moment at all, so it cannot exercise the expiry and the test "
            + "above would pass over a memo that simply never expires"))
        #expect(moment > Self.now)

        // One instant before, still held.
        read(memo, prospects: rows, inquiries: [], now: moment.addingTimeInterval(-1))
        #expect(memo.builds == 1)
        // At it, rebuilt.
        read(memo, prospects: rows, inquiries: [], now: moment)
        #expect(memo.builds == 2, Comment(rawValue:
            "the count was still being served at the instant it said it could change, so the badge can "
            + "show a number that is no longer true"))
    }

    // MARK: - The wiring, because built is not wired (L3)

    // Every test above drives the SHAPE `RootView.followUpsDue` has, not `RootView` itself, so all of
    // them would stay green over a badge still asking for a two second window. This is the half that
    // says the shipping surface takes the new one.
    @Test("the shipped badge takes its staleness from the count's own next change")
    func theShippedBadgeUsesItsOwnExpiry() {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!source.isEmpty, "RootView could not be read, so this guard checked nothing")
        #expect(source.contains("followUpsMemo.held.flatMap(\\.couldChangeAt).map { .at($0) } ?? .never"),
                Comment(rawValue:
                    "the due badge no longer takes its expiry from the count's own next change, so it is "
                    + "back on a fixed window and a quiet store pays a whole-store sweep again (#4110)"))
        #expect(source.contains("DueWork.countAndNextChange("), Comment(rawValue:
            "the badge builds its count without the moment beside it, so whatever decides the memo's "
            + "expiry is a second derivation the cheap path has to pay for (L431)"))
        // The shape that must not come back: the count alone, which carries no expiry and therefore
        // forces a window.
        #expect(!source.contains("DueWork.counts(prospects: allProspects"))
    }

    // MARK: - The pieces underneath

    @Test("the count and the moment come from one pass over one store")
    func bothHalvesAgreeWithTheirOwnSources() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let both = DueWork.countAndNextChange(prospects: rows, inquiries: [], now: Self.now,
                                              replyRunAlive: false)
        #expect(both.total == DueWork.counts(prospects: rows, inquiries: [], now: Self.now,
                                             replyRunAlive: false).total)
        #expect(both.couldChangeAt == DueWork.nextChange(prospects: rows, now: Self.now,
                                                         replyRunAlive: false))
    }

    // `.at` on its own, so all three staleness shapes are produced rather than reasoned about (L151).
    @Test("the at staleness expires at its instant and not before")
    func theAtStalenessExpiresAtItsInstant() {
        let built = Self.now
        let moment = Self.now.addingTimeInterval(600)
        let staleness = ScopeMemo<Int>.Staleness.at(moment)
        #expect(!staleness.hasExpired(builtAt: built, now: moment.addingTimeInterval(-0.001)))
        #expect(staleness.hasExpired(builtAt: built, now: moment))
        #expect(staleness.hasExpired(builtAt: built, now: moment.addingTimeInterval(0.001)))
        // And it does not consult when the value was built, which is what separates it from `.seconds`.
        #expect(staleness.hasExpired(builtAt: moment.addingTimeInterval(-99_999), now: moment))
    }
}
