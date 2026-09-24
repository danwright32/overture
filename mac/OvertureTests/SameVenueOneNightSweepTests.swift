import Testing
import Foundation
import SwiftData

// #3330: the half of the would-have-matched report that does not exist yet.
//
// #3330 wants the same-night rule applied BEFORE a row is written, so a show listed twice is never
// stored twice. Its direction says to measure the rule as a would-have-matched report first, and half
// of that is already shipped: `TwoShowsOneTitleOneNightTests` sweeps the store through the same
// predicate and reports 3 pairs on 2026-09-20, all judged and all correct.
//
// That sweep carries `guard leftRoom != rightRoom else { continue }`. It looks ONLY at pairs at
// DIFFERENT venues, because it was written for #1847, whose question was the risk #1761 introduced by
// making the merge venue blind. Every pair #3330 is about is at the SAME venue: the six Players Theatre
// groups share one venue string and one `sourceIds` entry and differ by host and billing. So the shipped
// sweep is silent on exactly the population an ingest rule would join, and quoting its clean result as
// evidence would be quoting a measurement of a different set (L107, L171).
//
// KEPT SEPARATE from that suite rather than widening it, deliberately. The two populations carry
// different risks and a single count would hide which one moved, and that suite's judged list is an
// answer to the cross-venue question specifically.
//
// WHAT A WRONG ANSWER COSTS HERE, which is why the bar is higher than the one the merge already passed.
// The launch merge deletes a row Dan can SEE, and it logs what it did. Refusing to INSERT loses a show
// that never reached a screen and leaves nothing to look at, so a false positive here is invisible by
// construction. That asymmetry is the whole reason this is measured before anything is built.
@MainActor
@Suite("Same venue, one night, two billings (#3330)")
struct SameVenueOneNightSweepTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreExists: Bool { LiveStoreClone.liveStoreURL != nil }

    private struct Candidate {
        var night: String
        var a: Prospect
        var b: Prospect
        var line: String {
            "\(night)  \(a.groupName) @ \(a.venue ?? "?")  ||  \(b.groupName) @ \(b.venue ?? "?")"
        }
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    // The mirror of `crossVenueCandidates`, with the venue guard INVERTED: same folded room, not a
    // different one. Everything else is identical on purpose, `isSameNightVariant` included, because that
    // is exactly what `SameNightTitleVariantMerge.clusters` calls and a near neighbour of it would
    // measure a rule nobody ships (the mistake that suite's own header records making twice).
    private func sameVenueCandidates(_ rows: [Prospect]) -> [Candidate] {
        var byNight: [String: [Prospect]] = [:]
        for row in rows {
            guard let night = row.performanceDate else { continue }
            byNight[night, default: []].append(row)
        }
        var out: [Candidate] = []
        for (night, sameNight) in byNight where sameNight.count > 1 {
            for (index, left) in sameNight.enumerated() {
                for right in sameNight[(index + 1)...] {
                    let leftRoom = VenueNormalization.normalizeForKey(left.venue ?? "")
                    let rightRoom = VenueNormalization.normalizeForKey(right.venue ?? "")
                    guard leftRoom == rightRoom else { continue }
                    guard GroupNameMatch.isSameNightVariant(left.groupName, right.groupName)
                    else { continue }
                    out.append(Candidate(night: night, a: left, b: right))
                }
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theStoreHoldsNoSameVenuePairAnIngestRuleWouldWronglyRefuse() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "same-venue-one-night")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                Issue.record("the live store exists but could not be cloned, so nothing was swept")
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let candidates = sameVenueCandidates(all)

            print("""
            Same venue one night corpus: \(all.count) row(s), \
            \(candidates.count) same-venue pair(s) an ingest rule would join
            \(candidates.map { "  " + $0.line }.joined(separator: "\n"))
            """)

            // THE JUDGEMENT, recorded rather than re-made, in the shape the cross-venue sweep uses. A pair
            // NOT listed here has never been looked at, and the cost of guessing is a show that never
            // reaches the screen, so it fails and names itself.
            //
            // Both were read on 2026-09-20 and both are ONE show. Each is also something more useful
            // than that, which is why the reasons are here rather than a bare list.
            //
            // BOTH PAIRS SHARE AN IDENTICAL `sourceListingURL`, so they are the population
            // `matchByStableSource` already exists for, not a population needing a new rule. And both
            // predate that arm's title test by eight weeks: all four rows were first seen between
            // 2026-07-18 and 2026-07-24, while #4032 and #3917 shipped on 2026-09-19. So they are
            // residue, and they are NOT evidence that today's chain would mint them. What they cannot
            // show is why the arm missed them in July, because both pairs have been re-scouted since and
            // their current field values are not the ones the arm was given then (L277).
            // #4067: keyed on WHAT WAS JUDGED rather than on the rows' natural keys, which every re-key
            // arm in this milestone rewrites out from under a settled verdict. See `JudgedPair`.
            let judged: Set<JudgedPair> = [
                // One act, billed with and without a space before the plus, on one night at one room.
                // The venue strings differ only by the address the second listing appends, which
                // VenueNormalization folds away, so this pair is also a small proof that the fold is
                // doing its job.
                // WRITE THESE FROM THE VERDICT KEY THE FAILURE PRINTS, never from the stored natural
                // key. The first attempt here copied the fragments out of `ZNATURALKEY` and every entry
                // missed: the key's title is folded by TODAY'S fold rather than the one that wrote the
                // row, and its venue keeps its case while the stored key does not. Both pairs below came
                // out of the `verdict key:` line this test prints when a pair is unjudged.
                JudgedPair(foldedTitles: ["macmccarty kiddtwist", "macmccarty kiddtwist"],
                           night: "2026-07-23", venues: ["Jalopy Theatre", "Jalopy Theatre"]),
                // One show, billed once with the artists in a parenthetical. This is the exact shape
                // `GroupNameMatch.isSameShowTitle` was given in #3917: a title against that title plus
                // a subtitle, corroborated by a shared listing URL.
                JudgedPair(foldedTitles: ["kinstillatory mappings in light and dark matter",
                                          "kinstillatory mappings in light and dark matter emily johnson and kai recollet"],
                           night: "2026-09-17", venues: ["Abrons Arts Center", "Abrons Arts Center"]),
                // Judged 2026-09-21 in PR #4118. One concert billed two ways, the programme title against the
                // performer billing. Evidence is not the titles, which could be two recitals: BOTH ROWS
                // CARRY THE SAME KAUFMAN MUSIC CENTER PAGE, differing only by a TRAILING SLASH
                // (`.../orli-shaham-in-claras-hands` against `.../orli-shaham-in-claras-hands/`), so the
                // source itself says they are one event.
                //
                // That slash is also why the pair exists at all. `matchByStableSource` compares the
                // listing URL EXACTLY, so a trailing slash defeats it and the second billing was inserted
                // as its own row eight weeks after the first. Filed as its own defect; this entry only
                // records the verdict.
                JudgedPair(foldedTitles: ["orli shaham in clara s hands", "orli shaham piano"],
                           night: "2026-10-06", venues: ["Merkin Hall", "Merkin Hall"]),
                // Judged 2026-09-24. One concert, and the evidence here is WEAKER than every entry above
                // it, which is why the reason says what it rests on rather than asserting the verdict.
                //
                // The three pairs above are all corroborated by the two rows sharing a listing URL, so
                // the source itself says they are one event. THESE TWO DO NOT SHARE ONE. What the store
                // holds is two carnegiehall.org listings for the same night:
                //   .../2027/01/18/the-music-of-sir-karl-jenkins-0700pm
                //   .../2027/01/18/dciny-the-music-of-sir-karl-jenkins-celebrating-jonathan-griffith-0700pm
                // captured 2.85 days apart, the second later.
                //
                // WHY THERE ARE TWO IS NOT ESTABLISHED, and an earlier draft of this comment said it was.
                // It claimed Carnegie "publishes them as separate pages". The store cannot show that. A
                // retitled listing whose slug moved with its title produces exactly this record, and so
                // does a calendar carrying two pages, and nothing here distinguishes them: neither URL
                // was fetched. Either way `matchByStableSource` compares the listing URL exactly, so the
                // second billing was inserted as its own row (L192: a fact inferred from content must
                // not be recorded as the fact it stands for).
                //
                // A THIRD ROW for this night is NOT part of this pair and is not a defect. Dan watches
                // the Carnegie calendar and DCINY's calendar as separate sources (his note, 2026-09-24),
                // so `Jenkins: The Armed Man; Jenkins: Gloria` from dciny.org is the expected overlap of
                // two watched sources rather than a duplicate either one produced.
                //
                // What joins them is the room and the clock: same night, same Stern Auditorium, both
                // billed at 0700pm in their own URLs, same presenter (DCINY). Two concerts cannot both
                // open at seven in that room, so one event is billed twice, most likely a programme
                // title and a fuller billing of the same evening. Dan's call on that reading, this
                // session in chat.
                //
                // WHAT THIS DOES NOT ESTABLISH, said because the next person will reach for this entry
                // as a precedent: it is not evidence that `isSameNightVariant` would be SAFE to build an
                // ingest rule on for pairs like this. A rule keyed on the title alone would have joined
                // these two, and it would have been right here by luck of the clock rather than by
                // anything in the titles (L192, L203). #3330 still needs the corroboration question
                // answered separately.
                JudgedPair(foldedTitles: ["dciny the music of sir karl jenkins celebrating jonathan griffith",
                                          "the music of sir karl jenkins"],
                           night: "2027-01-18",
                           venues: ["Stern Auditorium / Perelman Stage",
                                    "Stern Auditorium / Perelman Stage"]),
            ]

            let unjudged = candidates.filter {
                !judged.contains(JudgedPair.of($0.a, $0.b, night: $0.night))
            }

            #expect(unjudged.isEmpty, Comment(rawValue: """
                \(unjudged.count) same-venue same-night pair(s) would be joined by an ingest rule built \
                on isSameNightVariant, and none has been judged. Read each and record it with a reason, \
                or #3330 cannot be built on this predicate:
                \(unjudged.map { "  " + $0.line + "\n    verdict key: " + JudgedPair.of($0.a, $0.b, night: $0.night).description }.joined(separator: "\n"))
                """))

            // The clone is NOT removed here: #4061 is three suites doing exactly that while the context
            // still holds the file open, which SQLite reports as an integrity violation on every run.
            // TemporarySandboxes owns the directory and cleans it up after this returns.
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
