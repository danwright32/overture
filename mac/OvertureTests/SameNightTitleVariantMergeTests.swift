import Testing
import Foundation
import SwiftData

// #1590 part two. The natural-key title fold (TitleNormalization) collapses one show whose titles differ
// only by punctuation, because a canonical fold is a FUNCTION and can feed a unique key. It cannot touch
// the other half of the live duplication: one show BILLED two ways on the same night, where the titles
// differ by real words ("FRIGID Nightcap" versus "FRIGID Nightcap: FUTURE TENSE"). That is a similarity
// judgment, so it lives here, in a pass that deletes rows under the same safety rules #1064 and #1559 use.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="same-night same-venue groups whose titles are a confident name match but differ by real words, and the duplicate cards they cost"
// Measured on the live store 2026-07-27: 7 such groups, 8 duplicate cards, on top of the fold's 10.
@MainActor
@Suite("Same-night title variant merge (#1590)")
struct SameNightTitleVariantMergeTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, _ group: String, date: String?, venue: String,
                        ingestedAt: TimeInterval = 1_000,
                        configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(date ?? "")|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // The live shape: one show, two billings, one night, one room.
    @Test func oneShowBilledTwoWaysOnOneNightCollapsesToOneCard() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks", ingestedAt: 1_000)
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(all(ctx).count == 1)
    }

    // The venue half uses the SAME fold as the key, so a row carrying the street address still counts as
    // the same room. Both spellings are live in the store for this venue.
    @Test func theVenueHalfIsFoldedSoAnAddressSpellingStillMatches() throws {
        let ctx = try context()
        insert(ctx, "Fleetwood Mac: Stripped", date: "2026-09-23", venue: "The Cutting Room")
        insert(ctx, "Fleetwood Mac: Stripped (Broadway Sings)", date: "2026-09-23",
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 1)
    }

    // Three billings of one burlesque night, the widest live group.
    @Test func threeBillingsOfOneNightCollapseToOneCard() throws {
        let ctx = try context()
        insert(ctx, "Sins and Stardust Burlesque: Tribute to the Ruby", date: "2026-08-31",
               venue: "Under St Marks", ingestedAt: 1_000)
        insert(ctx, "Sins and Stardust Burlesque: August 31st", date: "2026-08-31",
               venue: "Under St Marks, 94 St Marks Pl, New York, NY 10009", ingestedAt: 2_000)
        insert(ctx, "Sins and Stardust Burlesque: Tribute to the 80s", date: "2026-08-31",
               venue: "Under St Marks", ingestedAt: 3_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 2)
        #expect(all(ctx).count == 1)
    }

    // The guard that matters most. The Green Room 42 genuinely books two different shows most nights,
    // right through the live store, and those are two real cards Dan has to see.
    @Test func twoDifferentActsOnOneNightAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "Bite Me", date: "2026-07-29", venue: "The Green Room 42")
        insert(ctx, "A Tom Lehrer Cabaret", date: "2026-07-29", venue: "The Green Room 42",
               ingestedAt: 2_000)

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // Two nights of one show are a RUN, not a duplicate. This pass is same-night only; widening it to a
    // date range would delete the second night of a run Dan can still shoot.
    @Test func thesameShowOnTwoDifferentNightsIsLeftAlone() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks")
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-08-01", venue: "Under St Marks",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2)
    }

    // An undated listing has no night to share, so it can never be a same-night duplicate.
    @Test func undatedRowsAreNeverMerged() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: nil, venue: "Under St Marks")
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: nil, venue: "Under St Marks",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2)
    }

    // Failure path, same rule as #1064 and #1559: when two rows both carry real outreach history, merging
    // would move a sent email onto the wrong show. Leave both, delete nothing, count the conflict.
    @Test func twoBillingsThatBothCarryHistoryAreLeftAloneAndCounted() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks") {
            $0.sentAt = Date(timeIntervalSince1970: 9_000)
        }
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000) { $0.draftBody = "a draft Dan has already read" }

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // The row holding Dan's own decision survives, whichever order the rows arrived in.
    @Test func theRowCarryingDansDecisionIsTheSurvivor() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks", ingestedAt: 1_000)
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000) { $0.confidenceReviewedByDan = true }

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).map(\.groupName) == ["FRIGID Nightcap: FUTURE TENSE"])
    }

    // A reachability check costs real money and real minutes. A probe that came back "no email found"
    // leaves no recipients behind, so it does not read as outreach history, and a naive merge would
    // delete the row that HOLDS the paid answer and keep the unprobed one, silently re-offering the
    // check. The probed row survives.
    // The probed row is deliberately the LATER-ingested one here, so the fallback survivor rule (oldest
    // wins) would pick the unprobed row and throw the answer away. Only the probe rule saves it, which is
    // what makes this test able to fail.
    @Test func aProbedRowOutranksAnUnprobedOneSoNoPaidAnswerIsThrownAway() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks", ingestedAt: 1_000)
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000) {
            $0.reachabilityProbedAt = Date(timeIntervalSince1970: 8_000)
            $0.reachabilityResult = .noEmailFound
        }

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let remaining = all(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.reachabilityProbedAt != nil,
                "the paid answer must outlive the merge")
    }

    // Idempotent: a second pass over an already-collapsed store is a no-op. This runs at every launch,
    // so a pass that could keep deleting would eat the queue one launch at a time.
    @Test func asecondPassChangesNothing() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks")
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()
        let second = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(second.duplicatesDeleted == 0)
        #expect(second.conflictsDeferred == 0)
        #expect(all(ctx).count == 1)
    }

    // #1845: an address a paid check FOUND, that nobody has written to, is a lookup result and not a
    // fact about the outside world, so it must not wedge one show into the queue twice forever.
    //
    // LIVE-STORE-CLAIM verified=2026-08-03 measure="same-night same-title groups whose copies disagree about the fit score, and what each copy holds"
    // Measured on the live store: all four surviving groups defer here, three of them for exactly this
    // reason, and Dan sees each of those shows twice at two different ranks (2 against 10). None of the
    // nine rows involved has ever been sent anything: no send date, no mail thread, no draft.
    @Test func afoundAddressNobodyWroteToDoesNotBlockTheMerge() throws {
        let ctx = try context()
        let first = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                           venue: "Greely Square", ingestedAt: 1_000)
        first.recipients.append(Recipient(id: "hello@golden.example", email: "hello@golden.example",
                                          provenance: .presenter))
        let second = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                            venue: "Greeley Square", ingestedAt: 2_000)
        second.recipients.append(Recipient(id: "info@jalopy.example", email: "info@jalopy.example",
                                           provenance: .presenter))
        try? ctx.save()

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(summary.conflictsDeferred == 0)
        #expect(all(ctx).count == 1)
    }

    // The other side of the same rule, and the one that must never move: once anybody has actually been
    // written to, the row records something that happened outside Overture. Merging then moves a real
    // email onto the wrong show, so the pair is left exactly as it is.
    @Test func anaddressThatWasActuallyWrittenToStillBlocksTheMerge() throws {
        let ctx = try context()
        let first = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                           venue: "Greely Square", ingestedAt: 1_000)
        let contacted = Recipient(id: "hello@golden.example", email: "hello@golden.example",
                                  provenance: .presenter)
        contacted.sentAt = Date(timeIntervalSince1970: 9_000)
        contacted.gmailMessageId = "msg-1"
        contacted.sendState = .sent
        first.recipients.append(contacted)
        let second = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                            venue: "Greeley Square", ingestedAt: 2_000)
        second.recipients.append(Recipient(id: "info@jalopy.example", email: "info@jalopy.example",
                                           provenance: .presenter))
        try? ctx.save()

        let summary = SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(all(ctx).count == 2)
    }

    // #2001, Dan's call (2026-08-03): "make it so that the one that has no decision stays. it's not about
    // the contact list, it's that I may have made a decision based on insufficient information. so give me
    // another chance to look at it." So when one copy carries a refusal and the other carries none, the
    // UNDECIDED copy survives and the show returns to the queue for a second look. He chose a genuinely
    // clean look over a card that remembers: the refusal goes with the row it was on.
    @Test func arefusedCopyMakesWayForTheUndecidedOneSoTheShowComesBack() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks", ingestedAt: 1_000) {
            $0.status = .dismissed
            $0.dismissReasonRaw = "too_soon"
        }
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let remaining = all(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.status == .new, "the show must come back for another look")
        #expect(remaining.first?.dismissReasonRaw == nil)
    }

    // The line that does NOT move. A refusal is Dan's judgment and can be revisited; a sent email is a
    // fact about the outside world. So a row that reached it survives even against an undecided copy,
    // because deleting it would destroy the record of what was actually sent.
    @Test func arowThatReachedTheOutsideWorldStillOutranksAnUndecidedCopy() throws {
        let ctx = try context()
        insert(ctx, "FRIGID Nightcap", date: "2026-07-31", venue: "Under St Marks", ingestedAt: 1_000) {
            $0.sentAt = Date(timeIntervalSince1970: 9_000)
            $0.gmailMessageId = "msg-1"
            $0.status = .contacted
        }
        insert(ctx, "FRIGID Nightcap: FUTURE TENSE", date: "2026-07-31", venue: "Under St Marks",
               ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let remaining = all(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.gmailMessageId == "msg-1", "the sent record must never be deleted")
    }

    // #1845, Dan's call (2026-08-03): when the merge may now collapse two copies that each hold found
    // addresses, the one Dan keeps must be the copy with the better contact list, because the other
    // copy's addresses go with it and only a fresh paid check would bring them back.
    // The richer row is deliberately the LATER-ingested one, so the oldest-wins fallback would pick the
    // thinner list and this test can actually fail.
    @Test func thesurvivorKeepsTheBetterContactList() throws {
        let ctx = try context()
        let thin = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                          venue: "Greely Square", ingestedAt: 1_000)
        thin.recipients.append(Recipient(id: "info@venue.example", email: "info@venue.example",
                                         provenance: .presenter))
        let rich = insert(ctx, "The Golden Hour Series: Vaden Landers", date: "2026-09-17",
                          venue: "Greeley Square", ingestedAt: 2_000)
        rich.recipients.append(Recipient(id: "act@band.example", email: "act@band.example",
                                         provenance: .act))
        rich.recipients.append(Recipient(id: "manager@band.example", email: "manager@band.example",
                                         provenance: .performer))
        try? ctx.save()

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let remaining = all(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.recipients.count == 2,
                "the copy holding two found contacts must be the one that survives")
    }
}
