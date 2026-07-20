import Foundation
import SwiftData

// Pure view-model helpers for the approval queue: labels, badges, timing hints,
// and date groupings. Ported from the engine's queueView.ts so the display logic
// is identical across the (retired) web app and this native app, and unit-testable
// without SwiftData. The SwiftUI views build QueueItem values from Prospect models.

struct QueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let groupName: String
    let discipline: String
    let venue: String?
    let performanceDate: String?
    let sourceListingURL: String?
    let websiteURL: String?
    // #970: the page's own words for where the show is, unresolved. The geo verdict is derived from
    // this and the discipline, never stored, so a rule change re-decides every row at once.
    var location: String? = nil
    let priorRelationship: String
    let production: String
    let profile: String
    let coverage: String
    let fitScore: Int
    let tier: String
    let fitReason: String
    let matchedClientName: String?
    let possibleMatchSource: String?
    let possibleMatchName: String?
    let status: ReviewStatus
    // #864: why it was dismissed, when it was. `wentBy` is Overture's own: the show's last night
    // passed while it sat untriaged. Archive needs it to keep a retirement apart from a cut Dan made.
    var dismissReason: DismissReason? = nil

    // Trigger 2: the drafted email, when present. Contact identity (name/role/email/confidence/
    // method/form URL) lives per-recipient on `contacts` now (#654); see `primaryContact`.
    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftEditedByDan: Bool = false
    // #846: which model wrote this draft (Prospect.draftModel). Read via draftTraceLabel below.
    var draftModel: String? = nil
    var outcome: Outcome = .noResponse
    // Phase F (#424): the show's status derived from its contacts, snapshotted at build time.
    var performanceStatus: PerformanceStatus = .new
    var sentAt: Date? = nil
    // At least one recipient is still pending with an address, so this performance can still send (#394).
    // Drives the Send button under fan-out: the lead `sentAt` rollup flips on the FIRST recipient, but
    // the button must persist until the LAST recipient goes, so it gates on this, not on `isSent`.
    var hasPendingRecipient: Bool = false
    // #792: contacts on this show held back by a review guard, each waiting on one glance from Dan. A
    // show can be genuinely Sent AND still have somebody waiting; the bug was that the row said only the
    // first, so the person waiting vanished with the show.
    var blockedContactCount: Int = 0
    var sendError: String? = nil
    var lostReason: String? = nil
    var classificationConfidence: String = Confidence.confident.rawValue
    var confidenceReviewedByDan: Bool = false
    var classificationOverriddenByDan: Bool = false
    var bookingSuggested: Bool = false
    // #611: a fit-risk Prep's own research found (the org's site names its own photographer),
    // dismissible without changing fitScore/tier or the whole prospect's status.
    var alreadyCoveredNote: String? = nil
    var alreadyCoveredDismissed: Bool = false
    // #753: Prep matched this show's PERFORMER (not its org) to a past client and warmed the lead.
    // Unlike alreadyCovered, this one ALREADY changed fitScore/tier, so the row has to be able to
    // both explain it and take it back. Unreviewed means the warm drafting tone is still held back
    // until Dan confirms (#752).
    // #769: this org asked Dan to stop emailing them. Every one of their shows is off-limits.
    var orgDoNotContact: Bool = false
    var relationshipCorrectedByPerformerMatch: Bool = false
    var performerMatchNote: String? = nil
    var performerMatchDismissed: Bool = false
    var performerMatchReviewed: Bool = false
    // #407: an old draft still carrying an un-strippable inline greeting; sending is blocked
    // entirely (Recipient.isSendablePending) until this clears itself on a fresh migration pass.
    var draftNeedsSalutationReview: Bool = false
    // #718: Dan's deliberate override of the block above, for the exact draft text he confirmed.
    var salutationReviewOverridden: Bool = false
    // #789: blocking lint findings in the text a still-pending recipient would actually receive
    // (each recipient's own, so a performer's override body counts). Gathered across recipients
    // because Send is a per-show button; `draftLintBlocked` is what actually holds the send.
    var draftLintBlockers: [DraftIssue] = []
    var draftLintBlocked: Bool = false
    var outcomeSourceRaw: String? = nil
    // #901: a day of this run Dan cannot work and has not waved through, and the sentence saying which.
    // The show still renders (Dan's call: he decides, not the app), sinks to the bottom of the order, and
    // is neither drafted nor sendable until he clears it.
    var hasUnclearedConflict: Bool = false
    var conflictNote: String? = nil
    // #929: the specific night that is blocked (yyyy-MM-dd), decoded from the conflict key. A run can be
    // flagged for a LATER night while its opening night (the date this show groups under) is free, so the
    // date-group header must compare this against the group's date rather than assume the two are the same.
    var conflictBlockedDate: String? = nil
    var runEndDate: String? = nil
    var partOfRelatedRun: Bool = false
    // #939: the same production at OTHER venues nearby (a recurring Carnegie community-calendar
    // pattern), distinct from partOfRelatedRun above (which means the same venue, a separate run).
    var linkedEngagementMembers: [EngagementLink.Member] = []
    // The show dropped out of the feed across enough scouts to count as cancelled/pulled (#133).
    var disappearedFromFeed: Bool = false
    // The performance's recipients as flat snapshots for the per-contact conversation surface (#418 B1).
    // Empty for a single-contact legacy view; built from prospect.recipients in send order.
    var contacts: [RecipientSnapshot] = []

    // #367: whether Dan asked for a re-prep still awaiting the next Prep run.
    var reprepDraftRequested: Bool = false
    var reprepContactsRequested: Bool = false
    // #733: when a Prep run last served this prospect, for the re-prep cooldown warning.
    var reprepLastServedAt: Date? = nil

    // Show the "unsure" mark only for a rules-guessed classification Dan hasn't reviewed (#32).
    var isClassificationUncertain: Bool {
        classificationConfidence == Confidence.uncertain.rawValue && !confidenceReviewedByDan
    }

    // True when Downbeat or Gmail auto-detected a booking (#114); Dan must confirm before it locks.
    var isAutoBooked: Bool {
        outcome == .booked && outcomeSourceRaw == OutcomeSource.auto.rawValue
    }

    // True when a reply was auto-detected from Gmail (#219); Dan can mark it "not a real reply".
    var isAutoReplied: Bool {
        outcome == .replied && outcomeSourceRaw == OutcomeSource.auto.rawValue
    }

    var isSent: Bool { sentAt != nil }
    // #367: a re-prep still awaiting the next Prep run, shown as a small badge (mirrors the
    // existing "Edited" badge) so Dan can tell which prospects are still waiting versus served.
    var isReprepQueued: Bool { reprepDraftRequested || reprepContactsRequested }
    // #367: re-prep is never offered once sent (.contacted) or given up on (.dismissed); redrafting
    // text already sent, or reviving a dismissed lead, are different actions from re-prep.
    var isReprepEligible: Bool { status != .contacted && status != .dismissed }
    var isHighFit: Bool { tier == "high" }
    var isKept: Bool { status == .queued || status == .drafted || status == .approved || status == .contacted }
    var hasDraft: Bool { draftBody != nil }
    // Lost: every contact resolved away (derived), or Dan marked the lead lost by hand / closing note.
    // The row shows an editable reason note. (Phase F: derive from the contacts, not only the lead.)
    var isLost: Bool {
        performanceStatus == .lostDoorOpen || performanceStatus == .lostNotInterested
            || outcome == .lostSoft || outcome == .lostHard
    }
    // Confirmed booked (auto-detected or hand-marked); the row reads as Booked, not a lead to pitch.
    var isBooked: Bool { performanceStatus == .booked || outcome == .booked }
    // A booking Dan has confirmed (manual source) is settled and leaves the reach-out queue (#201);
    // an auto-detected one (isAutoBooked) stays until he confirms it, so a wrong match can be caught.
    var isConfirmedBooking: Bool { outcome == .booked && outcomeSourceRaw == OutcomeSource.manual.rawValue }

    // #596: a quick-glance hint when a prospect carries more than one recipient (e.g. 2 named
    // performers found for a self-produced show, #366), so Dan doesn't have to expand every row
    // to see when multiple people were found. nil for the common single-contact case (no clutter).
    var contactCountLabel: String? {
        contacts.count > 1 ? "\(contacts.count) contacts" : nil
    }

    // #654: the single contact a show-level display (the review card's contactLine) shows, replacing
    // the old lead-level mirror fields. Mirrors PrepImporter's own selection rule exactly: act or
    // performer preferred (mutually exclusive per performance, #587), else the first contact.
    var primaryContact: RecipientSnapshot? {
        contacts.first(where: { $0.provenance == .act || $0.provenance == .performer }) ?? contacts.first
    }

    // #846: "Drafted by opus", or nothing at all when this draft carries no trace. Decided here rather
    // than in the SwiftUI body (#863), and shared with the reply draft via DraftTrace so the two surfaces
    // cannot drift into saying it differently.
    var draftTraceLabel: String? { DraftTrace.label(for: draftModel) }

    // #1136: the draft trace for the ROW badge specifically. The draft-review panel renders exactly when
    // the item has a draft body (hasDraft) and shows this same "Drafted by opus" line next to "Edited", so
    // a row badge would state it twice. The badge is therefore shown only once the panel is gone (no draft
    // body), which is the archived case #879 built the row badge for: model-vs-outcome staying visible
    // after review. Decided here, tested, not in the SwiftUI row (#863).
    var rowDraftTraceLabel: String? { hasDraft ? nil : draftTraceLabel }

    // #992: the one-line reason this show was placed too far, or nil unless the geo gate positively
    // placed it out of range. Shown on the row only while the "Too far" filter is engaged. Decided in
    // QueueModel (tested), not the SwiftUI body (#863).
    var tooFarReason: String? { QueueModel.tooFarReason(self) }

    // #991: the same reason line, but reading Dan's stored refusals too, so a row hidden because he
    // excluded its town explains itself with the skip-list sentence. The queue passes the union; the
    // property above (seed only) stays for callers that have no store.
    func tooFarReason(userExcludedTowns: Set<String>, allowedSeedTowns: Set<String> = []) -> String? {
        QueueModel.tooFarReason(self, userExcludedTowns: userExcludedTowns,
                                allowedSeedTowns: allowedSeedTowns)
    }

    // #991: the town Dan's "never show me shows in this town" action would add, or nil when this row has
    // no in-region, non-borough town worth offering (see EventPlace.excludableTown).
    var excludableTown: String? { EventPlace.excludableTown(from: location) }
}

