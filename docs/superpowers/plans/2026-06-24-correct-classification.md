# Correct a wrong classification (#60) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let Dan fix a prospect's discipline/production when the scout guessed wrong, make the fix stick against future scout runs, and re-rank that prospect immediately.

**Architecture:** Mac-app only. A Dan-owned override flag (`classificationOverriddenByDan`) mirrors the existing `confidenceReviewedByDan`. A shared re-score helper rebuilds a `Ranker.Candidate` from a `Prospect` and recomputes fit. The correction action sets the corrected discipline/production + flags + re-score; `ScoutService.apply` preserves overridden discipline/production and re-scores from them on later runs; the row UI gains a correction menu.

**Tech Stack:** Swift, SwiftData, Swift Testing, xcodegen, xcodebuild.

## Global Constraints

- Mac-app-only. Do NOT touch `scripts/` or `src/`.
- New SwiftData field MUST be optional/defaulted (`var classificationOverriddenByDan: Bool = false`) for lightweight migration.
- Any persisted `Prospect` is reachable (unreachable events are skipped before insert), so the re-score `Candidate` uses `reachable: true`.
- `Ranker.scoreFit(_ c: Candidate) -> FitResult` returns `{excluded, score, tier}` — it does NOT produce a `fitReason`. On override/re-score, set `fitScore` and `tier`; leave `fitReason` unchanged (it is a descriptive string the scout/AI-refine #30 owns). This is acceptable per #60.
- Correcting a classification also acknowledges the unsure flag (`confidenceReviewedByDan = true`).
- After adding any NEW `.swift` file: `cd mac && xcodegen generate` before xcodebuild.
- Test command: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test -only-testing:OvertureTests/<Suite>` (ignore CoreSimulator warnings; look for ✔/✘ and ** TEST SUCCEEDED/FAILED **). Run the full suite at the end of each task.

---

### Task 1: Model field + Prospect→Candidate re-score helper

**Files:**
- Modify: `mac/Overture/Domain/Prospect.swift` (add field)
- Create: `mac/Overture/Domain/ClassificationOverride.swift` (the helper)
- Test: `mac/OvertureTests/ClassificationOverrideTests.swift`
- After creating the new file: `cd mac && xcodegen generate`

**Interfaces:**
- Produces: `Prospect.classificationOverriddenByDan: Bool` (default false); and
  `enum ClassificationOverride { static func candidate(from p: Prospect, discipline: Discipline?, production: Production?) -> Ranker.Candidate; static func rescored(_ p: Prospect, discipline: Discipline?, production: Production?) -> FitResult }`
  where `discipline`/`production` nil means "use the prospect's current value". `candidate` maps the prospect's string fields to the Ranker enums (`Production`, `Profile`, `Coverage`, `Discipline`, `PriorRelationship`) with `reachable: true`, substituting the passed-in discipline/production when non-nil. `rescored` returns `Ranker.scoreFit(candidate(...))`.

- [ ] **Step 1: Add the field** to `Prospect.swift` (defaulted, next to `confidenceReviewedByDan`):

```swift
    // Dan-owned: once he corrects the discipline/production, the scout must not revert
    // them. Mirrors confidenceReviewedByDan. Defaulted so existing records migrate cleanly.
    var classificationOverriddenByDan: Bool = false
```

- [ ] **Step 2: Write the failing test** (`ClassificationOverrideTests.swift`). Verify the exact `Prospect` initializer and the raw-string values for the enums (`Discipline`, `Production`, etc.) before finalizing — read `Ranker.swift` and `Prospect.swift`.

```swift
import Testing
import Foundation
@testable import Overture

@Suite("Classification override re-score")
struct ClassificationOverrideTests {
    private func prospect(discipline: String, production: String, prior: String = "none",
                          profile: String = "strong", coverage: String = "likely_uncovered") -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: discipline, venue: "V",
                 performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: prior, production: production, profile: profile,
                 coverage: coverage, fitScore: 0, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved)
    }

    @Test func rescoringWithCorrectedDisciplineChangesFit() {
        // music (baseline) corrected to dance (+3) raises the score.
        let p = prospect(discipline: "music", production: "self")
        let before = ClassificationOverride.rescored(p, discipline: nil, production: nil)
        let after = ClassificationOverride.rescored(p, discipline: .dance, production: nil)
        #expect(after.score > before.score)
    }

    @Test func nilArgsUseTheProspectsCurrentValues() {
        let p = prospect(discipline: "dance", production: "self")
        let r = ClassificationOverride.rescored(p, discipline: nil, production: nil)
        let direct = Ranker.scoreFit(Ranker.Candidate(reachable: true, priorRelationship: .none,
            production: .selfProduced, profile: .strong, coverage: .likelyUncovered, discipline: .dance))
        #expect(r == direct)
    }
}
```

(Adjust enum case names/raw values and the `Candidate` initializer to the real ones from `Ranker.swift`.)

- [ ] **Step 3: Run to verify it fails** — `... -only-testing:OvertureTests/ClassificationOverrideTests`. Expected: FAIL (no `ClassificationOverride`).
- [ ] **Step 4: `cd mac && xcodegen generate`, then implement** `ClassificationOverride.swift`: map the prospect's string fields to the Ranker enums (reuse any existing string→enum init on those enums; they have `String` raw values), substitute the passed discipline/production when non-nil, `reachable: true`, and return `Ranker.scoreFit(...)`.
- [ ] **Step 5: Run to verify it passes**, then the full suite.
- [ ] **Step 6: Commit**

```bash
git add mac/Overture/Domain/Prospect.swift mac/Overture/Domain/ClassificationOverride.swift mac/OvertureTests/ClassificationOverrideTests.swift mac/project.yml mac/Overture.xcodeproj
git commit -m "Add classification override flag and re-score helper (#60)"
```

---

### Task 2: The correction action

**Files:**
- Modify: `mac/Overture/Domain/ClassificationOverride.swift` (add the mutating apply)
- Test: `mac/OvertureTests/ClassificationOverrideTests.swift`

**Interfaces:**
- Consumes: Task 1's `rescored(...)`.
- Produces: `static func correct(_ p: Prospect, discipline: Discipline?, production: Production?, now: Date)` — sets `p.discipline`/`p.production` to the corrected raw values (when provided), sets `p.classificationOverriddenByDan = true` and `p.confidenceReviewedByDan = true`, then sets `p.fitScore`/`p.tier` from `rescored(...)` computed with the corrected values. Does not save (caller owns the context save).

- [ ] **Step 1: Write the failing test:**

```swift
    @Test func correctingDisciplineSetsFlagsAndRerank() {
        let p = prospect(discipline: "music", production: "self")
        let before = p.fitScore
        ClassificationOverride.correct(p, discipline: .dance, production: nil, now: Date())
        #expect(p.discipline == "dance")
        #expect(p.classificationOverriddenByDan == true)
        #expect(p.confidenceReviewedByDan == true)
        #expect(p.fitScore > before)
    }

    @Test func correctingProductionOnlyLeavesDisciplineAlone() {
        let p = prospect(discipline: "dance", production: "self")
        ClassificationOverride.correct(p, discipline: nil, production: .agency, now: Date())
        #expect(p.discipline == "dance")
        #expect(p.production == "agency")
        #expect(p.classificationOverriddenByDan == true)
    }
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (no `correct`).
- [ ] **Step 3: Implement `correct(...)`** per the interface.
- [ ] **Step 4: Run to verify it passes**, then the full suite.
- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/ClassificationOverride.swift mac/OvertureTests/ClassificationOverrideTests.swift
git commit -m "Add the classification correction action (#60)"
```

---

### Task 3: Scout protection — preserve an override on re-ingest

**Files:**
- Modify: `mac/Overture/Integration/ScoutService.swift` (the `apply(_:to:)` update path)
- Test: `mac/OvertureTests/MatchingTests.swift` (or the ingest-persistence suite)

**Interfaces:**
- Consumes: `Prospect.classificationOverriddenByDan`, `ClassificationOverride.rescored`.

- [ ] **Step 1: Write the failing test** — a prospect with `classificationOverriddenByDan == true` whose stored discipline differs from a fresh scout result keeps Dan's discipline after `apply`, and its fit is re-scored from Dan's discipline (not the scout's). Use the in-memory `ModelContext` ingest pattern; set up an existing overridden prospect, then run `ScoutService.apply` with an event that classifies to a different discipline, and assert the discipline is unchanged.

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (apply overwrites discipline).
- [ ] **Step 3: Implement** in `apply(_:to:)`: when `existing.classificationOverriddenByDan`, skip `existing.discipline = p.discipline` and `existing.production = p.production`; still refresh `profile`/`coverage`/`priorRelationship`/etc from `p`; then set `existing.fitScore`/`existing.tier` from `ClassificationOverride.rescored(existing, discipline: nil, production: nil)` (which now reads existing's preserved discipline/production + freshly-updated profile/coverage/prior). Leave `fitReason` as `p.fitReason`. Never touch `classificationOverriddenByDan` here (Dan owns it), mirroring the `confidenceReviewedByDan` note.
- [ ] **Step 4: Run to verify it passes**, then the full suite.
- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Integration/ScoutService.swift mac/OvertureTests/MatchingTests.swift
git commit -m "Preserve and re-score a Dan-corrected classification on re-ingest (#60)"
```

