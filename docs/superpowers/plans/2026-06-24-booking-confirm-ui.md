# Booking confirm-prompt UI (#114) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface the per-event booking suggestions #99 produces (`Prospect.bookingSuggested`) so Dan can confirm or dismiss them inline, see a toolbar count of pending ones, filter the queue to just them, and tell auto-detected bookings apart from his own.

**Architecture:** Mac-app-only, on the existing `QueueView` review surface. Reuses the row-menu pattern from #60 and the existing manual-outcome setter (`QueueView.setOutcome`, which already sets `.booked` + `OutcomeSource.manual` + timestamp). Confirming a suggestion = mark booked-as-manual + clear the suggestion; dismissing = clear the suggestion. A toolbar badge shows the count and toggles a "pending bookings only" filter.

**Tech Stack:** Swift, SwiftData, Swift Testing, xcodegen, xcodebuild.

## Global Constraints

- Mac-app-only. Do NOT touch `scripts/` or `src/`.
- This branch (`feat/114-booking-confirm`) already has #99 (`bookingSuggested`, `downbeatClientId`) and #60 (`classificationOverriddenByDan`, the row `Menu` pattern) merged.
- A confirmed booking MUST be sticky: `outcome = .booked`, `outcomeSourceRaw = OutcomeSource.manual.rawValue` (so no later scout reconcile overwrites it — `reconcileBooked` already skips `.manual`).
- Setting ANY manual outcome must also clear `bookingSuggested` (a resolved row shows no stale prompt).
- Auto-detected booking = `outcome == .booked && outcomeSourceRaw == OutcomeSource.auto.rawValue`.
- After adding any NEW `.swift` file: `cd mac && xcodegen generate` before xcodebuild.
- Test command: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test -only-testing:OvertureTests/<Suite>` (ignore CoreSimulator warnings; look for ✔/✘ and ** TEST/BUILD SUCCEEDED **). UI parts are verified by a build + the controller launching the app; the testable slices below get unit tests.

---

### Task 1: View-model exposure, pending count, and filter predicate

**Files:**
- Modify: the `QueueItem` view model + its mapping (`mac/Overture/UI/QueueView+Model.swift` and the `QueueItem.init(_ p: Prospect)` in `mac/Overture/Persistence/ResultsImporter.swift` — verify the real init location).
- Modify: `mac/Overture/UI/QueueView+Model.swift` (add the count + filter helper to `QueueModel`).
- Test: `mac/OvertureTests/` (mirror the existing `QueueItem`-mapping test suite, e.g. the override-flag mapping tests added in #60).

**Interfaces:**
- Produces on `QueueItem`: `bookingSuggested: Bool` (default false), `outcomeSource: OutcomeSource?` (or expose the raw + a computed `isAutoBooked: Bool`). Map both from the `Prospect`.
- Produces on `QueueModel`: `static func pendingBookingCount(_ items: [QueueItem]) -> Int` (count of `bookingSuggested == true`). The filter itself is applied in QueueView (Task 3) by `items.filter(\.bookingSuggested)`.

- [ ] **Step 1: Write failing tests** — `QueueItem` maps `bookingSuggested` and `isAutoBooked` from a Prospect (true/false cases); `QueueModel.pendingBookingCount` counts only suggested items. Mirror the existing QueueItem-mapping test helpers.
- [ ] **Step 2: Run to verify they fail.** Expected: FAIL (no such members).
- [ ] **Step 3: Implement** the QueueItem fields + mapping and the `pendingBookingCount` helper. `isAutoBooked` = `outcome == .booked && outcomeSourceRaw == OutcomeSource.auto.rawValue` (decide whether to map `outcomeSourceRaw` onto QueueItem or compute at map time — keep it consistent with how `outcome` is already mapped).
- [ ] **Step 4: Run to verify they pass**, then the full suite.
- [ ] **Step 5: Commit** — "Expose bookingSuggested/auto-booked and pending-booking count on QueueItem (#114)".

---

### Task 2: Row affordance — confirm prompt + auto-detected tag

**Files:**
- Modify: `mac/Overture/UI/ProspectRowView.swift`

**Interfaces:**
- Consumes: `item.bookingSuggested`, `item.isAutoBooked` (Task 1).
- Produces: two new callbacks `var onConfirmBooking: () -> Void = {}` and `var onDismissBookingSuggestion: () -> Void = {}` (mirror the existing default-closure callback style).

- [ ] **Step 1: Implement the affordance.** When `item.bookingSuggested`, show a "Possible booking — confirm?" control in the same visual language as the existing flags (capsule, OVColor — use a distinct tone from the rust "unsure" flag, e.g. OVColor.gold/green, to read as positive). Use a `Menu` or two small buttons: "Confirm booking" → `onConfirmBooking()`, "Not a booking" → `onDismissBookingSuggestion()`.
- [ ] **Step 2: Add the auto-detected tag.** When `item.isAutoBooked`, show a small "auto-detected" tag (reuse the existing `Tag` component with a neutral tone) so Dan can distinguish it from a booking he marked. Do not show it for manual bookings.
- [ ] **Step 3: Build** — `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' build` → ** BUILD SUCCEEDED **. (No unit test for the SwiftUI view itself; behavior is covered by Tasks 1 and 3.)
- [ ] **Step 4: Commit** — "Add the booking confirm prompt and auto-detected tag to the row (#114)".