// One contact on a performance, flattened for the conversation surface (#418 B1). The per-contact
// status Dan reads is DERIVED from send/reply/resolution/bounced state; only the terminal resolutions
// and bounce aren't otherwise knowable, which is why the model stores those, not a status enum.
struct RecipientSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let email: String?
    let role: String?
    let provenance: RecipientProvenance
    let sendState: SendState
    let replied: Bool
    let lastReplyText: String?
    let resolution: RecipientResolution?
    let bounced: Bool
    let outcomeSource: OutcomeSource?
    // Only meaningful when sendState == .suppressed (#542); defaulted so existing call sites that
    // never touch a suppressed recipient don't need updating.
    var suppressionReason: RecipientSuppressionReason = .bookedElsewhere
    var replyDraftSubject: String? = nil
    var replyDraftBody: String? = nil
    var replyDraftRequestedAt: Date? = nil
    var intentHint: String? = nil
    var replyDraftEditedByDan: Bool = false
    // #846: which model wrote this reply (Recipient.replyDraftModel). Read via replyDraftTraceLabel.
    var replyDraftModel: String? = nil
    // #642 (#634 Phase D): a performer's direct-address draft, so the review screen can show Dan
    // exactly what this specific contact will receive instead of the shared draft body. Only ever
    // set when provenance == .performer; defaulted so existing call sites don't need updating.
    var overrideBody: String? = nil
    // #652: this contact's OWN conversation state, mirroring what QueueItem carries lead-level today,
    // so the per-contact review controls can read and act on it directly.
    var conversationState: ConversationState? = nil
    var conversationStateSource: OutcomeSource? = nil
    var conversationRemindedAt: Date? = nil
    // #654: moved from the now-deleted lead-level QueueItem fields, since contact confidence/method/
    // form-URL are genuinely per-recipient data.
    var contactConfidence: ContactConfidence? = nil
    var contactMethod: ContactMethod? = nil
    var contactFormURL: String? = nil
    // #363: mirrors Recipient.contactSourceURL. See contactSourceLinkURL below for the display
    // gate (only ever a link at confidence == .high).
    var contactSourceURL: String? = nil
    // #656: when the newest Gmail delay notice was first seen, or nil if there's never been one
    // (or it was superseded by a fresh reply/bounce/resolution). Drives hasRecentDeliveryDelay.
    var delayNoticeAt: Date? = nil
    // #388: a heuristic guess that this address belongs to the host venue, not the act/presenter.
    var looksLikeVenue: Bool = false
    var looksLikeVenueDismissed: Bool = false
    // #722: same shape, for a suspected press/media contact.
    var looksLikePressContact: Bool = false
    var looksLikePressContactDismissed: Bool = false
    // #726: same shape, for a contact already pitched on another still-open prospect for what
    // looks like the same real-world performance.
    var looksLikeDuplicateContact: Bool = false
    var looksLikeDuplicateContactDismissed: Bool = false

    // #363: the confidence badge becomes a clickable link to where the contact was actually
    // verified, so "high confidence" is checkable instead of an unverifiable assertion. Gated
    // here (not in PrepImporter) so a contactSourceURL left over from a since-downgraded
    // confidence is inert rather than shown as a false citation, mirroring ContactDisplay's own
    // "decide purely, keep the SwiftUI row dumb" pattern.
    var contactSourceLinkURL: URL? {
        guard contactConfidence == .high, let contactSourceURL, !contactSourceURL.isEmpty,
              let url = URL(string: contactSourceURL), url.scheme != nil else { return nil }
        return url
    }

    // The AI reply drafter has produced a draft Dan can send or copy (#420 C6).
    var hasReplyDraft: Bool { (replyDraftBody?.isEmpty == false) }

    // #846: "Drafted by opus" for THIS reply, or nothing when it carries no trace. Same DraftTrace rule
    // as the cold draft: one implementation, so the two surfaces cannot drift into saying it differently.
    var replyDraftTraceLabel: String? { DraftTrace.label(for: replyDraftModel) }

    // The deterministic self-check findings to surface on the reply draft (#456), or none once Dan has
    // edited it: it's his text then, the same suppression the cold path applies via draftEditedByDan
    // (#459). Lives here, not in the view, so the suppression is unit-testable.
    func replyDraftFindings(title: String? = nil, knownsDate: Bool, knownsVenue: Bool) -> [DraftIssue] {
        guard !replyDraftEditedByDan, let body = replyDraftBody else { return [] }
        return DraftCheck.findings(in: body, title: title, knownsDate: knownsDate, knownsVenue: knownsVenue)
    }
    // A draft was requested but hasn't arrived yet: show progress.
    var isDraftingReply: Bool { replyDraftRequestedAt != nil && !hasReplyDraft }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Unknown contact"
    }

    // A reply Overture auto-detected (not one Dan hand-marked): only these get a "not a real reply"
    // dismiss control.
    var isAutoReplied: Bool { replied && outcomeSource != .manual }

    // A bounce Overture auto-detected (not one Dan hand-marked): only these get a "not really
    // bounced" dismiss control (#398).
    var isAutoBounced: Bool { bounced && outcomeSource != .manual }

    // A soft/temporary Gmail delay notice within the fade window (#656): purely informational, so
    // it never shows once superseded by something more definite (a bounce, a reply, or a terminal
    // resolution), and fades on its own after a few days since Gmail never tells us a delay
    // resolved (most delayed mail either quietly delivers or eventually hard-bounces).
    static let deliveryDelayWindow: TimeInterval = 3 * 24 * 3600

    func hasRecentDeliveryDelay(now: Date) -> Bool {
        guard !bounced, !replied, resolution == nil, let delayNoticeAt else { return false }
        return now.timeIntervalSince(delayNoticeAt) < Self.deliveryDelayWindow
    }

    // The plain-language status line. Terminal marks win; then bounce; then reply; then send state.
    var statusLabel: String {
        if let resolution {
            switch resolution {
            case .booked: return "Booked"
            case .declinedSoft: return "Closed (not now)"
            case .declinedHard: return "Closed (not interested)"
            }
        }
        if bounced { return "Bounced" }
        if replied { return "In conversation" }
        switch sendState {
        case .sent: return "Awaiting reply"
        case .pending: return (email?.isEmpty == false) ? "Not sent yet" : "No email yet"
        case .suppressed:
            switch suppressionReason {
            case .bookedElsewhere: return "Paused (booked elsewhere)"
            case .declined: return "Paused (show declined)"
            case .removedByDan: return "Removed"
            }
        case .sending: return "Sending…"
        }
    }
}

