import Testing
import Foundation

// Milestone 62 Phase 1. One production stored as several rows renders as several cards, and each of
// those rows accrues feed misses on its own, so a show that is playing right now is struck through
// with "No longer in the feed, may be cancelled" because a SECOND row for it is the one the venue
// stopped listing (#3278). Measured on the live store 2026-09-19, 29 future rows carry that warning
// and 5 of them have a live twin under the same folded title, same venue and an intersecting night.
//
// ShowLink is the shared answer to "which rows are one show, for the purposes of DISPLAY". It is pure:
// no store, no I/O, no writes, and it never re-keys, merges or deletes anything. The ingest matcher
// arms own IDENTITY; this owns what a card SHOWS. Where they disagree the matcher wins on storage and
// ShowLink still groups whatever rows remain.
//
// The rule, and nothing else joins two rows automatically, ever:
//
//   Two rows are ONE SHOW when their folded titles are equal under the natural key's OWN fold, their
//   folded venues are equal under it, and EITHER their night sets intersect OR they share an opaque
//   stable production token.
//
// The counter-examples below are the point of the suite, not decoration. Each is a real pair from the
// live store, renamed, that a looser rule would fuse and lose.

private func row(_ id: String, _ title: String, venue: String?,
                 _ performanceDate: String?, runEndDate: String? = nil,
                 runNights: [String] = [], droppedNights: [String] = [],
                 sourceURLs: [String] = [], isStillInFeed: Bool = true) -> ShowLink.Row {
    ShowLink.Row(id: id, groupName: title, venue: venue, performanceDate: performanceDate,
                 runEndDate: runEndDate, runNights: runNights, droppedNights: droppedNights,
                 sourceURLs: sourceURLs, isStillInFeed: isStillInFeed)
}

// The ids sharing a group with `id`, sorted, so an assertion reads as a set rather than an order.
private func others(_ groups: [String: [String]], _ id: String) -> [String] {
    (groups[id] ?? []).sorted()
}

@Suite("Grouping the rows that are one show, for display (#3278, milestone 62)")
struct ShowLinkTests {

    // MARK: the night rule

    @Test func joinsTwoRowsOfOneRunThatShareANight() {
        // The live shape: pk 628 (a single night the venue's own schedule page published) and pk 998
        // (the same show as an OvationTix run that covers it).
        let out = ShowLink.group([
            row("a", "We Are Happy To Serve You", venue: "The Players Theatre", "2026-12-20"),
            row("b", "We Are Happy To Serve You", venue: "The Players Theatre", "2026-12-03",
                runEndDate: "2026-12-20"),
        ])
        #expect(others(out, "a") == ["b"])
        #expect(others(out, "b") == ["a"])
    }

    // The Tuudr counter-example, permanent. One folded title, one venue, twenty days apart, no shared
    // URL, no shared token, no shared night. A title-plus-venue-plus-gap rule fuses these and destroys
    // a real Carnegie show; this asserts it never happens.
    @Test func refusesOneTitleAtOneVenueOnNightsThatDoNotOverlap() {
        let out = ShowLink.group([
            row("oct11", "Tuudr Piano Competition Gala", venue: "Weill Recital Hall", "2026-10-11"),
            row("oct31", "Tuudr Piano Competition Gala", venue: "Weill Recital Hall", "2026-10-31"),
        ])
        #expect(out["oct11"] == nil)
        #expect(out["oct31"] == nil)
    }

    @Test func refusesOneTitleOnOneNightAtTwoDifferentVenues() {
        let out = ShowLink.group([
            row("asylum", "Open Mic", venue: "Asylum NYC", "2026-10-02"),
            row("cutting", "Open Mic", venue: "The Cutting Room", "2026-10-02"),
        ])
        #expect(out["asylum"] == nil)
        #expect(out["cutting"] == nil)
    }

    // The Infinite Wrench shape: A and C share nothing, and are one show because B bridges them. If the
    // closure stops doing the work, this splits into the pieces that remain.
    @Test func joinsThroughABridgingRowTransitively() {
        let out = ShowLink.group([
            row("a", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-02",
                runNights: ["2026-10-02", "2026-10-03"]),
            row("b", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-03",
                runNights: ["2026-10-03", "2026-10-09"]),
            row("c", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-09",
                runNights: ["2026-10-09"]),
        ])
        #expect(others(out, "a") == ["b", "c"])
        #expect(others(out, "c") == ["a", "b"])
    }