---

### Task 3: QueueView wiring — handlers, clear-on-outcome, toolbar badge + filter

**Files:**
- Modify: `mac/Overture/UI/QueueView.swift`

**Interfaces:**
- Consumes: Task 1 (`pendingBookingCount`, `bookingSuggested`), Task 2 (the row callbacks), the existing `setOutcome`, `markConfidenceReviewed` Prospect-resolution pattern.

- [ ] **Step 1: Handlers.** Add `confirmBooking(_ item:)` — resolve the Prospect (same pattern as `setOutcome`/`markConfidenceReviewed`), set `outcome = .booked`, `outcomeSourceRaw = OutcomeSource.manual.rawValue`, `outcomeAt = Date()`, `bookingSuggested = false`, save. Add `dismissBookingSuggestion(_ item:)` — set `bookingSuggested = false`, save. Wire both into the `ProspectRowView(...)` callsite.
- [ ] **Step 2: Clear-on-outcome.** In the existing `setOutcome(_:_:)`, also set `model.bookingSuggested = false` so any manual outcome resolves a pending suggestion.
- [ ] **Step 3: Toolbar badge + filter.** Add a `@State private var showPendingBookingsOnly = false`. Compute `pendingBookings = QueueModel.pendingBookingCount(items)`. Add a toolbar button labelled `Confirm bookings (N)` (shown when N > 0) that toggles `showPendingBookingsOnly` (mirror the existing follow-ups/dismissed toolbar buttons). In the `filtered` computed property, when `showPendingBookingsOnly` is true, restrict to `item.bookingSuggested`.
- [ ] **Step 4: Test the filter logic if extractable.** If the filter is a pure function over items + flags, add a unit test (filter on → only suggested; off → unchanged). If it's entangled in the View, rely on the build + Task 1 coverage and note it.
- [ ] **Step 5: Build + full suite** green.
- [ ] **Step 6: Commit** — "Wire booking confirm/dismiss, clear-on-outcome, and the pending-bookings toolbar filter (#114)".

---

## Self-Review

- **Spec coverage:** surface suggestions (Tasks 2,3); confirm→sticky-manual-booked + clear (Task 3 Step 1); dismiss→clear (Task 3 Step 1); clear on any manual outcome (Task 3 Step 2); toolbar count (Task 3 Step 3); filter to pending bookings (Task 3 Step 3); auto-detected label (Task 2 Step 2).
- **Placeholder scan:** UI steps are build+visual verified by design, labeled as such; no hidden TODOs.
- **Type consistency:** `bookingSuggested`/`isAutoBooked`/`pendingBookingCount` (Task 1) consumed in Tasks 2-3; `onConfirmBooking`/`onDismissBookingSuggestion` (Task 2) consumed in Task 3.