enum QueueModel {

    // MARK: - Copy and filtering the queue used to do in its own body (#885)

    // The three-clause filter that feeds the "To send (N)" pill. The windowing after it
    // (toSendQueue) was always tested; THIS half was written in the view, so the pill's number was only
    // ever as trustworthy as its untested part. A count is a promise about rows (#863).
    static func filter(_ items: [QueueItem], discipline: String?, highOnly: Bool,
                       pendingBookingsOnly: Bool, tooFarOnly: Bool = false,
                       userExcludedTowns: Set<String> = [],
                       allowedSeedTowns: Set<String> = []) -> [QueueItem] {
        items.filter { item in
            if let discipline, item.discipline != discipline { return false }
            if highOnly, !item.isHighFit { return false }
            if pendingBookingsOnly, !item.bookingSuggested { return false }
            // #970. The gate. `tooFarOnly` inverts it, which is how a hidden show stays one click away
            // rather than gone: the same predicate decides both, so the chip's count and the rows it
            // reveals cannot drift apart (#863).
            if isTooFar(item, userExcludedTowns: userExcludedTowns,
                        allowedSeedTowns: allowedSeedTowns) != tooFarOnly { return false }
            return true
        }
    }

    // #970. The geo gate, asked here and nowhere else, so `filter` and `tooFar` can never disagree
    // about a row: the chip's number is a promise about the rows behind it (#863).
    //
    // ONLY a positive placement hides. Unknown keeps, always (Dan's spec), which is what makes this
    // safe to ship on all 38 sources at once: it can only take shows the resolver can actually place
    // out of range. When this shipped no live row carried a location yet, so it changed nothing on the
    // queue Dan had then; that was a point in time observation, not a standing guarantee, and as the
    // geography work (#970) starts naming locations this gate takes effect. The behavior that matters
    // (a positive placement hides, an unknown location always keeps) is pinned by QueueGeoFilterTests
    // independently of what the store currently holds, so this comment is not the only thing keeping it
    // true (#1099).
    // The seed-only overload, kept as a distinct one-argument method (not a defaulted parameter) so it
    // stays usable as a first-class function value, e.g. `items.filter(QueueModel.isTooFar)`.
    static func isTooFar(_ item: QueueItem) -> Bool { isTooFar(item, userExcludedTowns: []) }

    static func isTooFar(_ item: QueueItem, userExcludedTowns: Set<String>,
                         allowedSeedTowns: Set<String> = []) -> Bool {
        let discipline = Discipline(rawValue: item.discipline) ?? .other
        return EventPlace.resolve(location: item.location, discipline: discipline,
                                  userExcludedTowns: userExcludedTowns,
                                  allowedSeedTowns: allowedSeedTowns).verdict == .outOfRange
    }

