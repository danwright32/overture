# Show Archive and Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Dan find and act on any show Overture has ever tracked, not just the ones currently visible in the day-to-day Queue, by adding a persistent search bar and a new Archive screen.

**Architecture:** A persistent search field in the main window (and a copy of the same field inside the new Archive screen) matches on org/act name, venue, and contact name/email across every show, live. Selecting a result either jumps to it inline in the Queue (if the Queue would actually show it) or opens Archive with that row highlighted. Archive is a new toolbar-accessible screen, replacing the existing Dismissed view, that lists every show with independent status filter toggles (New, Active, Closed - not now, Closed - not interested, Booked, Dismissed; defaulting to New + Active), sorted by most recent event date, reusing the exact same row component (`ProspectRowView`) and mutation logic the Queue uses today so every action (Mark menu, Keep/Dismiss, booking confirm, restore) behaves identically wherever the row appears. The Queue's own behavior is unchanged.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`).

## Global Constraints

- No dashes as punctuation in any generated code comment, string, or UI copy: no em dashes, no hyphens/dashes as parenthetical breaks or sentence connectors. Hyphens are fine only inside a single word. Use parentheses, commas, colons, or separate sentences instead.
- No comments explaining WHAT code does; only comment a genuinely non-obvious WHY (matches this file's existing convention throughout `mac/Overture`).
- 2 space indentation, Swift, following the existing Prettier-less Swift style already in the repo (matches surrounding code exactly).
- Every SwiftData mutation that can fail must go through `ModelContext.saveOrWarn(org:feedback:)` or `saveOrWarnSendNotConfirmed(org:feedback:)`, never a bare `try? context.save()` or a hand-rolled `do`/`catch` (existing repo-wide rule, enforced by `SourceGuard`-based regression tests).
- Run `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && xcodegen generate` after adding any new `.swift` file, before running tests.
- Run tests via `./scripts/run-tests-locked.sh` from `mac/` (never raw `xcodebuild test`, to avoid colliding with another test run).
- Never run `git push` yourself without the user's explicit go-ahead for that push.

---

## File Structure

```
mac/Overture/UI/ProspectMutations.swift   (NEW)  Every SwiftData mutation a row can trigger, extracted
                                                   from QueueView so QueueView and the new ArchiveView
                                                   share one implementation.
mac/Overture/UI/QueueView.swift           (MODIFY) Delegates its row actions to ProspectMutations
                                                   instead of its own private methods. No behavior change.
mac/Overture/UI/QueueView+Model.swift     (MODIFY) Adds QueueModel.isReachableInQueue, the pure check
                                                   that decides whether a search result should jump
                                                   into the Queue or open Archive instead.
mac/Overture/Domain/ArchiveStatus.swift   (NEW)  The six mutually exclusive buckets Archive filters by.
mac/Overture/Domain/ShowSearch.swift      (NEW)  The shared org/venue/contact text match, used by the
                                                   global search bar and Archive's own search field.
mac/Overture/UI/ProspectRowView.swift     (MODIFY) Adds an onRestore action and a Dismissed/Restore
                                                   row state, used only by Archive (the Queue never
                                                   shows a dismissed prospect, so its behavior there
                                                   is unchanged).
mac/Overture/UI/FilterChip.swift          (NEW)  The pill toggle used by Archive's status filter row.
mac/Overture/UI/ShowSearchField.swift     (NEW)  The reusable search field plus results dropdown.
mac/Overture/UI/ArchiveView.swift         (NEW)  The new "every show ever" screen, replacing DismissedView.
mac/Overture/UI/DismissedView.swift       (DELETE) Folded into ArchiveView.
mac/Overture/App/RootView.swift           (MODIFY) Swaps the Dismissed toolbar button/sheet for Archive,
                                                   adds the global search field, and wires the
                                                   reachability check that decides where a click lands.

mac/OvertureTests/ProspectMutationsTests.swift          (NEW)
mac/OvertureTests/QueueViewUserActionSaveGuardTests.swift (MODIFY, path only)
mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift (MODIFY, path only)
mac/OvertureTests/QueueModelTests.swift                 (MODIFY, append a suite)
mac/OvertureTests/ArchiveStatusTests.swift               (NEW)
mac/OvertureTests/ShowSearchTests.swift                  (NEW)
mac/OvertureTests/ProspectRowGuardTests.swift            (MODIFY, append a suite)
mac/OvertureTests/ShowSearchFieldGuardTests.swift        (NEW)
mac/OvertureTests/ArchiveViewRestoreSaveGuardTests.swift (NEW, replaces DismissedViewRestoreSaveGuardTests.swift)
mac/OvertureTests/DismissedViewRestoreSaveGuardTests.swift (DELETE)
```

---

### Task 1: Extract ProspectMutations

**Files:**
- Create: `mac/Overture/UI/ProspectMutations.swift`
- Test: `mac/OvertureTests/ProspectMutationsTests.swift`

**Interfaces:**
- Consumes: `QueueItem` (existing, `mac/Overture/UI/QueueView+Model.swift`), `Prospect`/`Recipient` (existing, `mac/Overture/Domain/`), `ModelContext.saveOrWarn(org:feedback:)` / `saveOrWarnSendNotConfirmed(org:feedback:)` (existing, `mac/Overture/App/ActionFeedback.swift`).
- Produces: `enum ProspectMutations` with static functions `toggleVoiceLearning`, `dismissReply`, `markContact`, `dismissContactReply`, `draftReply`, `editReplyDraft`, `copyReply`, `setStatus`, `saveDraft`, `markConfidenceReviewed`, `correctClassification`, `setConversationState`, `confirmConversationState`, `confirmBooking`, `dismissBookingSuggestion`, `rejectBooking`, `setLostReason`, `performSend`, `sendReply`; and `struct PendingSend: Identifiable` (`id: String`, `confirmation: SendConfirmation`). Task 2 (QueueView) and Task 7 (ArchiveView) call these directly.

- [ ] **Step 1: Write failing tests for three representative mutations**

```swift
import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("ProspectMutations")
struct ProspectMutationsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeProspect(_ ctx: ModelContext, key: String = "k", status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func setStatusUpdatesStatusAndDismissReason() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let feedback = ActionFeedback()
        ProspectMutations.setStatus(QueueItem(p), .dismissed, .notInterested,
                                    prospects: [p], context: ctx, feedback: feedback)
        #expect(p.status == .dismissed)
        #expect(p.dismissReasonRaw == DismissReason.notInterested.rawValue)
    }

    @Test func markContactSetsResolutionAndResumesPausedRecipients() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let recipient = Recipient(id: "r1", email: "act@example.com", provenance: .act)
        recipient.sendStateRaw = SendState.suppressed.rawValue
        recipient.suppressionReasonRaw = RecipientSuppressionReason.declined.rawValue
        p.recipients = [recipient]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.markContact(QueueItem(p), "r1", .declinedSoft, false,
                                      prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first?.resolution == .declinedSoft)
    }

    @Test func confirmBookingSetsOutcomeAndSuppressesUntriedRecipients() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let untried = Recipient(id: "r2", email: "presenter@example.com", provenance: .presenter)
        untried.sendStateRaw = SendState.pending.rawValue
        p.recipients = [untried]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.confirmBooking(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        #expect(p.recipients.first?.sendState == .suppressed)
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL to build. `ProspectMutations` does not exist yet.

- [ ] **Step 3: Create ProspectMutations.swift**

```swift
import Foundation
import SwiftData
import AppKit

// Every SwiftData mutation a queue row can trigger, moved out of QueueView so the same row
// component (Mark menu, Keep/Dismiss, booking confirm, and so on) behaves identically wherever
// it is shown: originally only the main Queue, now also the Archive lookup. Each function takes
// the full prospects array to find its target by natural key, the same way QueueView's private
// methods always did; nothing here changes existing behavior, it only relocates it.
@MainActor
enum ProspectMutations {
    static func toggleVoiceLearning(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.excludedFromVoiceLearning.toggle()
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.voiceLearning(excluded: model.excludedFromVoiceLearning, org: item.groupName))
        }
    }

    // Dan marked an auto-detected Gmail reply as not real (#219): revert it and remember that
    // reply so it does not re-flag, while a genuinely new reply still will.
    static func dismissReply(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.dismissAutoReply(now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // Dan hand marks one contact's outcome from the conversation surface (attribution only for
    // Booked, never sets the lead booking). Stamps the manual source so detection will not overwrite it.
    static func markContact(_ item: QueueItem, _ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool,
                            prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.markOutcomeManually(resolution: resolution, bounced: bounced) }
        model.resumePausedRecipients()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func dismissContactReply(_ item: QueueItem, _ recipientId: String,
                                    prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.dismissAutoReply() }
        model.resumePausedRecipients()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func draftReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.replyDraftRequestedAt = Date() }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
        _ = try? ReplyClassifyService.startClassify(from: context, now: Date())
    }

    static func editReplyDraft(_ item: QueueItem, _ recipientId: String, _ body: String,
                               prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.applyReplyDraftEdit(body) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func copyReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }),
              let body = recipient.replyDraftBody, !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        model.updateRecipient(id: recipientId) { $0.recordRepliedInGmail(now: Date()) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func setStatus(_ item: QueueItem, _ status: ReviewStatus, _ reason: DismissReason?,
                          prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.status = status
        model.dismissReasonRaw = reason?.rawValue
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func saveDraft(_ item: QueueItem, _ subject: String, _ body: String,
                         prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.applyEdit(subject: subject, body: body)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func markConfidenceReviewed(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confidenceReviewedByDan = true
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.confidenceConfirmed(org: item.groupName))
        }
    }

    static func correctClassification(_ item: QueueItem, discipline: Discipline?, production: Production?,
                                      prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        ClassificationOverride.correct(model, discipline: discipline, production: production, now: Date())
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.classificationCorrected(org: item.groupName))
        }
    }

    static func setConversationState(_ item: QueueItem, _ state: ConversationState,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.setConversationState(state, now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func confirmConversationState(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confirmConversationState(now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func confirmBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.outcome = .booked
        model.outcomeSourceRaw = OutcomeSource.manual.rawValue
        model.outcomeAt = Date()
        model.bookingSuggested = false
        model.suppressUntriedRecipients(reason: .bookedElsewhere)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func dismissBookingSuggestion(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.bookingSuggested = false
        model.bookingSuggestionDismissed = true
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func rejectBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.rejectAutoBooking(bookingId: model.autoBookedFromBookingId, now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func setLostReason(_ item: QueueItem, _ reason: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.lostReason = QueueModel.normalizedLostReason(reason)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // The confirm dialog itself (step 1 of a send) stays in each screen: it only needs
    // SendConfirmation(prospect:), a pure struct init, not worth extracting. This is step 2, the
    // actual send. markSending/clearSending let each screen show its own live "Sending…" state;
    // onNeedsReconnect lets each screen show its own reconnect prompt.
    static func performSend(_ naturalKey: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                           markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void,
                           onNeedsReconnect: @escaping () -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        let sender = GmailSender(fromEmail: "dan@danwrightphotography.com")
        markSending(naturalKey)
        Task {
            let sent = await SendService.sendOne(model, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: model.groupName, feedback: feedback)
            clearSending(naturalKey)
            if !sent && !GmailAuthManager.shared.isConnected { onNeedsReconnect() }
        }
    }

    static func sendReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                          markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void,
                          onNeedsReconnect: @escaping () -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        let sender = GmailSender(fromEmail: "dan@danwrightphotography.com")
        markSending(recipientId)
        Task {
            let sent = await SendService.sendReplyDraft(recipient, of: model, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: item.groupName, feedback: feedback)
            clearSending(recipientId)
            if !sent && !GmailAuthManager.shared.isConnected { onNeedsReconnect() }
        }
    }
}

// The one email awaiting Dan's explicit confirm before it sends (#49), shared by QueueView and
// ArchiveView so both present the identical confirm alert.
struct PendingSend: Identifiable {
    let id: String   // prospect naturalKey
    let confirmation: SendConfirmation
}
```

- [ ] **Step 4: Regenerate the Xcode project and run tests**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && xcodegen generate && ./scripts/run-tests-locked.sh
```
Expected: `ProspectMutationsTests` passes (3 tests). The rest of the suite is unaffected since QueueView has not been touched yet.

- [ ] **Step 5: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/UI/ProspectMutations.swift mac/OvertureTests/ProspectMutationsTests.swift mac/Overture.xcodeproj && git commit -m "Add ProspectMutations, extracted row action logic shared by Queue and Archive"
```

---

### Task 2: Refactor QueueView to use ProspectMutations

**Files:**
- Modify: `mac/Overture/UI/QueueView.swift`
- Modify: `mac/OvertureTests/QueueViewUserActionSaveGuardTests.swift`
- Modify: `mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift`

**Interfaces:**
- Consumes: `ProspectMutations` and `PendingSend` (Task 1, `mac/Overture/UI/ProspectMutations.swift`).
- Produces: no new interface; `QueueView`'s public surface (`deepLinkedKey`, `deepLinkedKeys`, `onConnectGmail`, `onShowFollowUps`) is unchanged. Task 7 (ArchiveView) follows the same call pattern established here.

This is a pure refactor: the 17 private mutation methods and the private `PendingConfirm` struct move out of `QueueView.swift`; every call site becomes a one line call into `ProspectMutations`. No test asserts on QueueView's private methods directly (the guard tests scan source text by file path, updated below), so behavior is verified by the existing full suite passing unchanged.

- [ ] **Step 1: Remove the 17 moved private methods and the PendingConfirm struct from QueueView.swift**

In `mac/Overture/UI/QueueView.swift`, delete the `private struct PendingConfirm` declaration (lines 53 to 56) and delete these private methods in their entirety: `toggleVoiceLearning`, `dismissReply`, `markContact`, `dismissContactReply`, `draftReply`, `sendReply`, `editReplyDraft`, `copyReply`, `setStatus`, `saveDraft`, `markConfidenceReviewed`, `correctClassification`, `setConversationState`, `confirmConversationState`, `confirmBooking`, `dismissBookingSuggestion`, `rejectBooking`, `setLostReason`, `performSend` (everything from the `toggleVoiceLearning` method down to the end of `performSend`, immediately before the closing brace of `struct QueueView`).

Change the `@State private var pendingConfirm: PendingConfirm?` declaration to:

```swift
    @State private var pendingConfirm: PendingSend?
```

- [ ] **Step 2: Rewrite prospectRow(_:reachOutLabel:) to delegate to ProspectMutations**

Replace the `prospectRow` function's `ProspectRowView(...)` construction with:

```swift
    private func prospectRow(_ item: QueueItem, reachOutLabel: String? = nil) -> some View {
        let model = prospects.first(where: { $0.naturalKey == item.id })
        let row = ProspectRowView(
            item: item,
            today: today,
            onKeep: { ProspectMutations.setStatus(item, .queued, nil, prospects: prospects, context: context, feedback: feedback) },
            onDismiss: { reason in ProspectMutations.setStatus(item, .dismissed, reason, prospects: prospects, context: context, feedback: feedback) },
            onApprove: { ProspectMutations.setStatus(item, .approved, nil, prospects: prospects, context: context, feedback: feedback) },
            onUnapprove: { ProspectMutations.setStatus(item, .drafted, nil, prospects: prospects, context: context, feedback: feedback) },
            onSkipDraft: { ProspectMutations.setStatus(item, .dismissed, .notInterested, prospects: prospects, context: context, feedback: feedback) },
            onSaveDraft: { subject, body in ProspectMutations.saveDraft(item, subject, body, prospects: prospects, context: context, feedback: feedback) },
            onSetLostReason: { reason in ProspectMutations.setLostReason(item, reason, prospects: prospects, context: context, feedback: feedback) },
            onSend: { requestSend(item) },
            onSetConversationState: { state in ProspectMutations.setConversationState(item, state, prospects: prospects, context: context, feedback: feedback) },
            onConfirmConversationState: { ProspectMutations.confirmConversationState(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissReply: { ProspectMutations.dismissReply(item, prospects: prospects, context: context, feedback: feedback) },
            onMarkContact: { rid, resolution, bounced in
                ProspectMutations.markContact(item, rid, resolution, bounced, prospects: prospects, context: context, feedback: feedback)
            },
            onDismissContactReply: { rid in ProspectMutations.dismissContactReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDraftReply: { rid in ProspectMutations.draftReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onSendReply: { rid in sendReply(item, rid) },
            onCopyReply: { rid in ProspectMutations.copyReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onEditReplyDraft: { rid, body in ProspectMutations.editReplyDraft(item, rid, body, prospects: prospects, context: context, feedback: feedback) },
            onMarkConfidenceReviewed: { ProspectMutations.markConfidenceReviewed(item, prospects: prospects, context: context, feedback: feedback) },
            onCorrectClassification: { d, p in
                ProspectMutations.correctClassification(item, discipline: d, production: p, prospects: prospects, context: context, feedback: feedback)
            },
            onConfirmBooking: { ProspectMutations.confirmBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissBookingSuggestion: { ProspectMutations.dismissBookingSuggestion(item, prospects: prospects, context: context, feedback: feedback) },
            onRejectBooking: { ProspectMutations.rejectBooking(item, prospects: prospects, context: context, feedback: feedback) },
            gmailConnected: GmailAuthManager.shared.isConnected,
            outboundSendSince: outboundSending[item.id],
            replySendSince: { rid in replySending[rid] },
            reachOutLabel: reachOutLabel
        )
        // #236: tag each row with its key so a deep link can scroll to it, and highlight the target.
        let highlighted = highlightedKey == item.id
        let framed = row
            .padding(highlighted ? OVSpacing.sm : 0)
            .background(highlighted ? OVColor.gold.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .id(item.id)
        if let model, model.sentAt != nil, model.originalDraftBody != nil {
            return AnyView(framed.contextMenu {
                Button(model.excludedFromVoiceLearning ? "Learn from this email again"
                                                       : "Don't learn from this email") {
                    ProspectMutations.toggleVoiceLearning(item, prospects: prospects, context: context, feedback: feedback)
                }
            })
        }
        return AnyView(framed)
    }
```

- [ ] **Step 3: Replace requestSend, performSend, and sendReply with thin wrappers around ProspectMutations**

Add these three private methods to `QueueView` (in the same place `performSend` used to live):

```swift
    // Step 1 of an explicit send: show Dan exactly what will go out and wait for his confirm (#49).
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingSend(id: item.id, confirmation: confirmation)
    }

    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        ProspectMutations.performSend(naturalKey, prospects: prospects, context: context, feedback: feedback,
                                      markSending: { outboundSending[$0] = Date() },
                                      clearSending: { outboundSending[$0] = nil },
                                      onNeedsReconnect: { showReconnect = true })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { replySending[$0] = Date() },
                                    clearSending: { replySending[$0] = nil },
                                    onNeedsReconnect: { showReconnect = true })
    }
```

- [ ] **Step 4: Update the two SourceGuard tests that scanned QueueView.swift by function name**

In `mac/OvertureTests/QueueViewUserActionSaveGuardTests.swift`, change the file the guard scans:

```swift
        let queueView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/ProspectMutations.swift")
        let src = try String(contentsOf: queueView, encoding: .utf8)
```

(Only the `.appendingPathComponent` argument changes, from `"Overture/UI/QueueView.swift"` to `"Overture/UI/ProspectMutations.swift"`. The rest of the file, including the comment and the `guardedFunctions` list, is unchanged since every one of those function names still exists, just in the new file.)

In `mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift`, change:

```swift
    @Test func queueViewHandlersUseSaveOrWarn() throws {
        try assertHandlersUseSaveOrWarn(file: "Overture/UI/ProspectMutations.swift", functions: Self.queueViewFunctions)
    }
```

(Only the `file:` argument changes.)

- [ ] **Step 5: Run the full suite**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh
```
Expected: full suite green, no behavior change. `QueueViewUserActionSaveGuardTests` and `SaveOrWarnConsolidationGuardTests.queueViewHandlersUseSaveOrWarn` now scan `ProspectMutations.swift` and still pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/UI/QueueView.swift mac/OvertureTests/QueueViewUserActionSaveGuardTests.swift mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift && git commit -m "Refactor QueueView to delegate row actions to ProspectMutations"
```

---

### Task 3: QueueModel.isReachableInQueue

**Files:**
- Modify: `mac/Overture/UI/QueueView+Model.swift`
- Test: `mac/OvertureTests/QueueModelTests.swift`

**Interfaces:**
- Consumes: `QueueModel.toSendQueue(_:reachedOutKeys:today:)` (existing, same file).
- Produces: `QueueModel.isReachableInQueue(_ item: QueueItem, reachedOutKeys: Set<String>, today: String) -> Bool`. Task 8 (RootView) calls this to decide whether a search result should jump into the Queue or open Archive.

- [ ] **Step 1: Write the failing tests**

Append to `mac/OvertureTests/QueueModelTests.swift`:

```swift
// #NEW: whether clicking a global search result would land on a real, visible row in the Queue,
// as opposed to a show the Queue hides (past its bookable window, or no longer active).
@Suite("Queue reachability")
struct QueueReachabilityTests {
    @Test func aShowInTheReachedOutSetIsReachableEvenIfLongPast() {
        let a = item(performanceDate: "2020-01-01", key: "a")
        #expect(QueueModel.isReachableInQueue(a, reachedOutKeys: ["a"], today: "2026-07-07"))
    }

    @Test func aShowWithinTheBookableWindowIsReachable() {
        let a = item(performanceDate: "2026-08-01", key: "a")
        #expect(QueueModel.isReachableInQueue(a, reachedOutKeys: [], today: "2026-07-07"))
    }

    @Test func aPastShowNotInTheReachedOutSetIsUnreachable() {
        let a = item(performanceDate: "2020-01-01", key: "a")
        #expect(QueueModel.isReachableInQueue(a, reachedOutKeys: [], today: "2026-07-07") == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL to build. `QueueModel.isReachableInQueue` does not exist yet.

- [ ] **Step 3: Add the function**

In `mac/Overture/UI/QueueView+Model.swift`, immediately after the existing `static func toSendQueue(_ items: [QueueItem], reachedOutKeys: Set<String>, today: String) -> [QueueItem]` function, add:

```swift
    // #NEW: whether a single show would actually render somewhere in the Queue right now, reusing
    // the exact same reached-out/toSendQueue rules the Queue itself renders with (on a one item
    // array), so this can never drift from what Dan would actually see if he looked.
    static func isReachableInQueue(_ item: QueueItem, reachedOutKeys: Set<String>, today: String) -> Bool {
        if reachedOutKeys.contains(item.id) { return true }
        return !toSendQueue([item], reachedOutKeys: [], today: today).isEmpty
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/UI/QueueView+Model.swift mac/OvertureTests/QueueModelTests.swift && git commit -m "Add QueueModel.isReachableInQueue for search result routing"
```

---

### Task 4: ArchiveStatus

**Files:**
- Create: `mac/Overture/Domain/ArchiveStatus.swift`
- Test: `mac/OvertureTests/ArchiveStatusTests.swift`

**Interfaces:**
- Consumes: `QueueItem.status` (`ReviewStatus`) and `QueueItem.performanceStatus` (`PerformanceStatus`, existing).
- Produces: `enum ArchiveStatus: String, CaseIterable, Sendable` with cases `new, active, lostDoorOpen, lostNotInterested, booked, dismissed`, a `label: String`, and `static func of(_ item: QueueItem) -> ArchiveStatus`. Task 7 (ArchiveView) uses this for its filter checkboxes.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Overture

private func item(status: ReviewStatus = .new, performanceStatus: PerformanceStatus = .new, key: String = "k") -> QueueItem {
    var q = QueueItem(
        id: key, groupName: "Test Group", discipline: "music", venue: "Weill Recital Hall",
        performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status
    )
    q.performanceStatus = performanceStatus
    return q
}

@Suite("ArchiveStatus")
struct ArchiveStatusTests {
    @Test func dismissedTakesPrecedenceOverPerformanceStatus() {
        // A prospect cut at triage is always performanceStatus .new (never contacted), but Archive
        // must bucket it as Dismissed, not New, so it is hidden by the New+Active default filter.
        let i = item(status: .dismissed, performanceStatus: .new)
        #expect(ArchiveStatus.of(i) == .dismissed)
    }

    @Test func nonDismissedMapsDirectlyFromPerformanceStatus() {
        #expect(ArchiveStatus.of(item(status: .new, performanceStatus: .new)) == .new)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .active)) == .active)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostDoorOpen)) == .lostDoorOpen)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostNotInterested)) == .lostNotInterested)
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .booked)) == .booked)
    }

    @Test func labelsAreDistinctPlainLanguage() {
        #expect(ArchiveStatus.lostDoorOpen.label == "Closed (not now)")
        #expect(ArchiveStatus.lostNotInterested.label == "Closed (not interested)")
        #expect(ArchiveStatus.dismissed.label == "Dismissed")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL to build. `ArchiveStatus` does not exist yet.

- [ ] **Step 3: Create ArchiveStatus.swift**

```swift
import Foundation

// Where a show sits for the Archive lookup (#NEW). Mirrors PerformanceStatus's five outcomes, plus
// Dismissed (a triage stage cut, ReviewStatus.dismissed) as a sixth, mutually exclusive bucket.
// Dismissed takes precedence: a cut prospect is always performanceStatus .new (it was never
// contacted), but that is not the useful lens once Dan has cut it.
enum ArchiveStatus: String, CaseIterable, Sendable {
    case new
    case active
    case lostDoorOpen
    case lostNotInterested
    case booked
    case dismissed

    var label: String {
        switch self {
        case .new: return "New"
        case .active: return "Active"
        case .lostDoorOpen: return "Closed (not now)"
        case .lostNotInterested: return "Closed (not interested)"
        case .booked: return "Booked"
        case .dismissed: return "Dismissed"
        }
    }

    static func of(_ item: QueueItem) -> ArchiveStatus {
        guard item.status != .dismissed else { return .dismissed }
        switch item.performanceStatus {
        case .new: return .new
        case .active: return .active
        case .lostDoorOpen: return .lostDoorOpen
        case .lostNotInterested: return .lostNotInterested
        case .booked: return .booked
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/Domain/ArchiveStatus.swift mac/OvertureTests/ArchiveStatusTests.swift && git commit -m "Add ArchiveStatus, the six filter buckets for the Archive screen"
```

---

### Task 5: ShowSearch

**Files:**
- Create: `mac/Overture/Domain/ShowSearch.swift`
- Test: `mac/OvertureTests/ShowSearchTests.swift`

**Interfaces:**
- Consumes: `QueueItem.groupName`, `QueueItem.venue`, `QueueItem.contacts` (`[RecipientSnapshot]`, existing).
- Produces: `enum ShowSearch { static func matches(_ item: QueueItem, query: String) -> Bool }`. Task 6 (`ShowSearchField`) and Task 8 (RootView) call this.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Overture

private func item(groupName: String = "Aurora Strings", venue: String? = "Weill Recital Hall",
                  contacts: [RecipientSnapshot] = []) -> QueueItem {
    var q = QueueItem(
        id: "k", groupName: groupName, discipline: "music", venue: venue,
        performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
    q.contacts = contacts
    return q
}

private func contact(name: String? = nil, email: String? = nil) -> RecipientSnapshot {
    RecipientSnapshot(id: email ?? name ?? "c", name: name, email: email, role: nil,
                      provenance: .act, sendState: .sent, replied: false, lastReplyText: nil,
                      resolution: nil, bounced: false, outcomeSource: nil)
}

@Suite("ShowSearch")
struct ShowSearchTests {
    @Test func matchesOrgNameCaseInsensitively() {
        #expect(ShowSearch.matches(item(groupName: "Aurora Strings"), query: "aurora"))
        #expect(ShowSearch.matches(item(groupName: "Aurora Strings"), query: "AURORA STRINGS"))
        #expect(!ShowSearch.matches(item(groupName: "Aurora Strings"), query: "Lumen"))
    }

    @Test func matchesVenue() {
        #expect(ShowSearch.matches(item(venue: "Weill Recital Hall"), query: "weill"))
        #expect(!ShowSearch.matches(item(venue: nil), query: "weill"))
    }

    @Test func matchesContactNameOrEmail() {
        let withContact = item(contacts: [contact(name: "Emma Roth", email: "emma@aurorastrings.example")])
        #expect(ShowSearch.matches(withContact, query: "emma"))
        #expect(ShowSearch.matches(withContact, query: "aurorastrings.example"))
        #expect(!ShowSearch.matches(withContact, query: "nobody"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(ShowSearch.matches(item(), query: ""))
        #expect(ShowSearch.matches(item(), query: "   "))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL to build. `ShowSearch` does not exist yet.

- [ ] **Step 3: Create ShowSearch.swift**

```swift
import Foundation

// Matches a show against a free text query (#NEW), shared by the global search bar and Archive's
// own search field: org/act name, venue, and every recipient's name/email, so Dan can find a show
// whether he remembers who he pitched, where it was, or who replied. Case insensitive substring
// match; an empty (or all whitespace) query matches everything.
enum ShowSearch {
    static func matches(_ item: QueueItem, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if contains(item.groupName, trimmed) { return true }
        if let venue = item.venue, contains(venue, trimmed) { return true }
        for contact in item.contacts {
            if let name = contact.name, contains(name, trimmed) { return true }
            if let email = contact.email, contains(email, trimmed) { return true }
        }
        return false
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/Domain/ShowSearch.swift mac/OvertureTests/ShowSearchTests.swift && git commit -m "Add ShowSearch, the shared org/venue/contact text match"
```

---

### Task 6: ProspectRowView restore action, FilterChip, ShowSearchField

**Files:**
- Modify: `mac/Overture/UI/ProspectRowView.swift`
- Modify: `mac/OvertureTests/ProspectRowGuardTests.swift`
- Create: `mac/Overture/UI/FilterChip.swift`
- Create: `mac/Overture/UI/ShowSearchField.swift`
- Test: `mac/OvertureTests/ShowSearchFieldGuardTests.swift`

**Interfaces:**
- Consumes: `ShowSearch.matches` (Task 5), `QueueItem` (existing).
- Produces: `ProspectRowView.onRestore: (() -> Void)?` (new optional parameter; `nil` everywhere it is used today, so no behavior change for `QueueView`). `FilterChip: View` (`label: String, active: Bool, action: () -> Void`). `ShowSearchField: View` (`query: Binding<String>, allItems: [QueueItem], placeholder: String, onSelect: (QueueItem) -> Void`). Task 7 (ArchiveView) and Task 8 (RootView) use all three.

This task has no new SwiftData behavior to unit test (it is pure SwiftUI view code), so it uses the repo's established `SourceGuard` pattern (see `ProspectRowGuardTests.swift`) instead of a runtime test, consistent with every other view only change in this codebase.

- [ ] **Step 1: Write the failing guard tests**

Append to `mac/OvertureTests/ProspectRowGuardTests.swift`:

```swift
// #NEW: a dismissed prospect (only ever shown in Archive; the Queue never renders one) reads as
// Dismissed with a Restore action, not as an undecided new prospect with Keep/Dismiss.
@Suite("Dismissed rows show Restore instead of Keep/Dismiss")
struct ProspectRowRestoreGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func onRestoreParameterExists() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("var onRestore: (() -> Void)?"))
    }

    @Test func actionsBranchesOnDismissedStatusBeforeKeepDismiss() {
        guard let actionsRange = prospectRow.range(of: "private var actions: some View {") else {
            Issue.record("actions view not found")
            return
        }
        let body = prospectRow[actionsRange.lowerBound...].prefix(600)
        #expect(body.contains("item.status == .dismissed"))
        #expect(body.contains("Restore"))
    }
}
```

Create `mac/OvertureTests/ShowSearchFieldGuardTests.swift`:

```swift
import Testing
import Foundation

// View only change with no independently testable behavior beyond ShowSearch itself (covered by
// ShowSearchTests): confirms the field actually wires into the shared matcher instead of rolling
// its own comparison.
@Suite("ShowSearchField uses the shared matcher")
struct ShowSearchFieldGuardTests {
    @Test func wiresToShowSearchMatches() {
        let src = SourceGuardHelper.source("Overture/UI/ShowSearchField.swift")
        #expect(!src.isEmpty)
        #expect(src.contains("ShowSearch.matches("))
    }
}
```

- [ ] **Step 2: Run to verify both fail**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL. `onRestore` does not exist on `ProspectRowView`; `ShowSearchField.swift` does not exist.

- [ ] **Step 3: Add onRestore and the Dismissed/Restore branch to ProspectRowView**

In `mac/Overture/UI/ProspectRowView.swift`, add the new parameter alongside the other `var on...` declarations (after `var onRejectBooking: () -> Void = {}`):

```swift
    // #NEW: only ever passed non nil by Archive (the Queue never shows a dismissed prospect), so
    // this has zero effect on any existing Queue row.
    var onRestore: (() -> Void)? = nil
```

Replace the `actions` computed property with:

```swift
    private var actions: some View {
        HStack(spacing: OVSpacing.xs) {
            if item.status == .dismissed, let onRestore {
                Label("Dismissed", systemImage: "archivebox")
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.inkFaint)
                    .padding(.horizontal, OVSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.inkFaint.opacity(0.10)))
                Button { onRestore() } label: {
                    Text("Restore").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .help("Put this prospect back in the queue as undecided")
            } else if item.isKept {
                Label("Kept", systemImage: "checkmark.seal.fill")
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.forest)
                    .padding(.horizontal, OVSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.forest.opacity(0.10)))
            } else {
                Button {
                    let wasUncertain = item.isClassificationUncertain
                    onKeep()
                    if wasUncertain { showConfirmClassification = true }
                } label: {
                    Text("Keep").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showConfirmClassification) { confirmClassificationPopover }
                Menu {
                    ForEach(DismissReason.allCases, id: \.self) { reason in
                        Button(reason.label) { onDismiss(reason) }
                    }
                } label: {
                    Text("Dismiss").font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
```

(The `else` branch's Keep/Dismiss content is unchanged from today; only the new `if item.status == .dismissed` branch and the previously bare `if item.isKept` are now an `if`/`else if`/`else` chain.)

- [ ] **Step 4: Create FilterChip.swift**

```swift
import SwiftUI

// The pill shaped toggle Archive's status filter row uses (#NEW), matching the Queue's existing
// discipline chip look without touching QueueFilterBar's already reviewed, working code.
struct FilterChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(OVType.tag)
                .foregroundStyle(active ? OVColor.onForest : OVColor.inkSoft)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                .background(Capsule().fill(active ? OVColor.forest : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 5: Create ShowSearchField.swift**

```swift
import SwiftUI

// The shared search UI (#NEW) for finding any show Overture has ever tracked, whether it is still
// in the Queue's date window or has since gone past, booked, closed, or dismissed. Used both as
// the persistent bar in the main window and inside Archive's own narrowing field, so the matching
// behavior and the dropdown look identical everywhere Dan searches.
struct ShowSearchField: View {
    @Binding var query: String
    let allItems: [QueueItem]
    var placeholder: String = "Search shows, venues, contacts"
    var onSelect: (QueueItem) -> Void = { _ in }
    @FocusState private var isFocused: Bool

    private var matches: [QueueItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(
            allItems
                .filter { ShowSearch.matches($0, query: query) }
                .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
                .prefix(8)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(OVColor.inkFaint)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(OVColor.inkFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
            .background(Capsule().fill(OVColor.surfaceSunk))
            .overlay(Capsule().strokeBorder(OVColor.line, lineWidth: 1))
            .frame(maxWidth: 280)
            if isFocused, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { result in
                        Button {
                            onSelect(result)
                            query = ""
                            isFocused = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                                Text([result.venue, result.performanceDate].compactMap { $0 }.joined(separator: " "))
                                    .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                            }
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(OVColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OVColor.line, lineWidth: 1))
                .frame(maxWidth: 320)
            }
        }
    }
}
```

- [ ] **Step 6: Regenerate the Xcode project and run tests**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && xcodegen generate && ./scripts/run-tests-locked.sh
```
Expected: full suite green, including the two new guard suites.

- [ ] **Step 7: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/UI/ProspectRowView.swift mac/Overture/UI/FilterChip.swift mac/Overture/UI/ShowSearchField.swift mac/OvertureTests/ProspectRowGuardTests.swift mac/OvertureTests/ShowSearchFieldGuardTests.swift mac/Overture.xcodeproj && git commit -m "Add restore action to ProspectRowView, add FilterChip and ShowSearchField"
```

---

### Task 7: ArchiveView, replacing DismissedView

**Files:**
- Create: `mac/Overture/UI/ArchiveView.swift`
- Delete: `mac/Overture/UI/DismissedView.swift`
- Create: `mac/OvertureTests/ArchiveViewRestoreSaveGuardTests.swift`
- Delete: `mac/OvertureTests/DismissedViewRestoreSaveGuardTests.swift`
- Modify: `mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift`

**Interfaces:**
- Consumes: `ProspectMutations`, `PendingSend` (Task 1), `QueueModel.isReachableInQueue` is not needed here (ArchiveView shows everything regardless of Queue reachability), `ArchiveStatus` (Task 4), `ShowSearch` via `ShowSearchField` (Task 5, Task 6), `FilterChip` (Task 6), `ProspectRowView.onRestore` (Task 6), `DismissedProspects.restore(_:)` (existing, `mac/Overture/Domain/DismissedProspects.swift`).
- Produces: `ArchiveView: View` with `init(initialHighlightKey: String? = nil, onConnectGmail: @escaping () -> Void = {})`. Task 8 (RootView) presents this as a sheet.

- [ ] **Step 1: Write the failing regression guard test for restore's save path**

Create `mac/OvertureTests/ArchiveViewRestoreSaveGuardTests.swift`:

```swift
import Testing
import Foundation

// Regression guard for #499 (originally on DismissedView, moved here with the view): restore
// mutates a prospect on Dan's action and must never swallow a context.save() failure with a bare
// try?, so a restore could silently fail to persist while still telling Dan it worked.
@Suite("ArchiveView restore save guard")
struct ArchiveViewRestoreSaveGuardTests {
    private static let forbidden = "try? context.save()"

    @Test func restoreNeverRevertsToSilentSave() throws {
        let src = SourceGuardHelper.source("Overture/UI/ArchiveView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "restore", in: src)
        #expect(!body.contains(Self.forbidden),
                "restore reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
        #expect(body.contains("saveOrWarn("),
                "restore no longer calls saveOrWarn(org:feedback:); a save failure path must go through the shared helper (#618).")
    }
}
```

Delete `mac/OvertureTests/DismissedViewRestoreSaveGuardTests.swift`:

```bash
rm "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/OvertureTests/DismissedViewRestoreSaveGuardTests.swift"
```

In `mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift`, change:

```swift
    @Test func dismissedViewHandlerUsesSaveOrWarn() throws {
        try assertHandlersUseSaveOrWarn(file: "Overture/UI/ArchiveView.swift", functions: Self.dismissedViewFunctions)
    }
```

(Only the `file:` argument changes, from `"Overture/UI/DismissedView.swift"` to `"Overture/UI/ArchiveView.swift"`.)

- [ ] **Step 2: Run to verify the new guard test fails**

Run: `cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./scripts/run-tests-locked.sh`
Expected: FAIL to build. `ArchiveView.swift` does not exist yet, and `DismissedView.swift` still exists (delete it in the next step).

- [ ] **Step 3: Delete DismissedView.swift**

```bash
rm "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/Overture/UI/DismissedView.swift"
```

- [ ] **Step 4: Create ArchiveView.swift**

```swift
import SwiftUI
import SwiftData

// Every show Overture has ever tracked (#NEW), for the cases the day to day Queue intentionally
// hides: past its bookable window, booked, closed either way, or dismissed at triage. Replaces
// DismissedView (Dismissed is now one of six independent status filters here, instead of its own
// separate screen). Reuses ProspectRowView and ProspectMutations exactly as the Queue does, so
// every row action (Mark menu, booking confirm, restore) behaves identically here.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback

    @Query private var prospects: [Prospect]

    @State private var activeStatuses: Set<ArchiveStatus> = [.new, .active]
    @State private var query: String = ""
    @State private var highlightedKey: String?
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]
    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false

    var initialHighlightKey: String? = nil
    var onConnectGmail: () -> Void = {}

    private var today: String { QueueModel.easternToday() }
    private var items: [QueueItem] { prospects.map(QueueItem.init) }

    private var filtered: [QueueItem] {
        items
            .filter { activeStatuses.contains(ArchiveStatus.of($0)) }
            .filter { ShowSearch.matches($0, query: query) }
            .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            ShowSearchField(query: $query, allItems: items) { result in
                highlightedKey = result.id
            }
            .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
            Divider()
            content
        }
        .frame(minWidth: 640, idealWidth: 780, maxWidth: 960, minHeight: 520, idealHeight: 720, maxHeight: 900)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
        .alert("Send this email now?", isPresented: sendConfirmBinding, presenting: pendingConfirm) { pending in
            Button("Send") { performSend(pending.id) }
            Button("Cancel", role: .cancel) { pendingConfirm = nil }
        } message: { pending in
            Text("To: \(pending.confirmation.recipient)\nSubject: \(pending.confirmation.subject)\n\nThis sends one email right now, to this recipient only. Nothing else goes out.")
        }
        .alert("Reconnect Gmail", isPresented: $showReconnect) {
            Button("Connect Gmail") { onConnectGmail() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again.")
        }
        .onAppear {
            guard let key = initialHighlightKey, let target = items.first(where: { $0.id == key }) else { return }
            activeStatuses.insert(ArchiveStatus.of(target))
            highlightedKey = key
        }
    }

    private var header: some View {
        HStack {
            Text("Archive").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text("\(filtered.count)").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(OVSpacing.lg)
    }

    private var filterBar: some View {
        WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
            ForEach(ArchiveStatus.allCases, id: \.self) { status in
                FilterChip(label: status.label, active: activeStatuses.contains(status)) {
                    if activeStatuses.contains(status) {
                        activeStatuses.remove(status)
                    } else {
                        activeStatuses.insert(status)
                    }
                }
            }
        }
        .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
    }

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: OVSpacing.md) {
                        ForEach(filtered) { item in row(item) }
                    }
                    .padding(OVSpacing.lg)
                }
                .task {
                    guard let key = initialHighlightKey else { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    withAnimation { proxy.scrollTo(key, anchor: .center) }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if highlightedKey == key { highlightedKey = nil }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: OVSpacing.xs) {
            Text(items.isEmpty ? "Nothing scouted yet" : "Nothing matches this filter")
                .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(items.isEmpty
                 ? "Shows land here once Overture has tracked at least one."
                 : "Try a different status filter, or clear the search.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OVSpacing.xl)
    }

    private func row(_ item: QueueItem) -> some View {
        let model = prospects.first(where: { $0.naturalKey == item.id })
        let row = ProspectRowView(
            item: item,
            today: today,
            onKeep: { ProspectMutations.setStatus(item, .queued, nil, prospects: prospects, context: context, feedback: feedback) },
            onDismiss: { reason in ProspectMutations.setStatus(item, .dismissed, reason, prospects: prospects, context: context, feedback: feedback) },
            onApprove: { ProspectMutations.setStatus(item, .approved, nil, prospects: prospects, context: context, feedback: feedback) },
            onUnapprove: { ProspectMutations.setStatus(item, .drafted, nil, prospects: prospects, context: context, feedback: feedback) },
            onSkipDraft: { ProspectMutations.setStatus(item, .dismissed, .notInterested, prospects: prospects, context: context, feedback: feedback) },
            onSaveDraft: { subject, body in ProspectMutations.saveDraft(item, subject, body, prospects: prospects, context: context, feedback: feedback) },
            onSetLostReason: { reason in ProspectMutations.setLostReason(item, reason, prospects: prospects, context: context, feedback: feedback) },
            onSend: { requestSend(item) },
            onSetConversationState: { state in ProspectMutations.setConversationState(item, state, prospects: prospects, context: context, feedback: feedback) },
            onConfirmConversationState: { ProspectMutations.confirmConversationState(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissReply: { ProspectMutations.dismissReply(item, prospects: prospects, context: context, feedback: feedback) },
            onMarkContact: { rid, resolution, bounced in
                ProspectMutations.markContact(item, rid, resolution, bounced, prospects: prospects, context: context, feedback: feedback)
            },
            onDismissContactReply: { rid in ProspectMutations.dismissContactReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDraftReply: { rid in ProspectMutations.draftReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onSendReply: { rid in sendReply(item, rid) },
            onCopyReply: { rid in ProspectMutations.copyReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onEditReplyDraft: { rid, body in ProspectMutations.editReplyDraft(item, rid, body, prospects: prospects, context: context, feedback: feedback) },
            onMarkConfidenceReviewed: { ProspectMutations.markConfidenceReviewed(item, prospects: prospects, context: context, feedback: feedback) },
            onCorrectClassification: { d, p in
                ProspectMutations.correctClassification(item, discipline: d, production: p, prospects: prospects, context: context, feedback: feedback)
            },
            onConfirmBooking: { ProspectMutations.confirmBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissBookingSuggestion: { ProspectMutations.dismissBookingSuggestion(item, prospects: prospects, context: context, feedback: feedback) },
            onRejectBooking: { ProspectMutations.rejectBooking(item, prospects: prospects, context: context, feedback: feedback) },
            gmailConnected: GmailAuthManager.shared.isConnected,
            outboundSendSince: outboundSending[item.id],
            replySendSince: { rid in replySending[rid] },
            onRestore: item.status == .dismissed ? { restore(item) } : nil
        )
        let highlighted = highlightedKey == item.id
        let framed = row
            .padding(highlighted ? OVSpacing.sm : 0)
            .background(highlighted ? OVColor.gold.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .id(item.id)
        if let model, model.sentAt != nil, model.originalDraftBody != nil {
            return AnyView(framed.contextMenu {
                Button(model.excludedFromVoiceLearning ? "Learn from this email again"
                                                       : "Don't learn from this email") {
                    ProspectMutations.toggleVoiceLearning(item, prospects: prospects, context: context, feedback: feedback)
                }
            })
        }
        return AnyView(framed)
    }

    private func restore(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        DismissedProspects.restore(model)
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.restored(org: item.groupName))
        }
    }

    private var sendConfirmBinding: Binding<Bool> {
        Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })
    }

    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingSend(id: item.id, confirmation: confirmation)
    }

    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        ProspectMutations.performSend(naturalKey, prospects: prospects, context: context, feedback: feedback,
                                      markSending: { outboundSending[$0] = Date() },
                                      clearSending: { outboundSending[$0] = nil },
                                      onNeedsReconnect: { showReconnect = true })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { replySending[$0] = Date() },
                                    clearSending: { replySending[$0] = nil },
                                    onNeedsReconnect: { showReconnect = true })
    }
}
```

- [ ] **Step 5: Regenerate the Xcode project and run tests**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && xcodegen generate && ./scripts/run-tests-locked.sh
```
Expected: build succeeds (RootView still references `DismissedView`/`showDismissed`/`dismissed` at this point and will fail; if so, this is expected and resolved by Task 8, which must be done before this build is clean). If Task 8 has not yet been done, skip full suite verification here and proceed directly to Task 8, then return to Step 6 below once both tasks are complete.

- [ ] **Step 6: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add -A mac/Overture/UI/ArchiveView.swift mac/OvertureTests/ArchiveViewRestoreSaveGuardTests.swift mac/OvertureTests/SaveOrWarnConsolidationGuardTests.swift && git rm mac/Overture/UI/DismissedView.swift mac/OvertureTests/DismissedViewRestoreSaveGuardTests.swift && git commit -m "Add ArchiveView, replacing DismissedView"
```

(This commit will not build in isolation, since `RootView.swift` still references the deleted `DismissedView`; Task 8 fixes that. If the plan is executed by separate subagents per task, land Task 7 and Task 8 as one combined review before merging, or squash them.)

---

### Task 8: Wire Archive and global search into RootView

**Files:**
- Modify: `mac/Overture/App/RootView.swift`

**Interfaces:**
- Consumes: `ArchiveView` (Task 7), `ShowSearchField` (Task 6), `QueueModel.isReachableInQueue` (Task 3), `ReachedOutQueue.active` (existing).
- Produces: no new interface; this is the final wiring task.

- [ ] **Step 1: Remove the Dismissed query, state, sheet, and toolbar button**

In `mac/Overture/App/RootView.swift`, delete the `dismissed` query:

```swift
    // Dismissed prospects, for the restore-from-dismissed view (#28).
    @Query(filter: #Predicate<Prospect> { $0.statusRaw == "dismissed" })
    private var dismissed: [Prospect]
```

Change:

```swift
    @State private var showDismissed = false
```

to:

```swift
    @State private var showArchive = false
    @State private var archiveJumpKey: String?
    @State private var searchQuery: String = ""
```

Delete the Dismissed toolbar button:

```swift
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showDismissed = true
                    } label: {
                        ToolbarHoverLabel(title: dismissed.isEmpty ? "Dismissed" : "Dismissed (\(dismissed.count))",
                                          systemImage: "archivebox")
                    }
                    .help("See dismissed prospects and restore any you cut by mistake")
                }
```

Replace it with:

```swift
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        archiveJumpKey = nil
                        showArchive = true
                    } label: {
                        ToolbarHoverLabel(title: "Archive", systemImage: "archivebox")
                    }
                    .help("Every show Overture has ever tracked: past its window, booked, closed, or dismissed")
                }
```

Change:

```swift
            .sheet(isPresented: $showDismissed) { DismissedView() }
```

to:

```swift
            .sheet(isPresented: $showArchive) {
                ArchiveView(initialHighlightKey: archiveJumpKey, onConnectGmail: connectGmail)
            }
```

- [ ] **Step 2: Add the reachability computed properties and the search selection handler**

Add these computed properties and this method to `RootView` (near `followUpsDue`):

```swift
    private var nonDismissedProspects: [Prospect] { allProspects.filter { $0.status != .dismissed } }

    private var searchableItems: [QueueItem] { allProspects.map(QueueItem.init) }

    // #NEW: whether picking a global search result should jump into the Queue (#236's existing
    // deep link mechanism) or open Archive with that row forced into view instead. A dismissed
    // show never renders in the Queue at all, so it always routes to Archive.
    private func handleSearchSelection(_ item: QueueItem) {
        let reachedOutKeys = Set(ReachedOutQueue.active(from: nonDismissedProspects, now: Date()).map(\.naturalKey))
        if item.status != .dismissed,
           QueueModel.isReachableInQueue(item, reachedOutKeys: reachedOutKeys, today: QueueModel.easternToday()) {
            deepLinkedKey = item.id
        } else {
            archiveJumpKey = item.id
            showArchive = true
        }
    }
```

- [ ] **Step 3: Add the global search field to the toolbar**

Add a new `ToolbarItem` inside the existing `.toolbar { ... }` block, placed right after the status `ToolbarItem(placement: .status) { ... }` block:

```swift
                ToolbarItem(placement: .principal) {
                    ShowSearchField(query: $searchQuery, allItems: searchableItems) { result in
                        handleSearchSelection(result)
                    }
                }
```

- [ ] **Step 4: Regenerate the Xcode project and run tests**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && xcodegen generate && ./scripts/run-tests-locked.sh
```
Expected: full suite green, including the guard tests updated in Task 7.

- [ ] **Step 5: Commit**

```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture" && git add mac/Overture/App/RootView.swift && git commit -m "Wire Archive and global search into RootView, replacing the Dismissed button"
```

- [ ] **Step 6: Build and launch, verify visually**

Run:
```bash
cd "/Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac" && ./build-install.sh --launch
```

Manually confirm, in the launched app:
1. The toolbar shows a search field and an "Archive" button (no more "Dismissed" button).
2. Typing an org name Dan has pitched shows a dropdown; clicking a result that is currently in the Queue's date window scrolls to and briefly highlights that row in the Queue.
3. Typing the name of a show that is past its window, booked, closed, or dismissed and clicking it opens Archive with that row scrolled to, highlighted, and its status included in the active filter chips.
4. Opening Archive directly (the toolbar button) defaults to the New and Active filter chips only; toggling any other chip (Closed (not now), Closed (not interested), Booked, Dismissed) independently adds or removes that bucket.
5. A dismissed row in Archive shows "Dismissed" and a "Restore" button (not Keep/Dismiss); clicking Restore removes it from Archive's current filtered view (since its status is no longer Dismissed) and it reappears in the main Queue.
6. The Mark menu, Send, and booking confirm/reject actions on an Archive row work identically to the same actions in the main Queue.

---

## Self-Review

**Spec coverage:**
- Persistent search bar, matches org/act name, venue, contact name/email, across every show: Task 5 (`ShowSearch`), Task 6 (`ShowSearchField`), Task 8 (wired into RootView's toolbar).
- Dropdown of matches, click jumps to Queue if visible there, else opens Archive highlighted: Task 3 (`isReachableInQueue`), Task 6 (`ShowSearchField`'s dropdown), Task 8 (`handleSearchSelection`), Task 7 (`ArchiveView.onAppear`/`.task` highlight and scroll).
- Archive replaces Dismissed, independent status checkboxes defaulting to New + Active, sorted by most recent event date: Task 4 (`ArchiveStatus`), Task 7 (`ArchiveView`'s `activeStatuses`/`filtered`).
- Archive rows are the exact same expandable row as the Queue (Mark menu, Restore, etc.): Task 1 (`ProspectMutations`), Task 2 (Queue refactor to prove no behavior change), Task 6 (`ProspectRowView.onRestore`), Task 7 (`ArchiveView.row`).
- Archive has its own search field reusing the same matcher: Task 7 (`ArchiveView` embeds `ShowSearchField`).
- Queue's own behavior unchanged: Task 2 is a pure refactor verified by the existing suite; no windowing/filter logic in `QueueView.swift` changes.
- No new data model or backend changes: confirmed throughout; every new file is either pure domain logic (`ArchiveStatus`, `ShowSearch`) or SwiftUI/UI glue over existing `Prospect`/`Recipient`/`QueueItem` fields.

**Placeholder scan:** every step contains complete code; no TBD/TODO, no "add appropriate handling," no bare descriptions without code.

**Type consistency:** `ProspectMutations`'s function signatures (Task 1) match exactly what `QueueView` (Task 2) and `ArchiveView` (Task 7) call. `PendingSend` (Task 1) replaces `QueueView`'s private `PendingConfirm` (Task 2) and is reused as is by `ArchiveView` (Task 7). `ArchiveStatus.of(_:)` (Task 4) takes a `QueueItem`, matching what `ArchiveView.filtered` (Task 7) and the guard test both pass. `ShowSearch.matches(_:query:)` (Task 5) takes a `QueueItem`, matching `ShowSearchField` (Task 6) and `ArchiveView` (Task 7). `ProspectRowView.onRestore` (Task 6) is `(() -> Void)?`, matching how `ArchiveView.row` (Task 7) constructs it (`item.status == .dismissed ? { restore(item) } : nil`).