    @Test func removingTheBridgeBreaksTheGroupIntoWhatRemains() {
        let out = ShowLink.group([
            row("a", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-02",
                runNights: ["2026-10-02", "2026-10-03"]),
            row("c", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-09",
                runNights: ["2026-10-09"]),
        ])
        #expect(out["a"] == nil)
        #expect(out["c"] == nil)
    }

    // MARK: the folds, in the natural key's own composition

    // #1590's own case: a source respelling one show's title (an accent, an ellipsis character, a stray
    // comma) must not read as a different show, because the natural key already folds those away.
    @Test func foldsTheTitleTheWayTheNaturalKeyDoes() {
        let out = ShowLink.group([
            row("plain", "Cafe Mystere: An Evening", venue: "Asylum NYC", "2026-10-02"),
            row("fancy", "Café Mystère: An Evening!", venue: "Asylum NYC", "2026-10-02"),
        ])
        #expect(others(out, "plain") == ["fancy"])
    }

    // #1064's own case: a bare venue name and the same name with its street address appended are one
    // physical room, and the key folds them together.
    @Test func foldsTheVenueTheWayTheNaturalKeyDoes() {
        let out = ShowLink.group([
            row("bare", "Monday Night Magic", venue: "The Cutting Room", "2026-10-02"),
            row("addressed", "Monday Night Magic", venue: "The Cutting Room, 44 East 32nd Street",
                "2026-10-02"),
        ])
        #expect(others(out, "bare") == ["addressed"])
    }