    // #992. The chip's number says HOW MANY the gate hid; this says WHY this row in particular was, in one
    // short line shown only while the "Too far" filter is engaged. `isTooFar` already computes the reason
    // on every row and throws it away; this keeps it. Resolved fresh from the row's own words (never
    // stored, like the verdict), so a rule change re-decides every row's reason at once.
    //
    // nil unless the gate positively placed this row out of range, so a kept or unknown row shows nothing.
    static func tooFarReason(_ item: QueueItem, userExcludedTowns: Set<String> = [],
                             allowedSeedTowns: Set<String> = []) -> String? {
        let discipline = Discipline(rawValue: item.discipline) ?? .other
        let reason = EventPlace.resolve(location: item.location, discipline: discipline,
                                        userExcludedTowns: userExcludedTowns,
                                        allowedSeedTowns: allowedSeedTowns).reason
        return tooFarReasonSentence(reason)
    }

    // #991: the label on the row's "never show me shows in this town" action, a complete literal template
    // (not a fragment, #copy-inventory) so the checked-in inventory reads it as one sentence. Decided in
    // the tested model, never in the SwiftUI body (#863).
    static func excludeTownLabel(town: String) -> String { "Never show me shows in \(town)" }

    // The three hiding reasons are three genuinely different situations, and Dan reacts to each
    // differently, so each gets its own sentence rather than a shared phrasing of "too far" (#843/#844):
    //   outsideTheRegion  a real place, simply nowhere near the tri-state area. Obviously right.
    //   excludedTown      in the tri-state, but a town on the skip list. He may want to reconsider it.
    //   outsideTheBoroughs in the tri-state, but this is music, which he only travels the boroughs for.
    //                     The surprising one: the same show as theater would have been kept, so the line
    //                     says so, because that is exactly what reads like a bug otherwise.
    // Every non-hiding reason returns nil (exhaustive, so a new EventPlace.Reason case must be handled here).
    static func tooFarReasonSentence(_ reason: EventPlace.Reason) -> String? {
        switch reason {
        case .outsideTheRegion:
            return "Outside New York, New Jersey and Connecticut."
        case .excludedTown:
            return "This town is on the skip list."
        case .outsideTheBoroughs:
            return "Music only travels to the five boroughs. As theater this would stay."
        case .insideTheBoroughs, .insideTheRegion, .noLocation, .couldNotPlace:
            return nil
        }
    }

    // The rows the gate took, so a filter bug is loud rather than invisible (#887): a hidden show is
    // one click away, never gone.
    //
    // #996: this is the set clicking the chip REVEALS, which is the only set its number may describe.
    // It therefore runs the identical expression the view renders with (`filter` then `toSendQueue`),
    // rather than the raw predicate over `items`.
    //
    // That distinction was not academic. The first version counted raw `items`, and the queue windows
    // the filtered set to the bookable date range afterwards, so a show could be counted as too far
    // and then dropped for being too far in the FUTURE. Dan saw "Too far (4)" open onto one row within
    // minutes of it shipping. There is deliberately no way to ask for the unwindowed count any more:
    // the whole justification for hiding rows at all is that the number makes a filter bug loud
    // (#887), and a number that overstates by 4x cannot do that job.
    static func tooFar(_ items: [QueueItem], discipline: String?, highOnly: Bool,
                       pendingBookingsOnly: Bool, reachedOutKeys: Set<String>,
                       today: String, userExcludedTowns: Set<String> = []) -> [QueueItem] {
        toSendQueue(filter(items, discipline: discipline, highOnly: highOnly,
                           pendingBookingsOnly: pendingBookingsOnly, tooFarOnly: true,
                           userExcludedTowns: userExcludedTowns),
                    reachedOutKeys: reachedOutKeys, today: today)
    }

    static func tooFarCount(_ items: [QueueItem], discipline: String?, highOnly: Bool,
                            pendingBookingsOnly: Bool, reachedOutKeys: Set<String>,
                            today: String, userExcludedTowns: Set<String> = []) -> Int {
        tooFar(items, discipline: discipline, highOnly: highOnly,
               pendingBookingsOnly: pendingBookingsOnly, reachedOutKeys: reachedOutKeys,
               today: today, userExcludedTowns: userExcludedTowns).count
    }

    // #996: the chip must stay clickable while it is ON, even when it now reveals nothing. Changing a
    // discipline filter with the chip active can empty its set, and a chip that vanished at that moment
    // would strand Dan in a queue showing no rows with nothing left to click to get back.
    static func chipIsShown(count: Int, showingOnly: Bool) -> Bool { count > 0 || showingOnly }

    static func tooFarLabel(count: Int) -> String { "Too far (\(count))" }

    // Why rows have vanished, which is the one thing a filter must never leave Dan guessing about, and
    // what turning it on would do when it is off. Mirrors pendingBookingsHelp, deliberately: it is the
    // same job, and the queue should not have two voices for it.
    static func tooFarHelp(showingOnly: Bool, count: Int) -> String {
        guard showingOnly else {
            return "Show only the shows that are too far away to shoot"
        }
        return "Showing only the \(Plural.count(count, "show")) that are too far away. Click to show the whole queue again."
    }

    // #308: the heading on the focused view a multi-lead away alert lands on. It names how many leads it
    // is about to show, so it is a promise about the rows directly beneath it.
    static func newLeadsHeading(count: Int) -> String {
        "\(Plural.count(count, "new lead")) while you were away"
    }

    // Why rows have vanished, which is the one thing a filter must never leave Dan guessing about, and
    // what turning it on would do when it is off. Two entirely different sentences, chosen by a ternary
    // in the view body.
    static func pendingBookingsHelp(showingOnly: Bool, count: Int) -> String {
        guard showingOnly else {
            return "Show only prospects where Downbeat detected a booking, to confirm or dismiss each one"
        }
        return "Showing only the \(Plural.count(count, "pending booking")). Click to show the whole queue again."
    }

    static func fitLabel(isHighFit: Bool) -> String { isHighFit ? "HIGH FIT" : "LONG SHOT" }

    // #885 (guard sweep): the bookings filter's own label, and the AI's read of an incoming reply. The
    // second one is a claim about what a MODEL concluded, so the words matter: "AI read" says whose
    // conclusion it is, which is the difference between a hint and a fact.
    static func confirmBookingsLabel(count: Int) -> String { "Confirm bookings (\(count))" }

    static func aiReadNote(hint: String) -> String { "AI read: \(replyIntentLabel(hint))" }

    // Both branches promise something about what the DRAFT will do, which is why they are worth a test:
    // one says a returning-client draft is now allowed, the other says it is not yet.
    static func performerMatchHelp(confirmed: Bool) -> String {
        confirmed
            ? "You confirmed this performer is a past client, so the fit score counts it and a draft can write to them as a returning client."
            : "Prep matched this show's performer to a past client, which raised the fit score. The draft won't treat them as a returning client until you confirm it."
    }

