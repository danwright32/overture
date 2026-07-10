# Group Ceremony Sub-Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `RunGrouping.group` so a ceremony and its differently-titled sub-event (e.g. a "Guest Artist:" night) at the same venue on adjacent dates collapse into one card instead of two, so Dan never gets asked to pitch the same contact twice for the same event (#369).

**Architecture:** Replace the exact-title-equality bucketing key with venue-only bucketing, then decide whether a date-adjacent row continues the current run using the existing, already-tested `GroupNameMatch.isConfident` name-similarity check instead of exact string equality. Add a shortest-title tiebreak for which row becomes a merged run's displayed representative. No new matching primitive is introduced; `GroupNameMatch` (used today for repeat-client history matching) is reused as-is.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`@Suite`).

## Global Constraints

- Follow test-driven development: write the failing tests before the implementation.
- No dashes as punctuation in any code comment or commit message (hyphens inside words like "task-by-task" are fine; write connector phrases as separate words otherwise).
- Venue matching stays an EXACT match (`canon(venue)`, unchanged); only title matching changes from exact equality to `GroupNameMatch.isConfident`.
- The date-adjacency window stays `gapDays = 3`, unchanged.
- Scope is the grouping fix only. Contact-based dedup (the issue's other suggested direction) is explicitly out of scope for this plan; it was split into a separate follow-up issue since it lives in a different part of the pipeline (post-Prep, when contacts are known, versus Scout-time grouping, when they are not).
- `GroupNameMatch` (`mac/Overture/Domain/GroupNameMatch.swift`) itself is NOT modified. It is reused exactly as it exists today.

---

### Task 1: Venue-only grouping with title-similarity matching and a shortest-title tiebreak

**Files:**
- Modify: `mac/Overture/Domain/RunGrouping.swift`
- Test: `mac/OvertureTests/RunGroupingTests.swift`

**Interfaces:**
- Consumes: `GroupNameMatch.isConfident(_ a: String, _ b: String) -> Bool` and `GroupNameMatch.tokens(_ name: String) -> [String]` (both existing, unmodified, in `mac/Overture/Domain/GroupNameMatch.swift`).
- Produces: no new public interface; `RunGrouping.group(_:) -> [GroupedRun]`'s signature is unchanged, only its internal behavior changes.

- [ ] **Step 1: Write the failing tests**

Add these three tests to `mac/OvertureTests/RunGroupingTests.swift`, inside the `RunGroupingTests` struct, after the existing `undatedRowsPassThroughUnmerged` test (the last one in the file):

```swift
    // #369: a ceremony and its differently-titled sub-event (a "Guest Artist:" night) at the
    // same venue on an adjacent date must merge into one run, using GroupNameMatch's existing
    // name-similarity check instead of exact title equality. The shorter title (the general
    // ceremony name, not the specific sub-event name) becomes the run's displayed representative.
    @Test func ceremonySubEventWithGuestArtistTitleMergesWithParentCeremony() {
        let out = RunGrouping.group([
            row("Golden Classical Music Awards Ceremony", "2026-07-08", venue: "Weill Recital Hall"),
            row("Golden Classical Music Awards Ceremony Guest Artist: Aurelia Faidley-Solars, Cello",
                "2026-07-09", venue: "Weill Recital Hall"),
        ])
        #expect(out.count == 1)
        #expect(out[0].row.groupName == "Golden Classical Music Awards Ceremony")
        #expect(out[0].runEndDate == "2026-07-09")
        #expect(out[0].partOfRelatedRun == false)
        #expect(out[0].runSourceURLs.sorted() == ["u-2026-07-08", "u-2026-07-09"])
    }

    // #369: the shortest-title tiebreak must win regardless of which night is chronologically
    // first. Same pair as above with the dates swapped, proving the representative isn't just
    // "whichever row sorts first" coinciding with the shorter title by chance.
    @Test func shortestTitleWinsAsRepresentativeEvenWhenItIsTheLaterNight() {
        let out = RunGrouping.group([
            row("Golden Classical Music Awards Ceremony Guest Artist: Aurelia Faidley-Solars, Cello",
                "2026-07-08", venue: "Weill Recital Hall"),
            row("Golden Classical Music Awards Ceremony", "2026-07-09", venue: "Weill Recital Hall"),
        ])
        #expect(out.count == 1)
        #expect(out[0].row.groupName == "Golden Classical Music Awards Ceremony")
        #expect(out[0].runEndDate == "2026-07-09")
    }

    // #369: a genuinely different act sharing both a venue and a long common title prefix must
    // NOT merge. GroupNameMatch.isConfident requires the shorter name's full token sequence to
    // appear as a contiguous run inside the longer one; these two diverge partway through
    // ("The Bright Sparks" vs "The Dizzy Gillespie All Stars"), so it correctly returns false.
    // Guards against the grouping fix becoming too aggressive.
    @Test func differentActsAtSameVenueStayUnmergedDespiteSharedPrefix() {
        let out = RunGrouping.group([
            row("Jazz at Lincoln Center Presents The Bright Sparks", "2026-07-01", venue: "Rose Theater"),
            row("Jazz at Lincoln Center Presents The Dizzy Gillespie All Stars", "2026-07-03", venue: "Rose Theater"),
        ])
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.partOfRelatedRun })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RunGroupingTests`
Expected: FAIL. `ceremonySubEventWithGuestArtistTitleMergesWithParentCeremony` and `shortestTitleWinsAsRepresentativeEvenWhenItIsTheLaterNight` fail with `out.count == 1` not matching (currently produces `2`, since the two rows have different exact titles and land in different buckets today). `differentActsAtSameVenueStayUnmergedDespiteSharedPrefix` currently PASSES already by coincidence (today's exact-title bucketing already keeps these two apart, for the wrong reason: exact inequality, not the intended similarity check); this is expected. It stays green through this task and only starts testing the real intended behavior once Step 3 lands, at which point it must still return `false` for the correct reason.

- [ ] **Step 3: Replace `RunGrouping.group` with the venue-only, title-similarity version**

In `mac/Overture/Domain/RunGrouping.swift`, replace the doc comment at the top of the file (currently referencing a deleted TypeScript file) and the entire `group` function body. Replace the whole file's contents with:

```swift
import Foundation

// Collapse a multi-night run (same venue, a similar enough act name, performances <=3 days
// apart) into the opening night, tagged with the run's closing date, all member source URLs,
// and a flag when the same venue has more than one run/date for that act in the batch.
// #369: title matching uses GroupNameMatch.isConfident (a shared name-similarity check, already
// used for repeat-client history matching) instead of exact string equality, so a ceremony and
// its differently-titled sub-event (e.g. a "Guest Artist:" night) still merge.
enum RunGrouping {
    struct RunRow: Equatable, Sendable {
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var sourceListingURL: String?
    }

    struct GroupedRun: Equatable, Sendable {
        var row: RunRow
        var runEndDate: String?
        var partOfRelatedRun: Bool
        var runSourceURLs: [String]
    }

    private static let gapDays = 3

    private static func canon(_ s: String?) -> String {
        (s ?? "").lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // #369: among a run's member rows, the shortest (fewest tokens) groupName reads as the
    // general/parent title rather than a specific sub-event's, so it becomes the run's
    // displayed representative regardless of which night happens to be chronologically first.
    // Ties (equal token count, including the common case where every row in the run shares the
    // exact same title) keep the first row in chronological order, since `run` is already
    // date-sorted and Sequence.min(by:) returns the first minimal element on a tie.
    private static func representativeRow(_ run: [RunRow]) -> RunRow {
        run.min(by: { GroupNameMatch.tokens($0.groupName).count < GroupNameMatch.tokens($1.groupName).count }) ?? run[0]
    }

    static func group(_ rows: [RunRow]) -> [GroupedRun] {
        let undated = rows.filter { $0.performanceDate == nil }
        let dated = rows.filter { $0.performanceDate != nil }

        // #369: bucket by venue only now; title similarity (not exact equality) decides which
        // same-venue rows belong together, checked during the chronological walk below.
        var order: [String] = []
        var byVenue: [String: [RunRow]] = [:]
        for r in dated {
            let key = canon(r.venue)
            if byVenue[key] == nil { order.append(key); byVenue[key] = [] }
            byVenue[key]?.append(r)
        }

        var out: [GroupedRun] = []
        for key in order {
            let venueRows = (byVenue[key] ?? []).sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            var runs: [[RunRow]] = []
            for r in venueRows {
                if let last = runs.last, let prev = last.last,
                   let gap = EasternDate.daysUntil(from: prev.performanceDate!, to: r.performanceDate!),
                   gap <= gapDays,
                   GroupNameMatch.isConfident(prev.groupName, r.groupName) {
                    runs[runs.count - 1].append(r)
                } else {
                    runs.append([r])
                }
            }
            // #369: a run is "related" to another run at this same venue only when their
            // representative titles are the same act by GroupNameMatch, not merely "this venue
            // produced more than one run" (which would also flag two genuinely different,
            // unrelated acts that happen to share a venue). This generalizes the old exact-key
            // behavior (same title, same venue, split by a date gap) to the new similarity check.
            for (i, run) in runs.enumerated() {
                let open = representativeRow(run)
                let related = runs.indices.contains { j in
                    j != i && GroupNameMatch.isConfident(open.groupName, representativeRow(runs[j]).groupName)
                }
                out.append(GroupedRun(
                    row: open,
                    runEndDate: run.count > 1 ? run.last?.performanceDate : nil,
                    partOfRelatedRun: related,
                    runSourceURLs: run.compactMap { $0.sourceListingURL }
                ))
            }
        }
        for r in undated {
            out.append(GroupedRun(row: r, runEndDate: nil, partOfRelatedRun: false,
                                  runSourceURLs: r.sourceListingURL.map { [$0] } ?? []))
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RunGroupingTests`
Expected: `** TEST SUCCEEDED **`. Grep the output for all 9 test names in the suite (the 6 pre-existing ones: `mergesConsecutiveNightsIntoOneRunWithRange`, `chainsAcrossDarkDaysButSplitsOnLargerGap`, `flagsSeparateRunsOfSameGroupVenueAsRelated`, `doesNotMergeDifferentVenues`, `singleNightHasNilEndDate`, `undatedRowsPassThroughUnmerged`, plus the 3 new ones from Step 1) to confirm every single one actually ran and passed, not just that the suite reported success overall (a scoped `-only-testing:` run can report success with 0 tests executed if the path doesn't match).

- [ ] **Step 5: Run the full Swift suite**

Run: `cd "mac" && ./scripts/run-tests-locked.sh`
Expected: all tests pass, no regressions anywhere else in the suite (nothing else in the codebase calls `RunGrouping` directly besides `ScoutService.apply`, which is exercised by its own tests under a different, unrelated key; the interface (`group(_:) -> [GroupedRun]`) is unchanged, only its internal grouping decisions).

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/Domain/RunGrouping.swift mac/OvertureTests/RunGroupingTests.swift
git commit -m "Group a ceremony with its differently-titled sub-events (#369)"
```