    // The fold this suite exists to pin the ORDER of. `Prospect.makeNaturalKey` canonicalizes the title
    // BEFORE folding it and the venue AFTER, and a helper written from the plan's prose rather than from
    // the code drops the outer canonicalize on the venue (#3772, correction 6). Asserting the composed
    // string rather than a grouping outcome, because the grouping can agree by accident.
    @Test func theSharedFoldIsExactlyWhatTheNaturalKeyComposes() {
        let key = Prospect.makeNaturalKey(groupName: "Café Mystère: An Evening!",
                                          performanceDate: "2026-10-02",
                                          venue: "The Cutting Room, 44 East 32nd Street")
        let fields = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == 3)
        #expect(ShowLink.foldedTitle("Café Mystère: An Evening!") == fields[0])
        #expect(ShowLink.foldedVenue("The Cutting Room, 44 East 32nd Street") == fields[2])
    }

    // The NY Philharmonic bucket, live on the store: four different programmes under one presenter at
    // one hall. They are refused because the key fold KEEPS the subtitle, which is exactly why
    // GroupNameMatch.normalize (which strips it) is deliberately not used here.
    @Test func refusesFourProgrammesThatShareAPresenterAndAHall() {
        let out = ShowLink.group([
            row("mass", "City Philharmonic - Bernstein's MASS", venue: "Geffen Hall", "2026-09-16"),
            row("carmina", "City Philharmonic - Carmina Burana", venue: "Geffen Hall", "2026-09-16"),
        ])
        #expect(out["mass"] == nil)
        #expect(out["carmina"] == nil)
    }

    // MARK: the decisions the grouping must survive

    // Constraint 7. A group joined by EXACTLY ONE shared night, where Dan then drops that night, must
    // SURVIVE: the night is still in the dropped list, which is stored precisely so it outlives the
    // scout's re-fold. Otherwise a per-night decision silently splits a card back into fragments.
    @Test func aGroupSurvivesDanDroppingTheOneNightThatJoinedIt() {
        let out = ShowLink.group([
            row("anchor", "Gross Prophets", venue: "Asylum NYC", "2026-10-02",
                runNights: ["2026-10-03"], droppedNights: ["2026-10-02"]),
            row("sibling", "Gross Prophets", venue: "Asylum NYC", "2026-10-02",
                runNights: ["2026-10-02"]),
        ])
        #expect(others(out, "anchor") == ["sibling"])
    }

    // MARK: the stable production token

    @Test func joinsDisjointNightsThatShareAnOpaqueVenuetixToken() {
        let out = ShowLink.group([
            row("sep", "Nihao Broadway", venue: "The Green Room 42", "2026-09-11",
                sourceURLs: ["https://thegreenroom42.venuetix.com/showdetails/zGbL9oIm/111"]),
            row("oct", "Nihao Broadway", venue: "The Green Room 42", "2026-10-29",
                sourceURLs: ["https://thegreenroom42.venuetix.com/showdetails/zGbL9oIm/222"]),
        ])
        #expect(others(out, "sep") == ["oct"])
    }

    // A tixr slug is the title slugified plus a per-performance integer, so admitting it would let a
    // venue publishing open-mic-8814 and open-mic-9102 join two different nights of an open mic, which
    // is #1847 arriving inside its own fix.
    @Test func neverTreatsATixrSlugAsAProductionToken() {
        let out = ShowLink.group([
            row("a", "Open Mic", venue: "Asylum NYC", "2026-10-11",
                sourceURLs: ["https://www.tixr.com/groups/asylum/events/open-mic-8814"]),
            row("b", "Open Mic", venue: "Asylum NYC", "2026-10-29",
                sourceURLs: ["https://www.tixr.com/groups/asylum/events/open-mic-9102"]),
        ])
        #expect(out["a"] == nil)
        #expect(out["b"] == nil)
    }

    // The allowlist's OWN guard, and it exists because the test above cannot be it. A real tixr URL
    // carries no `/showdetails/` segment at all, so it is refused by the path shape whatever the host
    // rule says: removing the host check entirely leaves that test green (measured, `scripts/mutate.sh`
    // reported SURVIVED). This fixture is the one where the host is the ONLY thing refusing, so a
    // future widening of the allowlist by accident goes red (L159).
    @Test func neverReadsATokenFromAHostThatWasNeverMeasured() {
        let out = ShowLink.group([
            row("a", "Open Mic", venue: "Asylum NYC", "2026-10-11",
                sourceURLs: ["https://tickets.example.com/showdetails/sharedToken/111"]),
            row("b", "Open Mic", venue: "Asylum NYC", "2026-10-29",
                sourceURLs: ["https://tickets.example.com/showdetails/sharedToken/222"]),
        ])
        #expect(out["a"] == nil)
        #expect(out["b"] == nil)
    }

    // The cheap deterministic guard against a venue that stamps ONE token across its whole season. It
    // discards nothing on the live store today (209 distinct tokens over 211 rows), which is the point:
    // it costs nothing now and refuses the failure on the day a venue starts.
    @Test func discardsATokenThatAppearsUnderTwoTitlesAtOneVenue() {
        let url = "https://thegreenroom42.venuetix.com/showdetails/seasonToken/"
        let out = ShowLink.group([
            row("first-a", "First Show", venue: "The Green Room 42", "2026-10-11",
                sourceURLs: [url + "1"]),
            row("first-b", "First Show", venue: "The Green Room 42", "2026-10-29",
                sourceURLs: [url + "2"]),
            row("second", "Second Show", venue: "The Green Room 42", "2026-10-12",
                sourceURLs: [url + "3"]),
        ])
        #expect(out["first-a"] == nil)
        #expect(out["first-b"] == nil)
    }

    // MARK: the pairs it refuses, which are the ones Dan is asked about

    // A bucket whose members share a title and a venue but no night is not one show, and it is also not
    // nothing: it is the shape that is EITHER a fragmented production or two real galas under one name,
    // and only Dan can tell. So the refusals are returned rather than discarded, which is what #3282's
    // duplicate report is built from.
    @Test func reportsARefusedPairRatherThanDiscardingIt() {
        let refused = ShowLink.nearMisses([
            row("oct11", "Tuudr Piano Competition Gala", venue: "Weill Recital Hall", "2026-10-11"),
            row("oct31", "Tuudr Piano Competition Gala", venue: "Weill Recital Hall", "2026-10-31"),
        ])
        #expect(refused.count == 1)
        let ends: Set<String> = refused.first.map { [$0.a, $0.b] } ?? []
        #expect(ends == ["oct11", "oct31"])
    }

    // Two rows in DIFFERENT buckets were never candidates, so they are not a refusal either. Otherwise
    // the report fills with every pair of shows in the store.
    @Test func doesNotReportRowsThatWereNeverInOneBucket() {
        #expect(ShowLink.nearMisses([
            row("a", "One Show", venue: "Asylum NYC", "2026-10-11"),
            row("b", "Another Show", venue: "Asylum NYC", "2026-10-11"),
        ]).isEmpty)
    }

    // Gross Prophets on the live store: three rows at one venue, no two sharing a night, so three
    // groups and THREE pairs from one bucket. It is the reason the report is built per PAIR and never
    // one row per bucket, and the reason a bucket that partly joins still contributes refusals.
    @Test func reportsEveryRefusedPairInABucketNotOnePerBucket() {
        let refused = ShowLink.nearMisses([
            row("a", "Gross Prophets", venue: "Asylum NYC", "2026-10-02"),
            row("b", "Gross Prophets", venue: "Asylum NYC", "2026-10-09"),
            row("c", "Gross Prophets", venue: "Asylum NYC", "2026-10-16"),
        ])
        #expect(refused.count == 3)
    }

    // A pair the closure joined through a third row is not a near miss, even though the two of them
    // share no night directly. Otherwise the report asks Dan about rows already on one card.
    @Test func doesNotReportAPairTheClosureAlreadyJoined() {
        #expect(ShowLink.nearMisses([
            row("a", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-02",
                runNights: ["2026-10-02", "2026-10-03"]),
            row("b", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-03",
                runNights: ["2026-10-03", "2026-10-09"]),
            row("c", "The Infinite Wrench", venue: "Asylum NYC", "2026-10-09",
                runNights: ["2026-10-09"]),
        ]).isEmpty)
    }

    // #4022: the table in `ShowLink`'s header naming which mechanism covers which kind of duplicate is
    // prose, and prose is enforced by nothing (L407). This is the half that fails when it goes stale.
    //
    // It checks the two things a table like that gets wrong: a mechanism it names that no longer exists
    // (renamed, deleted, folded into another), and a mechanism that exists and is missing from it. The
    // second half is derived from the app's own source rather than from a second hand written list,
    // because a list checked against a list only ever confirms somebody copied one into the other (L96).
    @Test func theTableOfDuplicateMechanismsNamesOnlyThingsThatExist() {
        let header = AppSourceWalk.appFiles()
            .first { $0.name.hasSuffix("ShowLink.swift") }
        let text = try! #require(header?.text)
        #expect(text.contains("WHICH MECHANISM COVERS WHICH KIND OF DUPLICATE"),
                "the record #4022 asked for is gone from ShowLink's header")

        // Every type the table names, and the file each must still be defined in.
        let named = ["SameNightTitleVariantMerge", "DriftedRunMerge", "ContradictedCancellation",
                     "FeedBreakEvent", "ScoutService"]
        for mechanism in named {
            #expect(text.contains(mechanism), "the table stopped naming \(mechanism)")
            let defined = AppSourceWalk.appFiles().contains {
                $0.text.contains("enum \(mechanism)") || $0.text.contains("struct \(mechanism)")
            }
            #expect(defined,
                    """
                    ShowLink's header names \(mechanism) as a duplicate mechanism and no type by that \
                    name is defined in the app any more, so the record is stale (#4022)
                    """)
        }

        // The other direction: a pass that DELETES a Prospect is by definition one of these mechanisms,
        // so the table must name it. The candidate set is the one `SurvivorInheritanceTests` already
        // derives for the same class of question, minus the debug-only teardowns that declare an
        // exemption there.
        let deleters = AppSourceWalk.appFiles().filter {
            $0.text.contains("FetchDescriptor<Prospect>") && $0.text.contains("context.delete(")
                && $0.text.contains("SurvivorInheritance.carry")
        }
        #expect(deleters.count >= 2, "found \(deleters.count) deleting passes, too few to be scanning")
        for file in deleters {
            let type = file.name.replacingOccurrences(of: ".swift", with: "")
                .split(separator: "/").last.map(String.init) ?? file.name
            #expect(text.contains(type),
                    """
                    \(type) deletes a Prospect and is missing from ShowLink's table of which mechanism \
                    covers which duplicate (#4022)
                    """)
        }
    }
}