    // "Pending Prep run" asserts this show is IN the Prep queue: a claim about what the app does next.
    static func contactPrepNote(isKept: Bool) -> String {
        isKept ? "Contact: pending Prep run" : "Contact: keep to prep"
    }
    // Plain-language label for the AI's non-binding reply-intent hint (#420 C6).
    static func replyIntentLabel(_ raw: String) -> String {
        switch ReplyIntent(rawValue: raw) {
        case .interested: return "interested"
        case .wantsToBook: return "wants to book"
        case .hasQuestion: return "has a question"
        case .declined: return "declined"
        case nil: return raw
        }
    }

    // #350: Choral is no longer its own category (folded into Music); a leftover raw "choral"
    // string degrades to the generic fallback below rather than a dedicated label.
    static func disciplineLabel(_ discipline: String) -> String {
        switch discipline {
        case "dance": return "Dance"
        case "opera": return "Opera"
        case "theater": return "Theater"
        case "music": return "Music"
        case "band": return "Band"
        case "comedy": return "Comedy"
        default: return "Performance"
        }
    }

    static func productionLabel(_ production: String) -> String? {
        switch production {
        case "self": return "Self-produced"
        case "agency": return "Agency-routed"
        default: return nil
        }
    }

    static func coverageLabel(_ coverage: String) -> String? {
        switch coverage {
        case "likely_uncovered": return "Likely uncovered"
        case "likely_covered": return "Likely covered"
        default: return nil
        }
    }

    // A confident match is stated plainly; a fuzzy "possible" match is a question.
    static func historyFlag(_ item: QueueItem) -> String? {
        if item.priorRelationship == "booked" {
            if let name = item.matchedClientName {
                return "Worked together before (\(name))"
            }
            return "Worked together before"
        }
        if item.priorRelationship == "declined_by_you" {
            return "You declined before (usually a date conflict)"
        }
        if item.priorRelationship == "warm" {
            return "Warm lead from a prior relationship"
        }
        if item.priorRelationship == "lost_soft" {
            return "Lost before, open to the future"
        }
        if item.priorRelationship == "lost_hard" {
            return "Lost before, not interested"
        }
        if item.priorRelationship == "contacted" {
            return "Cold-contacted before, no booking"
        }
        if let name = item.possibleMatchName {
            let where_ = item.possibleMatchSource == "downbeat_client" ? "a past client" : "the booking log"
            return "Possible match to \(where_): \(name)?"
        }
        return nil
    }

    // Today, as a "yyyy-MM-dd" string in New York time (Overture's canonical zone), so
    // "is this in the past / within the booking window" never drifts a day off UTC or the
    // Mac's local zone wherever Dan happens to be.
    static func easternToday(_ now: Date = Date()) -> String {
        EasternDate.today(now)
    }

    // The window the queue shows: past performances drop out, and anything more than this
    // many days out is beyond the planning horizon Dan wants to look at.
    static let leadTimeWindowDays = 90
    // Within this many days a booking is unrealistic to land, so the event still shows but
    // sinks below everything bookable rather than sitting up top with the nearest dates.
    //
    // Dan's call (2026-07-16), on his first real walk of the queue: five days is enough notice to
    // pitch, so the window closes at four. He set it knowing a show four days out still demotes.
    static let tooCloseDays = 4

    // Whole days from `today` (a "yyyy-MM-dd" string) to the performance, as New York
    // calendar dates so nothing drifts a day across timezones.
    static func daysUntil(performanceDate: String?, today: String) -> Int? {
        guard let performanceDate else { return nil }
        return EasternDate.daysUntil(from: today, to: performanceDate)
    }

    // #1122: `underway` is a run whose opening night has passed but whose closing night has not, so it is
    // still a live, pitchable show. Distinct from `past` (the whole run is over) and from the ordinary
    // upcoming urgencies (it has already started).
    enum Urgency { case past, tooSoon, imminent, soon, ahead, unknown, booked, underway }
    struct Timing: Equatable { let label: String; let urgency: Urgency
        static func == (l: Timing, r: Timing) -> Bool { l.label == r.label && l.urgency == r.urgency } }

    static func outreachTiming(performanceDate: String?, runEndDate: String? = nil, today: String) -> Timing {
        // #1122: a run is judged by its CLOSING night, never its opening one (EasternDate.runLastNight,
        // the same rule the scout import guard already honors). A run that opened last week and runs
        // through next week is still live, so only once its last night is behind us has it "passed".
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        if EasternDate.runHasPassed(lastNight: lastNight, today: today) {
            return Timing(label: "Performance passed", urgency: .past)
        }
        guard let days = daysUntil(performanceDate: performanceDate, today: today) else {
            return Timing(label: "Date TBD", urgency: .unknown)
        }
        // The opening night is behind us but the closing-night check above let the run through, so it is
        // underway and still bookable. The row shows the full date range beside this, so the label only
        // has to say the run has started and can still be pitched (Dan's big note on #1122).
        if days < 0 { return Timing(label: "Run underway, still bookable", urgency: .underway) }
        if days == 0 { return Timing(label: "Performs today, too close to book", urgency: .tooSoon) }
        if days <= tooCloseDays {
            return Timing(label: "In \(days) day\(days == 1 ? "" : "s"), likely too close to book", urgency: .tooSoon)
        }
        if days <= 7 {
            return Timing(label: "In \(days) days, reach out now", urgency: .imminent)
        }
        if days <= 21 {
            return Timing(label: "In \(days) days, good to send", urgency: .soon)
        }
        return Timing(label: "In \(days) days, send ~3 weeks out", urgency: .ahead)
    }

    // A booked prospect reads "Booked" instead of any outreach urgency, so the row never nags
    // Dan to pitch someone he has already booked (#198). Otherwise the normal outreach timing.
    static func displayTiming(performanceDate: String?, runEndDate: String? = nil,
                              today: String, isBooked: Bool) -> Timing {
        if isBooked { return Timing(label: "Booked", urgency: .booked) }
        return outreachTiming(performanceDate: performanceDate, runEndDate: runEndDate, today: today)
    }

    // #843: a booked row already carries "BOOKED" on its seal (the whole point of the seal is to make the
    // row read as done at a glance). The header's timing line would then say "Booked" a second time, so on
    // a booked row it shows only the run date and lets the seal own the status.
    static func headerShowsTimingLine(isBooked: Bool) -> Bool { !isBooked }

