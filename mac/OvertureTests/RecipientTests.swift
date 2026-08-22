import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let recipientTestsGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// One party emailed for a performance. Multiple per performance, each with its own send state and
// engagement. The behaviors that matter to the rest of the system: who is "silent" (the only ones
// that get follow-ups), the provenance/send-state mapping, and a clean Codable round-trip (it is
// stored as a JSON blob on Prospect).
@Suite("Recipient")
struct RecipientTests {
    private func sent(replied: Bool = false, bounced: Bool = false) -> Recipient {
        var r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = replied
        r.bounced = bounced
        return r
    }

    @Test func aSentUnansweredRecipientIsSilent() {
        #expect(sent().isSilent)
    }

    @Test func aPendingRecipientIsNotSilent() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.sendState == .pending)
        #expect(!r.isSilent)
    }

    @Test func aRepliedRecipientIsNotSilent() {
        #expect(!sent(replied: true).isSilent)
    }

    @Test func aBouncedRecipientIsNotSilent() {
        #expect(!sent(bounced: true).isSilent)
    }

    @Test func firstNameUsesTheSharedSalutationHelper() {
        var r = Recipient(id: "x", email: "x@act.example", provenance: .act)
        r.name = "Nora Calder"
        #expect(r.firstName == "Anna")
    }

    @Test func provenanceAndSendStateRoundTripThroughRawStrings() {
        var r = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        r.sendState = .suppressed
        #expect(r.provenance == .presenter)
        #expect(r.provenanceRaw == "presenter")
        #expect(r.sendState == .suppressed)
        #expect(r.sendStateRaw == "suppressed")
    }

    @Test func contactSourceURLDefaultsToNilAndRoundTripsThroughInit() {
        let noSource = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(noSource.contactSourceURL == nil)

        let withSource = Recipient(id: "b@act.example", email: "b@act.example", provenance: .act,
                                   contactSourceURL: "https://act.example/about/staff")
        #expect(withSource.contactSourceURL == "https://act.example/about/staff")
    }

    // #542: every suppression that predates this field (all of them were booking-freezes) has no raw
    // value stored, so it must read as .bookedElsewhere rather than an unrepresentable nil, or the
    // label for Dan's existing live data would break.
    @Test func suppressionReasonDefaultsToBookedElsewhereWhenNeverSet() {
        let r = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        #expect(r.suppressionReasonRaw == nil)
        #expect(r.suppressionReason == .bookedElsewhere)
    }

    @Test func suppressionReasonRoundTripsThroughRawStrings() {
        var r = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        r.suppressionReason = .declined
        #expect(r.suppressionReason == .declined)
        #expect(r.suppressionReasonRaw == "declined")
    }

    // Recipient is now a SwiftData @Model (#409): state persists through the store, not a JSON blob.
    @Test func persistsThroughTheStore() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .manual)
        r.name = "Virgile Roche"
        r.sendState = .sent
        r.replied = true
        r.gmailThreadId = "t1"
        ctx.insert(r)
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Recipient>()).first
        #expect(back?.name == "Virgile Roche")
        #expect(back?.sendState == .sent)
        #expect(back?.replied == true)
        #expect(back?.gmailThreadId == "t1")
        #expect(back?.provenance == .manual)
    }

    // A form-only contact (#368, the Ivalas Quartet case) has no published email, only a contact
    // form. It still becomes a recipient so it shows in the list and can be tracked; its id is the
    // form URL (not an email), so the SAME recipient is kept when Dan fills in an email later.
    @Test func aFormOnlyRecipientHasNoEmailAndAStableFormId() {
        let id = Recipient.makeId(email: nil, formURL: "https://www.ivalasquartet.com/contact")
        let r = Recipient(id: id!, email: nil, provenance: .act,
                          contactFormURL: "https://www.ivalasquartet.com/contact")
        #expect(r.email == nil)
        #expect(r.id == "form:https://www.ivalasquartet.com/contact")
    }

    // The id is the canonicalized email when there is one, the form URL otherwise, and nil when
    // there is neither (nothing to make a recipient from).
    @Test func makeIdPrefersTheCanonicalizedEmailThenTheForm() {
        #expect(Recipient.makeId(email: "Erobinson@Aurora.Example", formURL: "x") == "erobinson@aurora.example")
        #expect(Recipient.makeId(email: nil, formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: "", formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: nil, formURL: nil) == nil)
    }

    // A1b (#418): a per-recipient manual-outcome source, mirroring Prospect.outcomeSourceRaw, so
    // detection can tell "Dan judged this contact by hand" from "auto". nil = no manual mark.
    @Test func outcomeSourceMapsThroughRawString() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.outcomeSource == nil)
        #expect(r.outcomeSourceRaw == nil)
        r.outcomeSource = .manual
        #expect(r.outcomeSourceRaw == "manual")
        r.outcomeSourceRaw = "auto"
        #expect(r.outcomeSource == .auto)
    }

    // C0 (#420): the AI inbound-reply drafter writes a per-recipient draft + a non-binding intent hint;
    // replyDraftRequestedAt drives the request-response progress + needs-attention timeout. All additive.
    @Test func replyDraftFieldsRoundTripAndDefaultEmpty() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.replyDraftSubject == nil)
        #expect(r.replyDraftBody == nil)
        #expect(r.replyDraftRequestedAt == nil)
        #expect(r.intentHint == nil)

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        r.replyDraftSubject = "Re: Photographing the Clarion Choir"
        r.replyDraftBody = "Thanks for getting back to me. July 4 works well..."
        r.replyDraftRequestedAt = when
        r.intentHint = "wants_to_book"
        #expect(r.replyDraftSubject == "Re: Photographing the Clarion Choir")
        #expect(r.replyDraftBody?.hasPrefix("Thanks") == true)
        #expect(r.replyDraftRequestedAt == when)
        #expect(r.intentHint == "wants_to_book")
    }

    // A4 (#418): reply-triage auto-pause is its OWN flag, distinct from sendState .suppressed
    // (which means booking-freeze). Defaults off.
    @Test func pausedByReplyDefaultsOff() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.pausedByReply == false)
        r.pausedByReply = true
        #expect(r.pausedByReply == true)
    }

    // #423 E — editing one contact's AI reply draft persists to that contact and leaves others alone
    // (the substance of QueueView.editReplyDraft: updateRecipient { replyDraftBody = ... } + save).
    @MainActor
    @Test func editingAReplyDraftPersistsAndIsolates() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let a = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act); a.replyDraftBody = "AI draft A"
        let b = Recipient(id: "b@p.example", email: "b@p.example", provenance: .presenter); b.replyDraftBody = "AI draft B"
        p.setRecipients([a, b])
        try ctx.save()

        p.updateRecipient(id: "a@act.example") { $0.replyDraftBody = "Dan's edit" }
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(back?.recipients.first { $0.id == "a@act.example" }?.replyDraftBody == "Dan's edit")
        #expect(back?.recipients.first { $0.id == "b@p.example" }?.replyDraftBody == "AI draft B")
    }

    // #459 — editing the AI reply draft marks it as Dan's, the same way Prospect.applyEdit does for the
    // cold draft, so the deterministic DraftCheck warnings stop nagging on text he already owns.
    @Test func editingAReplyDraftMarksItEditedByDan() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftBody = "AI draft"
        #expect(r.replyDraftEditedByDan == false)
        r.applyReplyDraftEdit("Dan's edited reply.")
        #expect(r.replyDraftBody == "Dan's edited reply.")
        #expect(r.replyDraftEditedByDan == true)
    }

    // Dismissing a wrongly-detected reply wipes the draft, so the edited flag must reset too — otherwise
    // a later AI draft would inherit a stale "edited" mark and wrongly suppress its warnings.
    @Test func dismissingAnAutoReplyClearsTheReplyDraftEditedFlag() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replied = true
        r.applyReplyDraftEdit("Dan's edited reply.")
        r.dismissAutoReply()
        #expect(r.replyDraftEditedByDan == false)
    }

    // #398: dismissing a wrongly auto-detected bounce reverts it and remembers the wrong
    // bounce message's id, mirroring dismissAutoReply, so a genuinely new bounce still flags.
    @Test func dismissingAnAutoBounceRevertsItAndRemembersTheMessageId() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.bounced = true
        r.lastBounceId = "bounce-1"
        r.dismissAutoBounce()
        #expect(r.bounced == false)
        #expect(r.dismissedBounceId == "bounce-1")
    }

    @Test func dismissingWhenNotBouncedIsANoOp() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.dismissAutoBounce()
        #expect(r.bounced == false)
        #expect(r.dismissedBounceId == nil)
    }

    @Test func isAutoBouncedIsTrueOnlyForAnAutoDetectedBounce() {
        // RecipientSnapshot's core fields are `let`, so this builds two snapshots (one per
        // outcomeSource) rather than mutating a single instance in place.
        func snapshot(source: OutcomeSource?) -> RecipientSnapshot {
            RecipientSnapshot(id: "a@act.example", name: nil, email: "a@act.example",
                              role: nil, provenance: .act, sendState: .sent,
                              replied: false, lastReplyText: nil, resolution: nil,
                              bounced: true, outcomeSource: source)
        }
        #expect(snapshot(source: nil).isAutoBounced == true)
        #expect(snapshot(source: .manual).isAutoBounced == false)
    }

    // #656: a soft/temporary Gmail delay notice is a quiet, purely informational hint, never a
    // state change, so it must fade on its own (Gmail never tells us a delay resolved) and must
    // never show once something more definite (a bounce, a reply, or a resolution) applies.
    private func delaySnapshot(delayNoticeAt: Date?, bounced: Bool = false, replied: Bool = false,
                               resolution: RecipientResolution? = nil) -> RecipientSnapshot {
        RecipientSnapshot(id: "a@act.example", name: nil, email: "a@act.example",
                          role: nil, provenance: .act, sendState: .sent,
                          replied: replied, lastReplyText: nil, resolution: resolution,
                          bounced: bounced, outcomeSource: nil, delayNoticeAt: delayNoticeAt)
    }

    @Test func hasRecentDeliveryDelayIsTrueJustAfterTheNotice() {
        let s = delaySnapshot(delayNoticeAt: Date(timeIntervalSince1970: 1000))
        #expect(s.hasRecentDeliveryDelay(now: Date(timeIntervalSince1970: 1000 + 60)))
    }

    @Test func hasRecentDeliveryDelayFadesAfterTheWindow() {
        let s = delaySnapshot(delayNoticeAt: Date(timeIntervalSince1970: 0))
        let pastTheWindow = Date(timeIntervalSince1970: 0).addingTimeInterval(RecipientSnapshot.deliveryDelayWindow + 1)
        #expect(!s.hasRecentDeliveryDelay(now: pastTheWindow))
    }

    @Test func hasRecentDeliveryDelayIsFalseWithNoNotice() {
        let s = delaySnapshot(delayNoticeAt: nil)
        #expect(!s.hasRecentDeliveryDelay(now: Date(timeIntervalSince1970: 1000)))
    }

    @Test func hasRecentDeliveryDelayIsFalseOnceBounced() {
        let s = delaySnapshot(delayNoticeAt: Date(timeIntervalSince1970: 1000), bounced: true)
        #expect(!s.hasRecentDeliveryDelay(now: Date(timeIntervalSince1970: 1000 + 60)))
    }

    @Test func hasRecentDeliveryDelayIsFalseOnceReplied() {
        let s = delaySnapshot(delayNoticeAt: Date(timeIntervalSince1970: 1000), replied: true)
        #expect(!s.hasRecentDeliveryDelay(now: Date(timeIntervalSince1970: 1000 + 60)))
    }

    @Test func hasRecentDeliveryDelayIsFalseOnceResolved() {
        let s = delaySnapshot(delayNoticeAt: Date(timeIntervalSince1970: 1000), resolution: .booked)
        #expect(!s.hasRecentDeliveryDelay(now: Date(timeIntervalSince1970: 1000 + 60)))
    }

    private func confidenceSnapshot(confidence: ContactConfidence?, sourceURL: String?) -> RecipientSnapshot {
        RecipientSnapshot(id: "a@act.example", name: "Emma", email: "a@act.example",
                          role: nil, provenance: .act, sendState: .pending,
                          replied: false, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil,
                          contactConfidence: confidence, contactSourceURL: sourceURL)
    }

    @Test func contactSourceLinkURLIsSetForHighConfidenceWithAValidURL() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == URL(string: "https://act.example/about/staff"))
    }

    @Test func contactSourceLinkURLIsNilForMediumConfidenceEvenWithAURL() {
        let s = confidenceSnapshot(confidence: .medium, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilForLowConfidenceEvenWithAURL() {
        let s = confidenceSnapshot(confidence: .low, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilWhenNoSourceURLIsSet() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: nil)
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilForAnUnparseableURL() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: "not a url")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilForAnEmptyStringSourceURL() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: "")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilWhenConfidenceIsNotSet() {
        let s = confidenceSnapshot(confidence: nil, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == nil)
    }

    // #463 — the reply-draft voice pair, mirroring the cold path (Prospect.originalDraft*/sentBody). The
    // first substantive edit snapshots the AI original; the committed copy is frozen at send / copy-out so
    // a later re-draft can't rewrite the lesson.
    @Test func editingAReplySnapshotsTheAIOriginalOnce() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftBody = "AI reply draft."
        r.applyReplyDraftEdit("Dan's rewritten reply, much warmer.")
        #expect(r.originalReplyDraftBody == "AI reply draft.")     // baseline captured
        r.applyReplyDraftEdit("Dan tweaks it again.")
        #expect(r.originalReplyDraftBody == "AI reply draft.")     // baseline not overwritten by later edits
    }

    @Test func aWhitespaceOnlyReplyEditDoesNotSnapshot() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftBody = "AI reply draft."
        r.applyReplyDraftEdit("AI reply draft.   ")   // only trailing whitespace differs
        #expect(r.originalReplyDraftBody == nil)
    }

    @Test func recordAnswerSentFreezesTheSentReply() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replyDraftBody = "AI reply draft."
        r.applyReplyDraftEdit("Dan's committed reply text.")
        r.recordAnswerSent(now: Date(timeIntervalSince1970: 7))
        #expect(r.sentReplyBody == "Dan's committed reply text.")
        #expect(r.replySentAt == Date(timeIntervalSince1970: 7))
        #expect(r.replyDraftBody == nil)   // still consumed
    }

    // #459 — the reply-draft self-check is shown on an AI draft but suppressed once Dan edits it, the
    // same suppression the cold path applies. This is the behavior the reply view renders.
    private func snapshot(body: String, edited: Bool) -> RecipientSnapshot {
        RecipientSnapshot(id: "a", name: "N", email: "a@a.example", role: nil, provenance: .act,
                          sendState: .sent, replied: true, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil, replyDraftBody: body,
                          replyDraftEditedByDan: edited)
    }

    @Test func replyDraftWarningsShowOnAnAIDraftAndVanishOnceEdited() {
        let asksKnownDate = "Great — let me know the date and I'll be there."
        let aiDraft = snapshot(body: asksKnownDate, edited: false)
        #expect(aiDraft.replyDraftFindings(knownsDate: true, knownsVenue: false).contains { $0 == .asksForKnownFact })
        let dansEdit = snapshot(body: asksKnownDate, edited: true)
        #expect(dansEdit.replyDraftFindings(knownsDate: true, knownsVenue: false).isEmpty)
    }

    // #418 B2 — manual-judge marking stamps the manual source flag (so detection won't overwrite) and
    // maps the locked vocabulary onto resolution + bounced with no new enum.
    @Test func manualMarkingMapsTheLockedVocabularyAndStampsManualSource() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)

        r.markOutcomeManually(resolution: .booked)                 // Booked (attribution only)
        #expect(r.resolution == .booked)
        #expect(r.bounced == false)
        #expect(r.outcomeSource == .manual)

        r.markOutcomeManually(resolution: .declinedSoft)           // Closed-not-now
        #expect(r.resolution == .declinedSoft)

        r.markOutcomeManually(resolution: .declinedHard)           // Closed-no
        #expect(r.resolution == .declinedHard)

        r.markOutcomeManually(resolution: nil, bounced: true)      // Bounced
        #expect(r.resolution == nil)
        #expect(r.bounced == true)

        r.markOutcomeManually(resolution: nil)                     // In conversation
        #expect(r.resolution == nil)
        #expect(r.bounced == false)
        #expect(r.outcomeSource == .manual)                        // still stamped manual
    }

    // #418 B2↔A2 — a hand-marked contact is never overwritten by auto reply detection.
    @MainActor
    @Test func aManuallyMarkedContactIsNotOverwrittenByDetection() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date()
        ctx.insert(p)
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.gmailThreadId = "t1"; r.sendState = .sent
        r.markOutcomeManually(resolution: .declinedHard)   // Dan judged: not interested
        p.addRecipient(r)

        let reply = recipientTestsGmail.thread([.init(from: "them@org.org")])
        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date()) { _ in reply }
        #expect(n == 0)                          // detection skips the hand-marked contact
        #expect(r.resolution == .declinedHard)   // Dan's call stands
        #expect(r.replied == false)
    }

    // #418 B1 — the conversation-surface action path: marking ONE contact locates exactly that
    // recipient, applies the manual mark, persists it, and leaves the other contacts untouched (the
    // substance of QueueView.markContact, which is `updateRecipient(id:) { markOutcomeManually }` + save).
    @MainActor
    @Test func markingOneContactLocatesPersistsAndLeavesOthersUntouched() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date()
        ctx.insert(p)
        let a = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act); a.sendState = .sent
        let b = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter); b.sendState = .sent
        p.setRecipients([a, b])
        try ctx.save()

        // Mark only contact B booked (attribution).
        p.updateRecipient(id: "b@present.example") { $0.markOutcomeManually(resolution: .booked) }
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(back?.recipients.first { $0.id == "b@present.example" }?.resolution == .booked)
        #expect(back?.recipients.first { $0.id == "b@present.example" }?.outcomeSource == .manual)
        #expect(back?.recipients.first { $0.id == "a@act.example" }?.resolution == nil)   // others untouched
        #expect(back?.recipients.first { $0.id == "a@act.example" }?.outcomeSource == nil)
        // The lead booking is NOT set by a recipient attribution mark (decision g).
        #expect(back?.outcome != .booked)
    }

    // Per-recipient resolution (#389 derived-outcome model): an additive field capturing the
    // terminal commercial outcomes that aren't inferable from send/reply/bounce state. Phase 5
    // reads it to derive the performance status; here we only pin that it round-trips.
    @Test func dismissingAReplyAlsoClearsTheStaleIntentHintAndDraft() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 1_700_000_000)
        r.lastReplyId = "msg-1"
        r.lastReplyText = "Sure, let's talk."
        r.intentHint = "wants_to_book"
        r.replyDraftSubject = "Re: Photographing the Clarion Choir"
        r.replyDraftBody = "Thanks for getting back to me..."
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 1_700_000_100)

        r.dismissAutoReply()

        // The reply is gone, so its derived hint + draft must go too (#449).
        #expect(r.replied == false)
        #expect(r.dismissedReplyId == "msg-1")
        #expect(r.intentHint == nil)
        #expect(r.replyDraftSubject == nil)
        #expect(r.replyDraftBody == nil)
        #expect(r.replyDraftRequestedAt == nil)
    }

    @Test func aPausedContactIsNotSendable() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.isSendablePending)          // pending with an email
        r.pausedByReply = true
        #expect(!r.isSendablePending)         // paused pending a reply triage (#430)
    }

    // #407: a recipient with no prospect wired at all (every existing bare-Recipient test in this
    // file) must stay governed by its own state alone, never blocked by a flag it has no way to see.
    // #2545: renamed off the retired salutation gate onto the guards that actually exist now. A bare
    // recipient with no show wired to it has no body to judge, so every draft-level hold, the greeting
    // one included, must leave it alone rather than blocking on text it cannot see.
    @Test func aRecipientWithNoProspectIsUnaffectedByTheDraftLevelGates() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.prospect == nil)
        #expect(r.isSendablePending)
    }

    // #2545 RETIRED the two #407 salutation-review tests that sat here, and the reason is worth keeping
    // rather than just deleting them. Both set `draftNeedsSalutationReview = true` BY HAND in the fixture.
    // Nothing in the app has set that flag true since #2010 stopped the launch pass rewriting bodies, so
    // the block they asserted could never fire in production: they passed on a value only they wrote
    // (L90). The flag, its override and the hold are gone.
    //
    // What SURVIVES is the rule the second one encoded, that an override is pinned to the exact text it
    // was taken on so a later edit re-arms the block. That is now the greeting hold's override, and it is
    // covered by GreetingLivesInTheBodyTests.theoverrideClearsTheHoldForThatExactBodyOnly.

    // #388: a recipient flagged as looking like the venue is blocked until Dan dismisses that
    // specific guess; the flag lives on the RECIPIENT itself, not the performance.
    @Test func aVenueMatchFlagBlocksOnlyThatRecipientUntilDismissed() {
        let r = Recipient(id: "a@carnegiehall.example", email: "a@carnegiehall.example", provenance: .act)
        #expect(r.isSendablePending)

        r.looksLikeVenue = true
        #expect(!r.isSendablePending)

        r.looksLikeVenueDismissed = true
        #expect(r.isSendablePending)
    }

    // #722: same shape as the venue-match gate above, for a suspected press/media contact.
    @Test func aPressContactFlagBlocksOnlyThatRecipientUntilDismissed() {
        let r = Recipient(id: "press@venue.example", email: "press@venue.example", provenance: .act)
        #expect(r.isSendablePending)

        r.looksLikePressContact = true
        #expect(!r.isSendablePending)

        r.looksLikePressContactDismissed = true
        #expect(r.isSendablePending)
    }

    @Test func looksLikeDuplicateContactDefaultsToFalse() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.looksLikeDuplicateContact == false)
        #expect(r.looksLikeDuplicateContactDismissed == false)
    }

    @Test func aRecipientFlaggedAsDuplicateIsNotSendableUntilDismissed() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.looksLikeDuplicateContact = true
        #expect(r.isSendablePending == false)
        r.looksLikeDuplicateContactDismissed = true
        #expect(r.isSendablePending == true)
    }

    @MainActor
    @Test func aReplyPausesTheShowsStillPendingContacts() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date()
        ctx.insert(p)
        let sent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        sent.gmailThreadId = "t1"; sent.sendState = .sent
        let pending = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        pending.sendState = .pending   // never emailed yet
        p.setRecipients([sent, pending])

        let reply = recipientTestsGmail.thread([.init(from: "them@org.org")])
        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date()) { _ in reply }
        #expect(n == 1)                        // the act's reply detected
        #expect(sent.replied == true)
        #expect(pending.pausedByReply == true) // the still-unsent contact auto-paused (#430)
        #expect(!pending.isSendablePending)    // so the drip/queue won't email it
    }

    @Test func aReplyDraftStallsOnlyAfterTheTimeoutWithNoDraft() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let requested = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!r.isReplyDraftStalled(now: requested))   // no request yet

        r.replyDraftRequestedAt = requested
        #expect(!r.isReplyDraftStalled(now: requested.addingTimeInterval(60)))   // still within timeout
        #expect(r.isReplyDraftStalled(now: requested.addingTimeInterval(Recipient.replyDraftStallTimeout)))  // dead run (#431)

        r.replyDraftBody = "Here's a draft."                // the draft landed
        #expect(!r.isReplyDraftStalled(now: requested.addingTimeInterval(3600)))  // no longer stalled
    }

    // #471: the fixed wall-clock timeout alone can't distinguish a genuinely dead run from a slow one
    // still working; `runAlive` (the classify run's real heartbeat) must override it.
    @Test func aReplyDraftPastTimeoutIsNotStalledWhileTheRunIsAlive() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let requested = Date(timeIntervalSince1970: 1_700_000_000)
        r.replyDraftRequestedAt = requested

        #expect(!r.isReplyDraftStalled(now: requested.addingTimeInterval(6 * 60), runAlive: true))
        #expect(r.isReplyDraftStalled(now: requested.addingTimeInterval(6 * 60), runAlive: false))
        #expect(!r.isReplyDraftStalled(now: requested.addingTimeInterval(3 * 60), runAlive: false))
    }

    // #475/#476: a send claims .sending before the network call; if the app never comes back to
    // resolve it (crash, or a save that never landed), it must read as stuck after a timeout rather
    // than sit invisibly forever or look like any other in-flight send.
    @Test func aSendIsStuckOnlyAfterTheTimeoutWhileStillClaimed() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let claimed = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!r.isSendStuck(now: claimed))   // never claimed

        r.sendState = .sending
        r.sendClaimedAt = claimed
        #expect(!r.isSendStuck(now: claimed.addingTimeInterval(30)))   // still within the window
        #expect(r.isSendStuck(now: claimed.addingTimeInterval(RunTimeouts.send)))   // stuck

        r.sendState = .sent
        #expect(!r.isSendStuck(now: claimed.addingTimeInterval(3600)))   // resolved, no longer stuck
    }

    @Test func resolutionMapsThroughRawString() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.resolution == nil)
        r.resolution = .declinedSoft
        #expect(r.resolutionRaw == "declined_soft")
        r.resolutionRaw = "booked"
        #expect(r.resolution == .booked)
    }

    // #587 (#366 Phase 2): a named individual performer, distinct from `.act` (a single-act waterfall
    // result), gets its own provenance so the UI never mislabels a named person as "the act".
    @Test func performerProvenanceRoundTripsThroughRawStrings() {
        var r = Recipient(id: "p@performer.example", email: "p@performer.example", provenance: .performer)
        #expect(r.provenance == .performer)
        #expect(r.provenanceRaw == "performer")
        r.provenanceRaw = "performer"
        #expect(r.provenance == .performer)
    }

    // Performer and the single-act waterfall result are mutually exclusive per performance (never
    // both used at once), so they tie for first send position.
    @Test func performerTiesWithActForFirstSendOrder() {
        let performer = Recipient(id: "p@performer.example", email: "p@performer.example", provenance: .performer)
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(performer.sendOrderRank == act.sendOrderRank)
        #expect(performer.sendOrderRank == 0)
    }

    @Test func remindLaterStampsTheReanchor() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.remindLater(now: now)
        #expect(r.conversationRemindedAt == now)
    }
}