---

### Task 4: The correction UI on the row

**Files:**
- Modify: `mac/Overture/UI/ProspectRowView.swift` (the `confidenceFlag`)
- Modify: the QueueView/model wiring that supplies row callbacks (find where `onMarkConfidenceReviewed` is passed to `ProspectRowView`) and the context-save path.

This task is UI; the controller will write a sharpened brief at dispatch and the result will be verified by building and running the app (not only unit tests).

Direction: turn the single `confidenceFlag` Button into a `Menu` whose primary/first item is the existing "This looks right" (acknowledge → `onMarkConfidenceReviewed`), followed by a "Correct the type" submenu listing the disciplines and a production toggle, each invoking a new `onCorrectClassification(discipline:, production:)` callback that calls `ClassificationOverride.correct(...)` on the prospect and saves the context. Keep the flag visible only while `item.isClassificationUncertain`. Match the existing row visual language (OVColor/OVType/Tag).

---

## Self-Review

- **Spec coverage:** correct discipline+production (Tasks 2,4); sticky override (Task 1 field + Task 3 protection); immediate re-rank (Task 2); also-acknowledges (Task 2); UI on the unsure flag (Task 4). 
- **Placeholder scan:** Task 4 is intentionally left for a sharpened dispatch brief + visual verification, labeled as such.
- **Type consistency:** `classificationOverriddenByDan` (Task 1) used in Tasks 3-4; `ClassificationOverride.rescored` (Task 1) used in Tasks 2-3; `correct` (Task 2) used in Task 4.