    // Orders the queue for display: hide past performances and anything beyond the lead-time
    // window, and keep everything else in its normal date position, undated events included
    // (they group last anyway). Computed live against `today` so it stays correct as days pass
    // between scout runs.
    //
    // #1014, Dan's call REVISED after his first real walk of the queue (2026-07-16): a too-close show
    // used to sink to the bottom, graded by closeness, and it read as the show being deleted ("I do
    // not have anything in my queue before jul 22", when the shows were there, just demoted beneath
    // October dates). That is exactly #901's ruling for a conflicted show, recorded below: reordering
    // a single show to the very end of the list reads as its disappearance, whatever the reason. The
    // existing "likely too close to book" timing line already carries the meaning; the position no
    // longer needs to.
    static func queueOrder(_ items: [QueueItem], today: String) -> [QueueItem] {
        // Hide shows that vanished from the feed and Dan never acted on (#133): pure noise. Ones
        // he kept/drafted/approved stay (shown struck-through) so a cancellation he was pursuing
        // stays visible.
        let items = items.filter { !($0.status == .new && $0.disappearedFromFeed) }
        var bookable: [QueueItem] = []
        for item in items {
            // A confirmed booking is settled and leaves the reach-out queue (#201). An auto-detected
            // booking is kept (handled just below) so Dan can confirm it or catch a wrong match.
            if item.isConfirmedBooking { continue }
            // A detected booking awaiting Dan's confirmation is a separate workflow from
            // pitching, so it stays put regardless of how near or past its date is.
            if item.bookingSuggested {
                bookable.append(item)
                continue
            }
            // #1122: judged by the run's CLOSING night for the past check (a run still running tonight
            // stays visible, consistent with the scout import guard), but by the OPENING night for the
            // far-future check (a run that has not started and opens beyond the lead-time window is still
            // too far out). A single-night show has runEndDate nil, so its closing night IS its date and
            // this collapses to the old `days < 0` behaviour.
            let lastNight = EasternDate.runLastNight(runEndDate: item.runEndDate,
                                                     performanceDate: item.performanceDate)
            if EasternDate.runHasPassed(lastNight: lastNight, today: today) { continue }
            guard let days = daysUntil(performanceDate: item.performanceDate, today: today) else {
                bookable.append(item)
                continue
            }
            if days > leadTimeWindowDays { continue }
            // #1014: a too-close show is neither hidden nor reordered, only kept (falls through to
            // the same append as everything else). #901, Dan's call REVISED after he walked the build
            // (2026-07-14): a conflicted show keeps its normal date position and is NOT reordered
            // either. The highly visible "Unavailable" badge (and, here, the timing line) does the
            // telling now, not the position. The fit score is still untouched.
            bookable.append(item)
        }
        return bookable
    }

    struct DateGroup: Identifiable, Equatable {
        let id: String
        let weekday: String
        let monthDay: String
        let year: String
        let items: [QueueItem]
    }

    // Groups by performance date, preserving incoming order. Undated collect last.
    // #361: fold the just-sent rows playing their leaving delight back into the displayed rows, so each
    // glides out in its place. The send has already dropped them from `visible`, so they come from the
    // departing snapshots; a defensive filter avoids showing one twice if `visible` briefly still holds
    // it before the @Query refilters.
    static func withDeparting(_ visible: [QueueItem], departing: [String: QueueItem]) -> [QueueItem] {
        guard !departing.isEmpty else { return visible }
        return visible.filter { departing[$0.id] == nil } + Array(departing.values)
    }

    static func groupByDate(_ items: [QueueItem]) -> [DateGroup] {
        var order: [String] = []
        var buckets: [String: [QueueItem]] = [:]
        for item in items {
            let key = item.performanceDate ?? "tbd"
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(item)
        }
        return order.map { key in
            let bucket = buckets[key] ?? []
            if key != "tbd", let d = day(key) {
                let cal = easternCalendar
                return DateGroup(
                    id: key,
                    weekday: shortWeekday(cal.component(.weekday, from: d)),
                    monthDay: "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))",
                    year: String(cal.component(.year, from: d)),
                    items: bucket
                )
            }
            return DateGroup(id: key, weekday: "", monthDay: "Date to be confirmed", year: "", items: bucket)
        }
    }

    // A blank or whitespace-only lost reason clears the note (stored as nil) rather than
    // persisting an empty string, so "has a reason" stays meaningful.
    static func normalizedLostReason(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // #674: the first key in `keys` that's actually present among `items`, or nil if none are. A
    // multi-lead OmniFocus alert's initial auto-scroll uses this instead of blindly `keys.first`,
    // so a lead dismissed between the notification firing and Dan tapping it (and so no longer in
    // the focused list at all) doesn't leave the scroll targeting a row that isn't there.
    static func firstVisibleKey(_ keys: [String], among items: [QueueItem]) -> String? {
        let ids = Set(items.map(\.id))
        return keys.first { ids.contains($0) }
    }

    // #217: the to-send queue is the bookable order with anyone already reached out to removed, so
    // the "To send" and "Reached out" pipelines never show the same prospect twice.
    static func toSendQueue(_ items: [QueueItem], reachedOutKeys: Set<String>, today: String) -> [QueueItem] {
        queueOrder(items.filter { !reachedOutKeys.contains($0.id) }, today: today)
    }

    // Whether a single show would actually render somewhere in the Queue right now, reusing
    // the exact same reached-out/toSendQueue rules the Queue itself renders with (on a one item
    // array), so this can never drift from what Dan would actually see if he looked.
    static func isReachableInQueue(_ item: QueueItem, reachedOutKeys: Set<String>, today: String) -> Bool {
        if reachedOutKeys.contains(item.id) { return true }
        return !toSendQueue([item], reachedOutKeys: [], today: today).isEmpty
    }

    // Whether an OmniFocus follow-up tap or a global search pick should jump into the Queue, as
    // opposed to opening Archive with the item highlighted instead. A dismissed show never renders
    // in the Queue at all, so it's excluded here even though isReachableInQueue alone wouldn't catch
    // it. Shared by both call sites so a closed show with a late reply (#628) can't drift between
    // "reachable by search" and "reachable by deep link".
    static func isReachableForDeepLink(_ item: QueueItem, reachedOutKeys: Set<String>, today: String) -> Bool {
        item.status != .dismissed && isReachableInQueue(item, reachedOutKeys: reachedOutKeys, today: today)
    }

    static func summary(_ items: [QueueItem]) -> (total: Int, high: Int) {
        (items.count, items.filter { $0.tier == "high" }.count)
    }

    static func pendingBookingCount(_ items: [QueueItem]) -> Int {
        items.filter(\.bookingSuggested).count
    }

    // "Jun 25" for a single date (end nil or same as start), "Jun 25 to 28" for a same-month
    // range, "Jun 28 to Jul 2" for a cross-month range, "Date to be confirmed" for a bad start.
    static func runDateLabel(start: String?, end: String?) -> String {
        guard let start, let d = day(start) else { return "Date to be confirmed" }
        let cal = easternCalendar
        let startLabel = "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
        guard let end, end != start, let e = day(end) else { return startLabel }
        let sameMonth = cal.component(.month, from: d) == cal.component(.month, from: e)
        let endLabel = sameMonth
            ? "\(cal.component(.day, from: e))"
            : "\(shortMonth(cal.component(.month, from: e))) \(cal.component(.day, from: e))"
        return "\(startLabel) to \(endLabel)"
    }

    // #901 (Dan's walk, 2026-07-14): a date-group header is marked "Unavailable" when a show under it is
    // on a day he cannot work. A day off or a booked shoot blocks the whole day, so this reads as "this
    // date is blocked" at a glance, without opening each row.
    //
    // #929: the header is a claim about THIS date, so it fires only when the blocked night IS this date.
    // A multi-night run can be flagged for a LATER night while its opening night (the date it groups under)
    // is free; that run still shows its own row flag, but painting the opening-night header "Unavailable"
    // would state something untrue. Items in a group share their performanceDate, so comparing each show's
    // blocked night against its own performanceDate is the same as comparing against the group's date.
    static func groupIsUnavailable(_ items: [QueueItem]) -> Bool {
        items.contains { $0.hasUnclearedConflict && $0.conflictBlockedDate == $0.performanceDate }
    }

    // #1219: self double-booking. The detection lives here (testable, the #863 lesson); the views just
    // render it. A row counts as a same-date COMMITMENT on PERSISTENT facts (a confirmed booking, a pitch
    // already sent, or a live draft), never on a mutable stage, so the signal cannot vanish when a show
    // moves stage (#1246). groupName is both the production key (a run or the same show, shared groupName,
    // is not a double-booking) and the display name a warning uses to say WHICH other show clashes.
    static func selfBookingIsCommitment(_ i: QueueItem) -> Bool {
        if i.isBooked { return true }                         // a confirmed shoot (outcome/performanceStatus booked)
        if i.dismissReason == .alreadyBooked { return true }  // dismissed BECAUSE booked elsewhere: still committed
        if i.isLost { return false }                          // #1248: a pitch marked lost frees the date, even if it was sent
        if i.status == .dismissed { return false }            // any other dismissed show is dead; ignore it
        if i.sentAt != nil { return true }                    // a live pitch is already out
        return (i.status == .drafted || i.status == .approved) && i.hasDraft  // an in-progress draft
    }

    private static func selfBookingShow(_ i: QueueItem) -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: i.id, date: i.performanceDate,
                                 isCommitment: selfBookingIsCommitment(i),
                                 engagementKey: i.groupName, name: i.groupName)
    }

    // The OTHER committed shows clashing with `item` on its date, across the WHOLE queue (never scoped to
    // one stage, so the warning never vanishes when a show changes stage, #1246). Empty = the date is clear.
    static func selfBookingConflicts(for item: QueueItem, among items: [QueueItem]) -> [QueueItem] {
        let shows = items.map(selfBookingShow)
        let keys = Set(SelfBookingConflict.conflicts(for: selfBookingShow(item), among: shows).map(\.key))
        return items.filter { keys.contains($0.id) }
    }

    static func hasSelfBookingConflict(for item: QueueItem, among items: [QueueItem]) -> Bool {
        !selfBookingConflicts(for: item, among: items).isEmpty
    }

    // The names of the OTHER committed shows on this row's date, so a warning can name them. NOTE (#901/
    // #863): this must never be wired into needsPrep or a stage-pill count; it is confirm-to-proceed, not
    // a hard gate, so the counts stay honest.
    static func selfBookingConflictNames(for item: QueueItem, among items: [QueueItem]) -> [String] {
        selfBookingConflicts(for: item, among: items).map(\.groupName)
    }

    // #1244: the self-booking warning shown at the send-confirm moment, as one shared helper so BOTH send
    // paths (the main queue's requestSend and Archive's) surface a same-date clash identically and can never
    // drift on when or how it is named. nil when the date is clear. The comparison set is the WHOLE queue,
    // so a clash with a show in any stage still counts.
    static func sendSelfBookingWarning(for item: QueueItem, among items: [QueueItem]) -> String? {
        SelfBookingCopy.confirmWarning(selfBookingConflictNames(for: item, among: items))
    }

    // The queue-wide date-header note: shown when any row in this date group faces a self-booking conflict
    // against the WHOLE queue, so it stays visible even after the other show has moved to another stage.
    static func selfBookingNote(_ group: [QueueItem], among all: [QueueItem]) -> String? {
        group.contains { hasSelfBookingConflict(for: $0, among: all) } ? SelfBookingCopy.dateHeaderNote : nil
    }

    // #1219: which of the shows ABOUT TO BE PREPPED (by key) sit on a date that already holds a committed
    // OTHER show, and the names of those clashes, so a prep-launch confirm can name them. Shared by BOTH
    // prep entry points, the "Prep these N" sheet AND the per-row Re-prep (red-team FLAW 1: Re-prep
    // launches a run directly, so gating only the sheet leaves a hole). Empty = no clash, run freely.
    static func selfBookingPrepClashes(forKeys keys: Set<String>, among items: [QueueItem]) -> [SelfBookingPrepClash] {
        items
            .filter { keys.contains($0.id) }
            .compactMap { selfBookingClash(for: $0, among: items) }
    }

    // The single-row clash (this show + the committed OTHER shows on its date), or nil when the date is
    // clear. Used by the Approve and per-row Re-prep confirms, where one specific row is being committed.
    static func selfBookingClash(for item: QueueItem, among items: [QueueItem]) -> SelfBookingPrepClash? {
        let names = selfBookingConflictNames(for: item, among: items)
        return names.isEmpty ? nil : SelfBookingPrepClash(groupName: item.groupName, conflictNames: names)
    }

    static func relatedRunNote(_ item: QueueItem) -> String? {
        item.partOfRelatedRun ? "This group also performs at this venue on other dates" : nil
    }

    // #939: QueueView and ArchiveView both build their rows from `prospects` this same way, so the
    // cross-venue engagement link (computed across the WHOLE array, not one prospect at a time) lives
    // here where it is testable, rather than inline in either view (the #863 lesson).
    static func items(from prospects: [Prospect]) -> [QueueItem] {
        let linked = EngagementLink.group(prospects.map(EngagementLink.Row.init))
        return prospects.map {
            var item = QueueItem($0)
            item.linkedEngagementMembers = linked[$0.naturalKey] ?? []
            return item
        }
    }

    // #939: distinct from relatedRunNote above (same venue, a separate run): this production also plays
    // one or more OTHER venues nearby, so two queue rows Dan might otherwise treat as separate leads are
    // actually one touring engagement. Each case is one complete sentence (not built by joining pieces),
    // so the copy-inventory (docs/copy-inventory.md) shows it as the one whole line Dan actually reads.
    static func linkedEngagementNote(_ item: QueueItem) -> String? {
        let members = item.linkedEngagementMembers
        guard !members.isEmpty else { return nil }
        if members.count == 1, let only = members.first {
            let dateLabel = EasternDate.dayLabel(only.date) ?? only.date
            guard let venue = only.venue, !venue.isEmpty else {
                return "This production also plays elsewhere on \(dateLabel)."
            }
            return "This production also plays at \(venue) on \(dateLabel)."
        }
        // #966: 3+ venues used to fall back to a count-only sentence; a real short community-venue
        // tour showed that wasn't informative enough, so every member is named instead.
        let list = members.map(linkedEngagementMemberPhrase).joined(separator: "; ")
        return "This production also plays \(list)."
    }

    private static func linkedEngagementMemberPhrase(_ member: EngagementLink.Member) -> String {
        let dateLabel = EasternDate.dayLabel(member.date) ?? member.date
        guard let venue = member.venue, !venue.isEmpty else { return "elsewhere on \(dateLabel)" }
        return "at \(venue) on \(dateLabel)"
    }

    // MARK: - Date helpers

    // Overture is always reckoned in New York time, never UTC or the Mac's local zone.
    // Date math delegates to the shared EasternDate helper, the one source of truth (#116). The
    // label formatting below still uses the Eastern calendar + day parsing through it.
    private static let easternCalendar = EasternDate.calendar
    private static func day(_ iso: String) -> Date? { EasternDate.date(from: iso) }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static func shortWeekday(_ component: Int) -> String { weekdays[(component - 1 + 7) % 7] }
    // #901: the month names moved to EasternDate, which now also renders the single-day label the
    // blocked-calendar note needs ("Nov 14"). One list of month names, not two drifting ones.
    private static func shortMonth(_ component: Int) -> String { EasternDate.shortMonth(component) }
}

extension QueueItem {
    init(_ p: Prospect) {
        self.init(
            id: p.naturalKey,
            groupName: p.groupName,
            discipline: p.discipline,
            venue: p.venue,
            performanceDate: p.performanceDate,
            sourceListingURL: p.sourceListingURL,
            websiteURL: p.websiteURL,
            location: p.location,
            priorRelationship: p.priorRelationship,
            production: p.production,
            profile: p.profile,
            coverage: p.coverage,
            fitScore: p.fitScore,
            tier: p.tier,
            fitReason: p.fitReason,
            matchedClientName: p.matchedClientName,
            possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName,
            status: p.status,
            dismissReason: p.dismissReason,
            draftSubject: p.draftSubject,
            draftBody: p.draftBody,
            draftEditedByDan: p.draftEditedByDan,
            draftModel: p.draftModel,
            outcome: p.outcome,
            performanceStatus: p.performanceStatus,
            sentAt: p.sentAt,
            hasPendingRecipient: p.recipients.contains(where: \.isSendablePending),
            blockedContactCount: p.blockedContactCount,
            sendError: p.sendError,
            lostReason: p.lostReason,
            classificationConfidence: p.classificationConfidence,
            confidenceReviewedByDan: p.confidenceReviewedByDan,
            classificationOverriddenByDan: p.classificationOverriddenByDan,
            bookingSuggested: p.bookingSuggested,
            alreadyCoveredNote: p.alreadyCoveredNote,
            alreadyCoveredDismissed: p.alreadyCoveredDismissed,
            orgDoNotContact: p.orgDoNotContact,
            relationshipCorrectedByPerformerMatch: p.relationshipCorrectedByPerformerMatch,
            performerMatchNote: p.performerMatchNote,
            performerMatchDismissed: p.performerMatchDismissed,
            performerMatchReviewed: p.performerMatchReviewed,
            draftNeedsSalutationReview: p.draftNeedsSalutationReview,
            salutationReviewOverridden: p.isSalutationReviewOverridden,
            draftLintBlockers: DraftIssue.orderedBlockers(
                Set(p.recipients.filter { $0.sendState == .pending }.flatMap(\.draftLintBlockers))),
            draftLintBlocked: p.recipients.contains { $0.sendState == .pending && $0.isBlockedByDraftLint },
            outcomeSourceRaw: p.outcomeSourceRaw,
            hasUnclearedConflict: p.hasUnclearedConflict,
            conflictNote: p.conflictNote,
            conflictBlockedDate: p.conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date,
            runEndDate: p.runEndDate,
            partOfRelatedRun: p.partOfRelatedRun,
            disappearedFromFeed: p.disappearedFromFeed,
            contacts: p.recipients
                .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
                .map(RecipientSnapshot.init),
            reprepDraftRequested: p.reprepDraftRequested,
            reprepContactsRequested: p.reprepContactsRequested,
            reprepLastServedAt: p.reprepLastServedAt
        )
    }
}

extension RecipientSnapshot {
    init(_ r: Recipient) {
        self.init(id: r.id, name: r.name, email: r.email, role: r.role,
                  provenance: r.provenance, sendState: r.sendState, replied: r.replied,
                  lastReplyText: r.lastReplyText, resolution: r.resolution,
                  bounced: r.bounced, outcomeSource: r.outcomeSource,
                  suppressionReason: r.suppressionReason,
                  replyDraftSubject: r.replyDraftSubject, replyDraftBody: r.replyDraftBody,
                  replyDraftRequestedAt: r.replyDraftRequestedAt, intentHint: r.intentHint,
                  replyDraftEditedByDan: r.replyDraftEditedByDan,
                  replyDraftModel: r.replyDraftModel,
                  overrideBody: r.overrideBody,
                  conversationState: r.conversationState,
                  conversationStateSource: r.conversationStateSource,
                  conversationRemindedAt: r.conversationRemindedAt,
                  contactConfidence: r.contactConfidence,
                  contactMethod: r.contactMethod,
                  contactFormURL: r.contactFormURL,
                  contactSourceURL: r.contactSourceURL,
                  delayNoticeAt: r.delayNoticeAt,
                  looksLikeVenue: r.looksLikeVenue,
                  looksLikeVenueDismissed: r.looksLikeVenueDismissed,
                  looksLikePressContact: r.looksLikePressContact,
                  looksLikePressContactDismissed: r.looksLikePressContactDismissed,
                  looksLikeDuplicateContact: r.looksLikeDuplicateContact,
                  looksLikeDuplicateContactDismissed: r.looksLikeDuplicateContactDismissed)
    }
}
