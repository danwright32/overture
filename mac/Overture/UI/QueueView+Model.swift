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
    // #1145: the presenting org, read by the free reachability heuristic at Review (no presenter => nothing
    // to email). Defaulted so existing memberwise-init call sites are unaffected.
    var presenter: String? = nil
    // #1687: the presenting group's name AS THE CARD SHOWS IT, or nil where showing it would only repeat
    // a line beside it or name the room. Resolved once per queue build by QueueModel.items(from:), for
    // the same reason inheritedReachability is (deciding it needs the whole store, and a card must not
    // carry that cost per row). Defaulted so existing memberwise-init call sites are unaffected.
    var presenterLine: String? = nil
    // #1719: the producer/house correction in force for this row's organisation, and the organisation the
    // control acts on. Both resolved once per queue build from the same overrides the gate reads, never
    // looked up in the view: a membership rule stated in a SwiftUI body is one no test can reach (#863).
    var producerStanding: ProducerOverrideEditing.Standing = .none
    var correctableOrganisation: String? = nil
    // What the verdict IS right now, automatic or corrected. Without it the control could only offer two
    // opposite corrections and say nothing about which one was already true, which is a menu asking Dan
    // to choose a state without telling him the state he is in (his walk of the Debug build, 2026-07-29).
    var treatedAsVenue: Bool = false
    // #1788: this row's blank presenter is a name Overture DISCARDED, not a page that named nobody.
    var presenterWasTheRoom: Bool = false
    // #1731: WHY the verdict reads this presenter as the building, so the card can say the specific
    // reason rather than one line for all of them. Derived in the queue build through the same shared
    // function the sheet uses, never re-decided here.
    var readAsTheBuildingReason: OrganisationListing.Reason? = nil
    // #1308 Layer 2: when a reachability probe last researched this show (nil = never). Drives whether the
    // show is still a probe candidate and, later, the firm email-found/not-found badge.
    var reachabilityProbedAt: Date? = nil
    var reachabilityResult: Reachability.ProbeResult? = nil
    // #1722: why the check came back with nothing usable, so the badge can say what it measured instead
    // of claiming the search found nothing. Only ever qualifies the noEmailFound badge's wording; it
    // changes no verdict, no score and no tone.
    var reachabilityEmptyReason: Reachability.EmptyReason? = nil
    // #1724: when a check ran over this show and came home with no answer for it (nil = never, or a later
    // check answered it). The row's only way to tell a show a check MISSED from one no check has been near.
    var reachabilityUnansweredAt: Date? = nil
    // #1598 Phase 5: an answer paid for on a DIFFERENT show by the same organisation. Folded in once per
    // render by QueueModel.items(from:ledger:) (the EngagementLink.group precedent), never looked up per
    // row, because deciding it needs the whole store and a card must not carry that cost. nil is the
    // common case: no answer, or an organisation the producer gate refuses.
    var inheritedReachability: OrgAnswerLedger.Inherited? = nil
    // #970: the page's own words for where the show is, unresolved. The geo verdict is derived from
    // this and the discipline, never stored, so a rule change re-decides every row at once.
    var location: String? = nil
    let priorRelationship: String
    let production: String
    let profile: String
    let coverage: String
    // #384 / #1669: Dan already passed on THIS show. A scoring axis like the five above, and carried for
    // the same reason: the masthead's merit split re-scores the item, and without this it re-scores a
    // show he turned down as if he never had. Defaulted so existing memberwise-init call sites are
    // unaffected.
    var passedOnThisShow: Bool = false
    // #1648: the contact answer AS THE RANKER READS IT, resolved once per queue build with the same
    // `now` that decides the badge's staleness, so the masthead's merit split can never disagree with
    // the score about whether an answer is still current. Defaulted so existing memberwise-init call
    // sites are unaffected.
    var contactRoute: ContactRoute = .unchecked
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
    // #244/#1773: this show was sent with an AI draft recorded behind it, so Dan's edits to it are
    // something the voice loop can learn from, and whether he has opted this one out. Resolved here
    // rather than looked up per card: the row factory used to answer this by scanning the whole
    // prospect array for the card it was building, once per card, on every render pass.
    var voiceLearningCandidate: Bool = false
    var excludedFromVoiceLearning: Bool = false
    // At least one recipient is still pending with an address, so this performance can still send (#394).
    // Drives the Send button under fan-out: the lead `sentAt` rollup flips on the FIRST recipient, but
    // the button must persist until the LAST recipient goes, so it gates on this, not on `isSent`.
    var hasPendingRecipient: Bool = false
    // #1324: a real email exists but only as a venue front desk or press inbox (held by the venue/press
    // guard, so not sendable). Lets the reachability badge say "Weak contact only" rather than the untrue
    // "No email found". Only meaningful once probed and when hasPendingRecipient is false.
    var hasWeakContactEmail: Bool = false
    // #1798: which guard is holding that address, so the row's sentence names what actually happened.
    // Defaulted so existing memberwise-init call sites are unaffected.
    var weakContactHoldReason: Recipient.HoldReason? = nil
    // #1680: the source pages this row was found on. Mirrors Prospect.runSourceURLs.
    //
    // #1825: NOT what decides the listing link's label any more, and it never could. `RunGrouping` fills
    // it by compactMapping the run members' OWN listing URLs, so a row is always inside its own run's
    // URLs and the comparison matched on all but 10 of the live store's 702 linked rows. It stays because
    // FeedReconcile genuinely needs "every URL this run's nights came from"; the label needs a different
    // fact and now reads its own field below. Two readers, two facts, no shared field to disagree about.
    var runSourceURLs: [String] = []
    // #1825: the calendar addresses of the watched sources this row came from. The fallback link IS the
    // source's own address, so this is what separates a link to THIS show from a link to the venue's
    // whole listing page. Empty when the row names no source still on the watchlist (3 rows on the live
    // store), which reads as the ordinary label rather than a claim nothing verified.
    var sourceCalendarURLs: [String] = []
    // #1630: what the Review row offers for a show whose only way through is the act's own contact form.
    // Decided in the domain (FormPitch), so the row only renders it.
    var formPitch: FormPitch.State = .unavailable
    // #1311: any recipient carries a real address (sendable, or held by a guard). Distinguishes a show
    // with NO way to email at all from one whose only email is held for a review, so the Send surface can
    // say "no email to send to" only when that is actually true.
    var hasAnyEmailContact: Bool = false
    // #792: contacts on this show held back by a review guard, each waiting on one glance from Dan. A
    // show can be genuinely Sent AND still have somebody waiting; the bug was that the row said only the
    // first, so the person waiting vanished with the show.
    var blockedContactCount: Int = 0
    // #1797: whether this show has reached the half of the funnel a send belongs to. Snapshotted from the
    // prospect through the SAME rule the stage asks (SendHalf), because the two decide one thing between
    // them: who tells Dan about a contact a guard is holding.
    var hasEnteredSendHalf: Bool = false
    var sendError: String? = nil
    var lostReason: String? = nil
    var classificationOverriddenByDan: Bool = false
    // #1274: true once Dan has manually renamed this show, so the row can offer "reset to scout name".
    var groupNameOverriddenByDan: Bool = false
    var bookingSuggested: Bool = false
    // #611: a fit-risk Prep's own research found (the org's site names its own photographer),
    // dismissible without changing fitScore/tier or the whole prospect's status.
    var alreadyCoveredNote: String? = nil
    var alreadyCoveredDismissed: Bool = false
    // #1824: what the Prep run found this show to BE, read off its own listing page, or the honest reason
    // there is nothing to say. Drawn under the header by ProspectRowView.showSummaryNote.
    var showSummary: String? = nil
    var showSummaryAbsence: ShowSummaryAbsence? = nil
    // #1887: how well Dan already knows this ROOM, and the nights it rests on, so the card can show
    // him what the pitch is about to claim on his behalf. Set by the list builder from one shared
    // VenueShootHistory rather than per row, the same way venueBrands is. Nil band means the pitch
    // will say nothing, which includes a Carnegie show by design.
    var venueHistoryBand: VenueShootHistory.Band? = nil
    var venueHistoryShoots: [VenueShootHistory.Shoot] = []
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

    // #1583: whether this show clashes with the calendar AT ALL, as opposed to `hasUnclearedConflict`,
    // which is whether that clash still BLOCKS it. Keep is now the acceptance, so the two diverge the
    // moment Dan keeps a flagged show, and everything that merely TELLS him about the night (the card's
    // sentence, the date header) has to read this one rather than the gate. Accepting a clash stops the
    // blocking, not the telling: he is still busy that night whatever he decided about pitching it.
    //
    // Derived from the blocked NIGHT rather than carried as another stored field, and rather than from the
    // sentence: both come off the conflict key alone, but `conflictScope` already reads the night, so the
    // date header's two halves ("is there a clash" and "is it on THIS date") ask one field instead of two
    // that could disagree about a row whose key decoded only partly.
    var hasConflict: Bool { conflictBlockedDate != nil }
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

    // #1797/#1800: the contact a review guard is holding, when THIS card is the surface that has to say
    // so. Nil once the show is in the send half, because Send issues speaks for it there and the draft
    // review already carries "N contacts held for a check": said in both places it would be the same
    // sentence twice, which is the #843 defect. Nil when nothing is held, obviously.
    //
    // The two are exact complements over one rule (SendHalf), which is the property that matters: a held
    // contact is always spoken for by exactly one surface, never by both and never by neither. A contact
    // waiting on Dan with nothing anywhere saying so is #792, the defect this whole area exists to
    // prevent.
    var heldContactAtTriage: Recipient.HoldReason? {
        guard blockedContactCount > 0, !hasEnteredSendHalf else { return nil }
        return weakContactHoldReason
    }

    // #1145/#1308: the reachability badge shown on a Review row. Before a probe it is the free Layer 1
    // heuristic (only the hard case surfaces); after a probe it is the firm email-found/not-found answer.
    // A Review-time decision aid, so it only shows while the show is still a candidate (not yet pitched,
    // not booked); a sent or booked show was clearly reachable.
    // #1325: a method (not a property) so staleness is decided against an injectable `now`, keeping the
    // freshness logic testable rather than reading the wall clock from inside the view (the #863 lesson).
    // The view calls it with the default; tests pass a fixed `now`.
    func reachabilityBadge(now: Date = Date()) -> Reachability.Badge {
        guard sentAt == nil && !isBooked else { return .none }
        return Reachability.badge(result: reachabilityResult,
                                  probeIsStale: Reachability.probeIsStale(probedAt: reachabilityProbedAt, now: now),
                                  inherited: inheritedReachability?.result,
                                  // #1724: through the SAME freshness helper a result goes stale by, at the
                                  // same instant, so the row cannot judge a miss current while judging an
                                  // answer of the same age expired.
                                  missedByACheck: reachabilityUnansweredAt != nil
                                      && !Reachability.probeIsStale(probedAt: reachabilityUnansweredAt, now: now),
                                  presenter: presenter, sourceListingURL: sourceListingURL, websiteURL: websiteURL)
    }

    // #1598 Phase 5: the addresses the row prints under its badge. A show researched itself shows ITS
    // contacts; only a show with none falls back to the organisation's. Mixing the two would put an
    // address on the card that no check on this show ever produced. Decided here (testable, #863) rather
    // than in the view, which used to read `contacts` directly.
    var displayedContactEmails: [String] {
        let own = contacts.compactMap { $0.email?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return own.isEmpty ? (inheritedReachability?.emails ?? []) : own
    }

    // #1788: the line the card shows where the presenter's name would have gone, when the run reported
    // the ROOM and the boundary drained it. Dan's call on the #1766 post-merge check: "flag the card for
    // me", because a show at a room he knows often has a company he can name himself.
    //
    // Shown ONLY where the question is still open: the moment a real presenter is named, on this run or a
    // later one, the card answers "who puts this on?" outright and a mark saying it could not would be
    // saying the opposite of what the row above it shows (the #843 rule against two lines that disagree).
    var unidentifiedPresenterNote: String? {
        guard presenterWasTheRoom, presenterLine == nil else { return nil }
        return "Couldn't tell who's putting this on: the listing named only the room."
    }

    // #1731, after Dan read the Presenters sheet (2026-07-30): "this sheet is confusing. I'm not sure what
    // to do with it." The question that sheet was built to answer, why is no presenter named here, is one
    // he asks while looking at a CARD. Answering it on a separate screen he has to know exists means the
    // answer never reaches the question, so the card answers it.
    //
    // Only where the VERDICT is what hid the name. Measured 2026-07-29: of the 351 rows whose presenter is
    // judged the building, 296 would have their name hidden anyway because the presenter field simply
    // repeats the venue printed directly below it. Nothing is being judged there and nothing needs saying.
    // The verdict uniquely hides 55, and those are the only cards with something to explain.
    var readAsTheBuildingNote: String? {
        guard treatedAsVenue, presenterLine == nil, let presenter, !presenter.isEmpty else { return nil }
        guard let reason = readAsTheBuildingReason else { return nil }
        // The name repeats the venue or the title: the card already shows it, so there is no absence to
        // explain. Compared through the fold the presenter line itself uses, so the two cannot disagree
        // about when a name is a repeat.
        let key = ProducerGate.key(presenter)
        guard key != ProducerGate.key(venue), key != ProducerGate.key(groupName) else { return nil }
        return OrganisationListing.cardLine(presenter, reason)
    }

    // #1626: the contact forms the row offers as a link, when there is no address to print. Only forms
    // on the act's own site: an Instagram is a dead end Dan will not use, so putting it on the card
    // would hand him a control he cannot act on. Same rule as Prospect.usableContactFormURLs, and
    // decided here rather than in the view so the exclusion is testable.
    // #1629: and never the ROOM's own booking form, through the same VenueContactGuard comparison
    // Prospect.usableContactFormURLs uses. The card and the stored verdict have to agree here: if only
    // one of them learned the rule, the row would read "No email found" while still offering the room's
    // form as a link right underneath it.
    var displayedContactForms: [URL] {
        guard displayedContactEmails.isEmpty else { return [] }
        return contacts.compactMap { c -> URL? in
            guard let raw = c.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !Reachability.isSocialOnly(raw),
                  !VenueContactGuard.looksLikeVenue(formURL: raw, venue: venue),
                  // #1636: and the press rule, kept in step with the stored verdict for the same reason
                  // the venue one is.
                  !PressContactGuard.looksLikePressContact(formURL: raw),
                  let url = URL(string: raw), url.scheme != nil else { return nil }
            return url
        }
    }

    // #1628: which of the printed contacts the check was NOT sure about. The badge above says what KIND
    // of contact was found; this says how sure it was, and only for the ones that are not.
    //
    // VERIFIED means exactly what the runbook allows `high` for: an address actually READ from a real
    // page, and for a named performer, corroborated against THIS performance. Everything else is marked.
    //
    // WHY THE THRESHOLD IS THERE AND NOT AT `low`, which is the whole judgment in this change. The stored
    // confidence looked like an independent measure of certainty and is not: measured across all 29 stored
    // contacts on 2026-07-27 it is a near-mechanical restatement of the contact METHOD. Every form or DM
    // is `low` (9 of 9), every generic inbox is `medium` (8 of 8), and a named person is `high` except
    // once. So it cannot tell a form on the RIGHT act's site (marcribler.com, confirmed by #1626) from
    // one on the wrong act's (shop.copeland.band, the Florida rock band on a Red Hook folk room bill),
    // and a mark driven by `low` alone flags both identically.
    //
    // Dan's call, 2026-07-27, made with that measurement in front of him: mark everything that is not a
    // verified address anyway. A generic inbox and a contact form really are weaker than an address read
    // off the act's own page, and he would rather see that stated on every one of them than have the
    // distinction go unsaid because the signal is imperfect. The cost is accepted knowingly: the correct
    // Marc Ribler form wears the same mark as the wrong Copeland one. What would actually separate those
    // two is the CHECK recording what tied a site to the act, which nothing does today.
    //
    // FAILS CLOSED on a missing confidence, which falls out of the same rule: only `high` clears it.
    //
    // Per CONTACT, not per row, because a self-produced show can find two performers and verify only one
    // of them. That is why the mark lives on the address line and not on the row's badge.
    private static func isUnverified(_ c: RecipientSnapshot) -> Bool {
        c.contactConfidence != .high
    }

    // An address INHERITED from another show by the same organisation (#1598 Phase 5) is deliberately
    // never marked: the org ledger stores the addresses that earned the verdict and not how sure each one
    // was, so a mark here would assert something no check ever measured. Absence of a warning is not a
    // claim of verification; asserting one would be. Filed rather than guessed at.
    var unverifiedContactEmails: Set<String> {
        guard !contacts.isEmpty else { return [] }
        return Set(contacts.filter(Self.isUnverified).compactMap {
            $0.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    // #1628, Dan's call 2026-07-28: an address was found, and NOTHING found was verified. The badge says
    // this once, instead of a caveat printed beside every unverified address (which went through three
    // layouts and broke the address column each time, the last by making long addresses wrap).
    //
    // "ALL" is the load-bearing word, and it is what stops this crying wolf. One address read off a page
    // naming the act is enough to write to, so a weaker sibling beside it earns no warning. His words:
    // "it wouldn't say that if we found one unverified and one verified."
    //
    // False when nothing was found at all, since those shows wear a different badge entirely, and false
    // for an answer INHERITED from another show by the same organisation (#1598 Phase 5): the org ledger
    // stores the addresses and not how sure each one was, so calling it unverified would assert something
    // no check ever measured.
    var onlyUnverifiedEmailsFound: Bool {
        guard !contacts.isEmpty else { return false }
        let shown = displayedContactEmails
        guard !shown.isEmpty else { return false }
        return shown.allSatisfy { unverifiedContactEmails.contains($0) }
    }


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
    // #1740: Dan stood this contact's outreach down, and when. Carried so the card can SAY so rather than
    // just quietly showing no follow-up activity, which reads the same as a contact nobody got to.
    var outreachStoodDownAt: Date? = nil
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
            // #1840: says what happened, not what they said. Nobody declined; Dan stopped pitching.
            case .stoodDown: return "You stopped working this"
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

    // #1570: through GeoRefusals, the same value StageNavigation's predicate applies, so the queue's
    // own gate and this one cannot answer differently about a row.
    static func isTooFar(_ item: QueueItem, userExcludedTowns: Set<String>,
                         allowedSeedTowns: Set<String> = []) -> Bool {
        GeoRefusals(userExcludedTowns: userExcludedTowns, allowedSeedTowns: allowedSeedTowns)
            .hidesFromQueue(location: item.location,
                            discipline: Discipline(rawValue: item.discipline) ?? .other)
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

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="untriaged rows carrying neither a source listing URL nor a group website"
    // #1600 Phase 7.2: what the row's reference strip actually has to show. Decided here rather than in
    // the view (#863) so the EMPTY case is reachable by a test: 145 untriaged rows on the live store
    // carry neither link, and they would otherwise draw an empty padded strip.
    //
    // #1534: links, and nothing else. This used to carry a third member, "Contact: pending Prep run",
    // shown on a kept show with no draft. It was a status claim keyed on isKept, and isKept is not what
    // decides whether Prep will pick a show up: PrepQueueBuilder.needsPrepEligible is, and it refuses a
    // show with an open date conflict. So the line promised a Prep run on shows Prep was refusing, and
    // promised a contact hunt on shows whose contact a reachability probe had already found. It also had
    // no one left to tell: a kept, undrafted show only ever appears inside the Prep stage list, whose
    // heading already says these are the shows waiting for a Prep run.
    // #1828: whether this card offers Re-prep, and when it must say why it cannot.
    //
    // Held here rather than as an `if` inside each of DraftReviewView's action branches, which is how the
    // branch that needs it most came to be the one branch without it: a show with NO ADDRESS AT ALL draws
    // the form-pitch row, where "find contacts only" is the highest-value action on the card, and it was
    // the only place Dan could not ask for it. One rule, one place, reachable by a test.
    enum ReprepOffer: Equatable {
        case shown
        case hidden
        // Offered but inert, with the reason to say out loud. NOT hidden: a control that vanishes teaches
        // nothing, and this state is one Dan can clear himself.
        case blocked(String)
    }

    static func reprepOffer(for item: QueueItem) -> ReprepOffer {
        // #367: never on a show already emailed or given up on.
        guard item.isReprepEligible else { return .hidden }
        // The trap #1828's scope note found: PrepQueueBuilder.needsPrep refuses a clashed show BEFORE it
        // reads the re-prep flags, so a run started here does nothing while the acknowledgement says work
        // began. Say so instead of confirming work that cannot happen.
        // The same sentence the action itself uses when it refuses, so the tooltip and the toast can
        // never say two different things about one state (#843).
        if item.hasUnclearedConflict {
            return .blocked(ActionAck.reprepBlockedByClash(org: item.groupName))
        }
        return .shown
    }

    static func rowReferenceLinks(_ item: QueueItem) -> (listing: URL?, website: URL?) {
        (url(item.sourceListingURL), url(item.websiteURL))
    }

    // #1680: what to call the listing link. A per-event link says "Source listing" as it always has; a link
    // that is merely the source's own calendar says so, because the two are different promises and Dan
    // decides whether to click on the strength of the label. Derived rather than stored: the fallback link IS
    // the source's own address, so the comparison is the fact itself, and it classifies the rows already in
    // the store without a migration.
    // #1825: compared against the SOURCE's own calendar address, not against the run's member URLs. The
    // run's URLs are the members' own event pages, so every row matched itself and 639 rows whose link
    // opens a single show's page were announced as the venue's calendar.
    static func listingLinkLabel(_ item: QueueItem) -> String {
        guard let listing = item.sourceListingURL else { return "Source listing" }
        let normalized = canonicalLink(listing)
        return item.sourceCalendarURLs.contains(where: { canonicalLink($0) == normalized })
            ? "Venue calendar"
            : "Source listing"
    }

    // A trailing slash is not a different page, and the fallback link is the source URL verbatim, so one
    // character of spelling would otherwise make a calendar link read as this show's own page.
    private static func canonicalLink(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func rowHasReferenceLinks(_ item: QueueItem) -> Bool {
        let links = rowReferenceLinks(item)
        return links.listing != nil || links.website != nil
    }

    private static func url(_ raw: String?) -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: raw)
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
            // #1687: the pill exists to say "you know these people". Once the card names the group in its
            // own right one line under the title, a pill that also spells the name says it twice on one
            // card, which is the defect #1687 fixes, not a second instance of it.
            //
            // Compared through GroupNameMatch.normalize, which is the fold the MATCHER used to decide
            // these two are the same client in the first place, so the pill can never disagree with it
            // about whether it is repeating the line above. The venue-key fold cannot do this job: it
            // keeps punctuation, and the live store spells this exact pair "Young New Yorkers Chorus"
            // (the Downbeat record) against "Young New Yorkers' Chorus" (the scouted presenter), which is
            // Dan's own card. A collaboration billed as "Tenet Vocal Artists & Alkemie" against the client
            // "TENET Vocal Artists" stays two different strings here, and keeps its pill name, correctly:
            // the line above is naming something the pill is not.
            if let name = item.matchedClientName,
               GroupNameMatch.normalize(name) != GroupNameMatch.normalize(item.presenterLine ?? "") {
                return "Worked together before (\(name))"
            }
            return "Worked together before"
        }
        // #1361: no badge for a past decline. Whether Dan declined a group before (usually just an old
        // date conflict) is irrelevant to a future pitch, so it is deliberately absent here, not forgotten.
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
            return "Possible match to \(possibleMatchOrigin(item.possibleMatchSource)): \(name)?"
        }
        return nil
    }

    // #1695: WHICH list the record came from, in Dan's words.
    //
    // This used to be one ternary: a client, or else "the booking log". "The booking log" covered both the
    // booking sheet he imported once AND Overture's own activity, which includes shows he merely swiped
    // away and never contacted. In #1693 the flag pointed at a date-clash dismissal from the month before
    // (never sent, no reply, no business of any kind) and called it the booking log, which reads as real
    // past business. He could not tell what he was being asked without opening the database, and a flag
    // whose answer requires reading the store is not a flag.
    //
    // So each origin says what it actually is, and what happened with it, because a show he dismissed and
    // a show he booked are the same "history" and could not be less alike as an answer to this question.
    static func possibleMatchOrigin(_ source: String?) -> String {
        switch source {
        case "downbeat_client": return "a past client"
        case "booking_import": return "your booking log"
        case "overture_dismissed": return "a show you dismissed in Overture"
        case "overture_contacted": return "a show you emailed in Overture"
        case "overture_replied": return "a show that wrote back"
        case "overture_booked": return "a show you booked in Overture"
        // Overture's own activity in a state with no better sentence (a lost outcome, a taste pass, a
        // do-not-contact), plus the legacy "history" value on any row stored before this shipped. The
        // launch recheck rewrites those on the next launch; until then this says something true rather
        // than claiming the booking log it might not be.
        default: return "something Overture has seen before"
        }
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

    // #1122: `underway` is a run whose opening night has passed but whose closing night has not. Distinct
    // from `past` (the whole run is over) and from the ordinary upcoming urgencies (it has already
    // started). #1540: it is no longer a PITCHABLE state, and no untriaged row can be in it any more; it
    // survives only to label a run Dan had already kept when it opened, which keeps working.
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
        // The opening night is behind us but the closing-night check above let the run through, so the run
        // is underway. #1540: this row can now only be one Dan already KEPT (triage drops an opened run),
        // and he ruled that nothing may call such a run bookable, which the label used to. The row shows
        // the full date range beside this, so all this has to add is that today falls inside it.
        if days < 0 { return Timing(label: "Run underway", urgency: .underway) }
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

    // #1687: the name of the group, on every card that has one to give, not only on the ones Dan has
    // booked before. Dan, on the Aug 4 queue: "I should be able to see who the group is no matter if I've
    // worked with them or not." Until now `presenter` rode all the way onto the row model and was never
    // drawn, so the only thing naming an ensemble was the gold past-client pill, which by definition
    // appears only where he already knows them. That inverted the pill: it exists to say "you know these
    // people" and was being read as "who is playing".
    //
    // It is a RULE and not a field because the presenter is very often the ROOM. Drawn unconditionally it
    // puts "Jalopy Theatre" directly above "Jalopy Theatre", which is the #843 defect (a second line that
    // tells him nothing the line beside it did not). Four gates, each measured on the live store
    // 2026-07-29 against the 547 rows at status = new that carry a presenter at all:
    //
    //   - it must differ from the TITLE (275 rows fail this and the venue gate between them),
    //   - it must differ from this row's own VENUE, folded, so "Jalopy Theatre" and "Jalopy Theatre, Red
    //     Hook, Brooklyn, NY" count as the same room (the #1498 / #1686 variance),
    //   - it must not be the building's own BRAND (42 more), which the row alone cannot decide: all 18
    //     Carnegie rows carry "Carnegie Hall Presents" over a venue spelled "Stern Auditorium", so no
    //     comparison against this row's venue ever fires. That judgment is #1702's, shared rather than
    //     copied, and it is INERT without a corpus by design (ProducerGate.VenueBrands.none),
    //   - and the TITLE must not already name it (15 more), or the card reads "Camerata Nordica" directly
    //     above "Camerata Nordica Octet".
    //
    // 215 of 559 rows draw it today; the rest stay silent.
    //
    // Dan chose the BARE NAME over "Presented by X" (2026-07-29), having read that the field mixes the
    // act with its agency (AGP Agency Inc., The Bowery Presents and Hong Kong Bay Sea Art Co. all survive
    // the four gates and none of them played a note). So this returns the stored name and nothing else:
    // no label is wrapped around it anywhere, here or in the view.
    static func presenterLine(title: String, presenter: String?, venue: String?,
                              venueBrands: ProducerGate.VenueBrands = .none) -> String? {
        let name = (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let presenterKey = ProducerGate.key(name) else { return nil }
        // ProducerGate.key rather than VenueNormalization.normalizeForKey directly: it is that fold plus
        // the parenthetical and leading-"the" reductions #1620 added, which is the comparison every other
        // presenter-versus-venue question in the app already uses.
        guard presenterKey != ProducerGate.key(title) else { return nil }
        guard presenterKey != ProducerGate.key(venue) else { return nil }
        guard !venueBrands.contains(name) else { return nil }
        if let titleKey = ProducerGate.key(title),
           ProducerGate.containsAsWords(titleKey, presenterKey) { return nil }
        return name
    }

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
            // #1540, reversing #1122: both edges of the window are judged by the run's OPENING night. A
            // run that has already started leaves triage (Dan will not pitch a client who has opened),
            // and a run that opens beyond the lead-time window is still too far out. Asked through
            // Prospect.hasOpened's twin so the pill's count and this list cannot answer it differently.
            //
            // Stage lists (Prep, Review, Reached out) never come through here, so a run Dan kept before
            // it opened keeps working: hiding work already in flight would read as deletion (#1014/#901).
            if EasternDate.runHasOpened(openingNight: item.performanceDate, today: today) { continue }
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

    // #1922: the same fold, applied to groups ALREADY BUILT rather than to the rows going into the
    // derivation. That is the whole point: setting and clearing a departing snapshot used to happen
    // inside the whole-store derivation, so each send dragged all 724 prospects through the CPU twice
    // more to animate one card. Over finished groups, the send animates its own card instead.
    //
    // Sending the only show on a night is the case that makes this more than a move: that night's group
    // has already gone with it, so regrouping is what puts the night back rather than leaving the card
    // Dan is watching with nowhere to land. Expressed through the two tested helpers, so the ordering
    // (existing dates first, a night that exists only for a departing card last) is exactly what the
    // rows-first version produced.
    static func groups(_ groups: [DateGroup], withDeparting departing: [String: QueueItem]) -> [DateGroup] {
        guard !departing.isEmpty else { return groups }
        return groupByDate(withDeparting(groups.flatMap(\.items), departing: departing))
    }

    // #1233: the Reached-out stage groups its rows under headers keyed on the REACH-OUT date (when Dan
    // should next contact them), not the performance date every other stage groups by, while keeping the
    // soonest-first order. Generic over the row so the day-bucketing and header formatting are tested
    // without SwiftData; the view passes its (prospect, recipient, next) tuples and `reachDate` reads next.
    struct ReachOutDateGroup<Row>: Identifiable {
        let id: String
        let weekday: String
        let monthDay: String
        let year: String
        let rows: [Row]
    }

    // #1513: both kinds of Reached-out row in ONE list ordered by when each next needs Dan, so the
    // grouping below produces a single sequence of headings that all answer the same question. An
    // inquiry with no reach-out date is left out rather than dated arbitrarily; it has nothing to be due
    // about, and inventing a date would put a row under a heading that lies about it.
    static func reachedOutEntries(prospects: [(prospect: Prospect, recipient: Recipient, next: Date)],
                                  inquiries: [Inquiry], now: Date) -> [ReachedOutEntry] {
        let prospectEntries = prospects.map {
            ReachedOutEntry.prospect(prospect: $0.prospect, recipient: $0.recipient, next: $0.next)
        }
        // Each inquiry is paired with ITS OWN row rather than matched back by id: a row's id comes from
        // the persistent model id, which is temporary and not yet distinct for an object that has not
        // been saved, so looking the model up by it silently gave every row the first inquiry's date.
        let inquiryEntries = inquiries.compactMap { inquiry -> ReachedOutEntry? in
            guard let due = inquiry.nextReachOutDate,
                  let row = inquiryRows([inquiry], now: now).first else { return nil }
            return .inquiry(inquiry: inquiry, row: row, next: due)
        }
        // Stable: equal dates keep prospects before inquiries rather than reordering run to run.
        return (prospectEntries + inquiryEntries).sorted { $0.next < $1.next }
    }

    // #1513: the numbers behind the "N contacts across M shows" note, counted from the SAME entries the
    // list renders. Counting only prospects made the note smaller than the rows on screen the moment an
    // inquiry joined them, and that note sits directly above those rows.
    //
    // An inquiry is one contact and one event, so it adds one to each: it can never create the fan-out
    // (more contacts than shows) the note exists to explain, and it can never hide it either.
    static func reachedOutNoteCounts(_ entries: [ReachedOutEntry]) -> (contacts: Int, shows: Int) {
        var showKeys = Set<String>()
        var contacts = 0
        for entry in entries {
            switch entry {
            case .prospect(let prospect, _, _):
                contacts += 1
                showKeys.insert("p:\(prospect.naturalKey)")
            case .inquiry(_, let row, _):
                contacts += 1
                showKeys.insert("i:\(row.id)")
            }
        }
        return (contacts, showKeys.count)
    }

    static func reachOutDateGroups<Row>(_ rows: [Row], reachDate: (Row) -> Date) -> [ReachOutDateGroup<Row>] {
        let cal = easternCalendar
        var order: [String] = []
        var buckets: [String: [Row]] = [:]
        var headers: [String: (String, String, String)] = [:]
        for row in rows {
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: reachDate(row))
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
                headers[key] = (shortWeekday(c.weekday ?? 1),
                                "\(shortMonth(c.month ?? 1)) \(c.day ?? 0)",
                                String(c.year ?? 0))
            }
            buckets[key]?.append(row)
        }
        return order.map { key in
            let h = headers[key]!
            return ReachOutDateGroup(id: key, weekday: h.0, monthDay: h.1, year: h.2, rows: buckets[key]!)
        }
    }

    // #1573: the scroll-target identity of a rendered date group, which is what the queue's
    // scrollPosition binding names. Deliberately NOT the bare date: the show groups and the hire-inquiry
    // groups (#1436) sit in the SAME scrollTargetLayout and were both keyed on the raw date, so on a day
    // holding both, one id named two different targets and a jump could land on the inquiry block instead
    // of the show. The group models keep their date-valued `id` (BulkDismiss reads it as a date); only the
    // view identity is namespaced.
    static func showGroupScrollID(_ date: String) -> String { "show-group:\(date)" }
    static func inquiryGroupScrollID(_ date: String) -> String { "inquiry-group:\(date)" }

    // #1573: the group a jump should land on to bring `key` into view, or nil when the key is not among
    // the rendered rows at all. Resolved THROUGH groupByDate rather than by reading the item's date
    // directly, so the id a jump names can never drift from the ids the layout actually draws.
    static func scrollGroupID(containing key: String, among items: [QueueItem]) -> String? {
        guard let group = groupByDate(items).first(where: { group in
            group.items.contains { $0.id == key }
        }) else { return nil }
        return showGroupScrollID(group.id)
    }

    // #1597: everything a multi-date reachability check needs, from the dates Dan ticked. Pure, and out
    // of the view on purpose: the bar and its confirm both read this, and logic living in a SwiftUI body
    // cannot be tested at all, so the arithmetic Dan spends money against would have had no test.
    //
    // Returns nil when nothing is selected. `candidateKeys` is what the run is asked to check, which is
    // every still-open, not-recently-answered show on those dates: the whole selection, no exceptions.
    // #1916: `rows` is an @autoclosure because the two guards below refuse almost every call, and an
    // argument is evaluated BEFORE the call, so the guard could not protect against the cost of building
    // it. The real call site passes `scoutRows(data)`, a sweep of every show in the store, and paid for
    // it on every render pass and every stage to reach a function that returns nil on its first line.
    // Taking the rows as something this function can decline to evaluate keeps the rule in one place
    // (here, where it is tested) instead of copying the two conditions up to the caller.
    static func probeSelection(dates: Set<String>, in rows: @autoclosure () -> [QueueItem], among all: [QueueItem],
                               today: String, stage: StageFocus?, now: Date = Date(),
                               overrides: ProducerOverrides = .none,
                               // #1609: Dan's geography refusals, so a multi-date confirm can never
                               // include, count, or charge for a show somewhere he will not travel.
                               geo: GeoRefusals = .none) -> (ProbeSelection.Summary, [String])? {
        // The bar belongs to Scout, because the checkboxes do. Ticking dates and switching stage left it
        // pinned at the top offering to start a run against a selection Dan could neither see nor change
        // (his walk of the Debug build, 2026-07-27). The selection itself survives the trip: hiding is
        // not discarding, and losing his ticks for glancing at another stage would be the worse bug.
        guard stage == .scout else { return nil }
        guard !dates.isEmpty else { return nil }
        let groups = groupByDate(rows()).filter { dates.contains($0.id) }
        guard !groups.isEmpty else { return nil }
        let selected = groups.flatMap(\.items)
        let candidateKeys = Set(groups.flatMap { reachabilityProbeCandidateKeys($0.items, now: now, today: today, geo: geo) })
        // Open shows on those dates that were answered recently: free, and named in the confirm rather
        // than quietly dropped, because a count that omits rows stops being a promise about what is there.
        let answered = selected.filter { i in
            !candidateKeys.contains(i.id)
                && OpenForDecision.isOpen(status: i.status, performanceDate: i.performanceDate,
                                          isBooked: i.isBooked, sentAt: i.sentAt, today: today)
        }.count
        let asShow: (QueueItem) -> ProbeBatch.Show = {
            ProbeBatch.Show(key: $0.id, presenter: $0.presenter, venue: $0.venue)
        }
        // #1724: of the shows this run WILL look up, how many an earlier check already ran over and came
        // home without an answer for. Counted over the candidates rather than the whole selection, because
        // the sentence is about what is being paid for a second time, and read through the same freshness
        // window the row's own mark is, so the sheet and the card cannot disagree about which shows count.
        let previouslyMissed = selected.filter { i in
            candidateKeys.contains(i.id) && i.reachabilityUnansweredAt != nil
                && !Reachability.probeIsStale(probedAt: i.reachabilityUnansweredAt, now: now)
        }.count
        let summary = ProbeSelection.summarize(
            dateCount: groups.count,
            candidates: selected.filter { candidateKeys.contains($0.id) }.map(asShow),
            alreadyAnswered: answered,
            previouslyMissed: previouslyMissed,
            // The producer gate is judged against the WHOLE queue, never just the ticked dates: judged
            // against one night, every producer looks like a single-venue house and nothing amortises.
            among: all.map(asShow),
            overrides: overrides)
        return (summary, candidateKeys.sorted())
    }

    // #1719: which correction is in force for a presenter, from the overrides already in hand. Mirrors
    // ProducerOverrideEditing.standing, but reads the loaded sets rather than the store, because the queue
    // build has them and re-fetching per row would be several hundred pointless round trips.
    static func producerStanding(of presenter: String?,
                                 overrides: ProducerOverrides) -> ProducerOverrideEditing.Standing {
        guard let key = ProducerGate.key(presenter) else { return .none }
        if overrides.demoted.contains(key) { return .demoted }
        if overrides.promoted.contains(key) { return .promoted }
        return .none
    }

    // #1763: the organisation this row can offer a correction on, or nil when it can offer none. Split
    // out of the build so the rule is testable (#863) rather than stated inside a map closure.
    //
    // Three questions in order, and the order is the rule: a name the gate cannot key has no organisation
    // in it at all; a correction already in force always keeps its way back; and what remains is offered
    // only where a correction could actually move the verdict.
    static func correctableOrganisation(_ presenter: String?,
                                        venueBrands: ProducerGate.VenueBrands,
                                        standing: ProducerOverrideEditing.Standing) -> String? {
        guard let presenter, ProducerGate.key(presenter) != nil else { return nil }
        if standing != .none { return presenter }
        return venueBrands.isRoomName(presenter) ? nil : presenter
    }

    // What the menu says. One sentence per state, each naming the organisation, so the line Dan reads is
    // about a specific name rather than a rule in the abstract. Kept out of the view with every other
    // sentence the app can say (#915).
    static func producerCorrectionLabel(_ standing: ProducerOverrideEditing.Standing,
                                        organisation: String,
                                        treatedAsVenue: Bool) -> String {
        // "Presenter", never "producer": it is Dan's own word for this and the app's own field name
        // ("watch the venue, pitch the presenter"), and the gate's internal vocabulary is not his problem.
        //
        // Dan's walk of the Debug build, 2026-07-29, on a menu that offered both directions at once:
        // "these are mutually exclusive? What is it currently being treated as?" He was right, and the
        // answer was nowhere on screen. "No correction in force" is NOT "no verdict": the gate has always
        // already decided, and offering both corrections as equals hid which one was true. So the menu now
        // STATES the verdict (producerVerdictLine) and offers only the single action that changes it.
        // A correction in force offers the way back to automatic instead.
        switch standing {
        case .none:
            return treatedAsVenue
                ? "Treat \(organisation) as the presenter instead"
                : "Treat \(organisation) as the venue instead"
        case .demoted, .promoted:
            return "Go back to deciding \(organisation) automatically"
        }
    }

    // The state line above the action, naming WHO decided. Dan needs that distinction: a verdict he set
    // is his to revisit, and one Overture reached is a rule doing its job, and the two invite different
    // responses to the same wrong answer.
    static func producerVerdictLine(_ standing: ProducerOverrideEditing.Standing,
                                    treatedAsVenue: Bool) -> String {
        let what = treatedAsVenue ? "the venue" : "the presenter"
        return standing == .none ? "Overture decided: \(what)" : "You set this: \(what)"
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
            return DateGroup(id: key, weekday: "", monthDay: Self.undatedGroupLabel, year: "", items: bucket)
        }
    }

    // ── Hire inquiries fold into the same daily list (#1436) ─────────────────────

    // Live inquiries as display rows. A booked or hand-lost inquiry is closed and leaves the daily
    // list, exactly as a confirmed booking leaves the pitch queue. Nudge/closing state is computed
    // against `now` here so the row is a pure snapshot.
    static func inquiryRows(_ inquiries: [Inquiry], now: Date) -> [InquiryRow] {
        inquiries.filter { $0.isOpen }.map { inquiry in
            InquiryRow(
                id: String(describing: inquiry.persistentModelID),
                inquirerName: inquiry.inquirerName,
                source: inquiry.source,
                eventName: inquiry.eventName,
                performanceDate: inquiry.performanceDate,
                venue: inquiry.venue,
                outcome: inquiry.outcome,
                sentAt: inquiry.sentAt,
                replied: inquiry.replied,
                bookingSuggested: inquiry.bookingSuggested,
                followUpNudgeDue: inquiry.followUpNudgeDue(now: now),
                shouldSuggestClosing: inquiry.shouldSuggestClosing(now: now)
            )
        }
    }

    // The unified daily list: scouted shows (run through the SAME pitch windowing as always) plus
    // inquiries, which are NEVER dropped by that window. THE AUDIT (#1436, the plan's worst failure
    // mode): an inquiry is live because someone awaits Dan's reply, whatever the event date, so a past,
    // far-future, or unknown event date must never remove it. Rows interleave by date via a stable sort
    // (undated last), preserving each source's own order within a date.
    static func combinedQueueRows(prospectItems: [QueueItem], inquiryRows: [InquiryRow],
                                  reachedOutKeys: Set<String>, today: String) -> [QueueRow] {
        let prospectRows = toSendQueue(prospectItems, reachedOutKeys: reachedOutKeys, today: today)
            .map { QueueRow.prospect($0) }
        let inquiryQueueRows = inquiryRows.map { QueueRow.inquiry($0) }
        return (prospectRows + inquiryQueueRows).enumerated().sorted { lhs, rhs in
            switch (lhs.element.performanceDate, rhs.element.performanceDate) {
            case let (a?, b?): return a != b ? a < b : lhs.offset < rhs.offset
            case (nil, .some): return false     // undated groups last
            case (.some, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map { $0.element }
    }

    // Groups QueueRows by date, mirroring groupByDate exactly (undated bucket last, naming itself). The
    // caller passes combinedQueueRows output, already date-ordered, so buckets appear in date order.
    static func groupRowsByDate(_ rows: [QueueRow]) -> [RowDateGroup] {
        var order: [String] = []
        var buckets: [String: [QueueRow]] = [:]
        for row in rows {
            let key = row.performanceDate ?? "tbd"
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(row)
        }
        return order.map { key in
            let bucket = buckets[key] ?? []
            if key != "tbd", let d = day(key) {
                let cal = easternCalendar
                return RowDateGroup(
                    id: key,
                    weekday: shortWeekday(cal.component(.weekday, from: d)),
                    monthDay: "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))",
                    year: String(cal.component(.year, from: d)),
                    rows: bucket
                )
            }
            return RowDateGroup(id: key, weekday: "", monthDay: Self.undatedGroupLabel, year: "", rows: bucket)
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

    // #1567: isReachableInQueue and isReachableForDeepLink lived here. Whether a show renders in the
    // Queue, and so whether an OmniFocus tap or a search pick opens the Queue or Archive, is now
    // StageNavigation.opensInQueue: it asks the same predicate the focused list renders from instead of
    // re-deciding it here behind a date window no stage list applies. Their cases, the dismissed show,
    // the past show, the late reply on a reached-out lead, moved to QueueShowableIsOneFilterTests.

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
    //
    // #1583: asks `hasConflict`, not `hasUnclearedConflict`. Keep now accepts the clash, so the gate goes
    // down on the first show Dan keeps, and reading the gate here would take the marker off the header the
    // moment he said "I can shoot this anyway". That decision is about whether to PITCH the show; the
    // calendar is blocked either way, and the header's job is to say what the day is.
    static func groupIsUnavailable(_ items: [QueueItem]) -> Bool {
        items.contains { $0.hasConflict && conflictScope($0) == .thisNight }
    }

    // #1501: which night of a flagged show's run the clash is on, derived from two fields the item already
    // carries so the header, the pill and the sentence are three renderings of ONE decision rather than
    // three rules that eventually contradict each other on screen (#863/#885).
    static func conflictScope(_ item: QueueItem) -> ConflictScope? {
        ConflictScope.of(blockedDate: item.conflictBlockedDate, performanceDate: item.performanceDate)
    }

    // #1219: self double-booking. The detection lives here (testable, the #863 lesson); the views just
    // render it. A row counts as a same-date COMMITMENT on PERSISTENT facts (a confirmed booking, a pitch
    // already sent, or a live draft), never on a mutable stage, so the signal cannot vanish when a show
    // moves stage (#1246). groupName is both the production key (a run or the same show, shared groupName,
    // is not a double-booking) and the display name a warning uses to say WHICH other show clashes.
    // #1308 Layer 2: the shows on a date worth an opt-in reachability check. Only still-open
    // pre-commitment candidates count: a booked, already-sent, or drafted/approved show is past the
    // keep/dismiss moment, and an already-probed show already has its answer. Pure and tested; the view
    // renders it.
    // #1332: an unprobed show OR one whose probe has gone STALE (#1325) is a candidate. Without the stale
    // arm the "Reachability may be out of date" badge would tell Dan to re-check a show the control never
    // includes. `now` decides staleness; the view passes the wall clock, tests inject it.
    // #1595 / #1587: candidacy is now the SHARED OpenForDecision predicate plus "has no fresh answer yet".
    // It used to spell out its own status test, which admitted kept shows and never asked whether the run
    // had already opened, so it disagreed with the Scout list Dan actually triages and would offer to
    // spend real money on a show the queue refuses to display.
    //
    // #1609: geography is applied HERE, not merely relied on upstream. StageNavigation gates every stage
    // list (#1570), so a Scout row reaching this rule was already filtered, but that made this safe only
    // by accident of ordering. The #308 away-alert leads list renders through the same date section with
    // no stage focus, skips that filter entirely, and its rows are untriaged, so the Check button appeared
    // on them: a paid Opus lookup on a show Overture refuses to display anywhere else.
    //
    // The issue filing this said it first needed a `location` field on QueueItem. That was true when it
    // was written and is not any more; the field exists and is populated from the prospect, so the gate is
    // just an application of the same GeoRefusals value the queue's own filter uses. Asking it here means
    // the two cannot answer differently about a row, which is the #1570 lesson applied one level down.
    //
    // The asymmetry is deliberate and comes straight from GeoRefusals (#970): a POSITIVE placement out of
    // range excludes, and anything Overture cannot read is kept. Most rows carry no location at all, and a
    // gate that treated silence as refusal would quietly stop offering checks on almost the whole queue.
    // LIVE-STORE-CLAIM verified=2026-07-27 measure="paid lookups saved by not offering a check on a show that already carries an inherited organisation answer"
    // #1598 Phase 5: a show already carrying an INHERITED answer is not a candidate either. This is where
    // the saving actually lands (59 lookups on the live store as measured 2026-07-27), and without it the
    // card would contradict itself: "Email found" sitting beside a button offering to go and find one.
    static func reachabilityProbeCandidateKeys(_ items: [QueueItem], now: Date = Date(),
                                               today: String = QueueModel.easternToday(),
                                               geo: GeoRefusals = .none) -> [String] {
        items.filter { probeIsWorthOffering($0, today: today, geo: geo)
                        && !hasFreshReachabilityAnswer($0, now: now) }.map(\.id)
    }

    // A show a paid check could still be about: Dan has not decided yet, and it is somewhere he travels.
    // Split out for #1617, which needs the SAME two questions to tell a date that is finished apart from
    // one that is bare for a reason nobody checked. Asked twice in two spellings they could disagree, and
    // the marker would then claim a date had been checked because the candidacy rule had dropped it for
    // some entirely different reason.
    private static func probeIsWorthOffering(_ i: QueueItem, today: String, geo: GeoRefusals) -> Bool {
        OpenForDecision.isOpen(status: i.status, performanceDate: i.performanceDate,
                               isBooked: i.isBooked, sentAt: i.sentAt, today: today)
            && !geo.hidesFromQueue(location: i.location,
                                   discipline: Discipline(rawValue: i.discipline) ?? .other)
    }

    // An answer this row can show right now: its own check while it is still fresh (#1332), or the
    // organisation's, inherited from a check paid for on another of its shows (#1598 Phase 5).
    private static func hasFreshReachabilityAnswer(_ i: QueueItem, now: Date) -> Bool {
        if i.inheritedReachability != nil { return true }
        return i.reachabilityProbedAt != nil
            && !Reachability.probeIsStale(probedAt: i.reachabilityProbedAt, now: now)
    }

    // #1617: this date has nothing left to check BECAUSE its shows have been answered, which is a
    // different thing from having nothing to check at all. Dan met the second on his walk of the Debug
    // build (2026-07-31): a Scout date drew a bare heading, no button and no tick box, and he read the
    // feature as broken rather than that date as finished.
    //
    // False only when nothing on the date was ever the check's business: a night whose shows are all past
    // the keep-or-dismiss moment, or somewhere he has refused to travel, was never checked and must not
    // say it was. Those headings stay bare, which is honest; the marker is a claim, so it is made only
    // where an answer actually exists.
    static func dateReachabilityIsFullyChecked(_ items: [QueueItem], now: Date = Date(),
                                               today: String = QueueModel.easternToday(),
                                               geo: GeoRefusals = .none) -> Bool {
        guard reachabilityProbeCandidateKeys(items, now: now, today: today, geo: geo).isEmpty else {
            return false
        }
        return items.contains { probeIsWorthOffering($0, today: today, geo: geo)
                                 && hasFreshReachabilityAnswer($0, now: now) }
    }

    // #1595, then Dan's walk (2026-07-27): `usesStaleRecheckHeadline` (formerly isLoneStaleRecheck) is
    // GONE along with both callout headlines. It chose between two sentences the control no longer shows.
    // A stale result still announces itself where it belongs, on the ROW, via Reachability.Badge.staleProbe.

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
    // #1626: how a contact form is labelled on the row, which is by the SITE it lives on. The pill above
    // it already says "Contact form only", so repeating that here would be the #843 shape; what this line
    // owes Dan is the same thing the address line owes him, who he would be writing to. Kept out of the
    // view so the trimming is testable.
    static func contactFormSiteLabel(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // #1598 Phase 5: `answers` is the stored organisation ledger and `corpus` is EVERY prospect in the
    // store, dismissed rows included. The corpus is separate from `prospects` on purpose: the queue's own
    // @Query filters dismissed shows out, and judging the producer gate against that filtered list would
    // let a triage decision quietly change which organisations qualify (see OrgAnswerLedger). Both
    // default to empty so the many call sites that only want rows (Archive's own list, tests) are
    // unaffected and simply inherit nothing.
    static func items(from prospects: [Prospect],
                      answers: [OrgReachabilityAnswer] = [], corpus: [Prospect]? = nil,
                      overrides: ProducerOverrides = .none,
                      sources: [WatchedSource] = [],
                      now: Date = Date()) -> [QueueItem] {
        let linked = EngagementLink.group(prospects.map(EngagementLink.Row.init))
        let inherited = inheritedAnswers(answers, corpus: corpus ?? prospects,
                                         overrides: overrides, now: now)
        // #1687: built ONCE here from the same whole-store corpus the gate above judges against, never per
        // row. Deciding whether a presenter is really its building's brand walks every presenter in the
        // store against every venue spelling in it (roughly 400 by 114 on Dan's), which is a cost a card
        // must not pay on every render. The corpus is deliberately the unfiltered store rather than the
        // caller's rows, so a dismissal cannot quietly change which names draw.
        let venueBrands = ProducerGate.VenueBrands(
            shows: (corpus ?? prospects).map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
            overrides: overrides)
        // #1887: built ONCE here for the same reason venueBrands is. It reads the shoot-history file
        // and the Downbeat export, which a card must not do on every render.
        let shootHistory = VenueShootHistory.current()
        // #1825: built ONCE, for the same reason as the two above. Every row resolves its own sources
        // through this rather than walking the watchlist per card.
        let calendarBySourceId = Dictionary(
            sources.compactMap { s -> (String, String)? in
                guard let u = s.listingsURL, !u.isEmpty else { return nil }
                return (s.sourceId, u)
            },
            uniquingKeysWith: { first, _ in first })
        return prospects.map {
            var item = QueueItem($0)
            item.sourceCalendarURLs = $0.sourceIds.compactMap { calendarBySourceId[$0] }
            // #1887: read from the one history built above, never rebuilt per row (it loads a file).
            item.venueHistoryBand = shootHistory.band(for: $0.venue)
            item.venueHistoryShoots = shootHistory.shoots(for: $0.venue)
            item.linkedEngagementMembers = linked[$0.naturalKey] ?? []
            item.inheritedReachability = inherited[$0.naturalKey]
            // #1648: one staleness evaluation, feeding both the badge and the merit split.
            item.contactRoute = $0.contactRouteForScoring(now: now)
            item.presenterLine = presenterLine(title: $0.groupName, presenter: $0.presenter,
                                               venue: $0.venue, venueBrands: venueBrands)
            item.producerStanding = producerStanding(of: $0.presenter, overrides: overrides)
            // Only an organisation the gate can actually key is correctable. A name that folds away to
            // nothing would store a key no presenter can ever match, which reads exactly like no
            // correction at all.
            //
            // #1763: and only one a correction could actually MOVE. A presenter spelled exactly like a
            // room is refused by isVenueBrand's first line, before it ever reads overrides.promoted, so
            // promoting it stores a key the gate then ignores. Measured on the live store 2026-07-29:
            // 15 organisations, 312 rows, all 15 still refused after being promoted. Offering the control
            // there is the #1679 shape, a correction that reads as applied while changing nothing, so the
            // row says nothing rather than something untrue.
            //
            // A correction ALREADY in force keeps its control regardless, because the way back is a real
            // state change and stranding Dan with one he cannot take back is the worse failure.
            item.correctableOrganisation = correctableOrganisation(
                $0.presenter, venueBrands: venueBrands, standing: item.producerStanding)
            // Read off the SAME corpus verdict the card itself draws from, so the menu can never state a
            // classification the row is not actually using.
            item.treatedAsVenue = venueBrands.contains($0.presenter)
            item.presenterWasTheRoom = $0.presenterWasTheRoom == true   // #1788
            // #1731: only meaningful where the verdict IS the building; nil otherwise.
            item.readAsTheBuildingReason = venueBrands.contains($0.presenter)
                ? OrganisationListing.buildingReason(
                    isRoomName: venueBrands.isRoomName($0.presenter),
                    standing: item.producerStanding)
                : nil
            return item
        }
    }

    // The SwiftData-to-value boundary, kept here so OrgAnswerLedger itself stays free of the store and
    // its rules stay unit-testable.
    private static func inheritedAnswers(_ answers: [OrgReachabilityAnswer], corpus: [Prospect],
                                         overrides: ProducerOverrides,
                                         now: Date) -> [String: OrgAnswerLedger.Inherited] {
        guard !answers.isEmpty else { return [:] }
        let flat = answers.compactMap { row -> OrgAnswerLedger.Answer? in
            guard let result = row.result else { return nil }
            return OrgAnswerLedger.Answer(orgKey: row.orgKey, result: result, probedAt: row.probedAt,
                                          presenterName: row.presenterName, emails: row.foundEmails)
        }
        let shows = corpus.map {
            OrgAnswerLedger.Show(key: $0.naturalKey, presenter: $0.presenter, venue: $0.venue,
                                 hasOwnAnswer: $0.reachabilityProbedAt != nil)
        }
        return OrgAnswerLedger.inherited(from: flat, shows: shows, now: now, overrides: overrides)
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
    // The header an undated group names itself with, shared by groupByDate and groupRowsByDate so the
    // two never drift and the sentence lives in one place (#1436).
    static let undatedGroupLabel = "Date to be confirmed"

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
            presenter: p.presenter,
            reachabilityProbedAt: p.reachabilityProbedAt,
            reachabilityResult: p.reachabilityResult,
            reachabilityEmptyReason: p.reachabilityEmptyReason,
            reachabilityUnansweredAt: p.reachabilityUnansweredAt,
            location: p.location,
            priorRelationship: p.priorRelationship,
            production: p.production,
            profile: p.profile,
            coverage: p.coverage,
            passedOnThisShow: p.passedOnThisShow,
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
            // #244/#1773: a sent show with the AI's original wording still recorded is something the
            // voice loop can learn from. Resolved once here, so the card is handed the answer instead
            // of searching the whole store for its own model to work it out.
            voiceLearningCandidate: p.sentAt != nil && p.originalDraftBody != nil,
            excludedFromVoiceLearning: p.excludedFromVoiceLearning,
            hasPendingRecipient: p.recipients.contains(where: \.isSendablePending),
            // #1324: a real address held by a guard, so the badge can say so rather than "No email found"
            // when that is all a check found. #1798: the same shared definition the stored verdict uses,
            // because these were two copies of one rule and both were missing the duplicate guard.
            hasWeakContactEmail: p.recipients.contains(where: \.isHeldByAGuard),
            // #1798: WHY it is held, so the sentence beside it is true of this row.
            weakContactHoldReason: p.recipients.compactMap(\.holdReason).first,
            formPitch: FormPitch.state(of: p),
            // #1311: any recipient with a real address at all, so the Send surface can tell "no email to
            // send to" apart from "an email exists but is held for a review".
            hasAnyEmailContact: p.recipients.contains { $0.email?.isEmpty == false },
            blockedContactCount: p.blockedContactCount,
            hasEnteredSendHalf: p.hasEnteredSendHalf,   // #1797
            sendError: p.sendError,
            lostReason: p.lostReason,
            classificationOverriddenByDan: p.classificationOverriddenByDan,
            groupNameOverriddenByDan: p.groupNameOverriddenByDan,
            bookingSuggested: p.bookingSuggested,
            alreadyCoveredNote: p.alreadyCoveredNote,
            alreadyCoveredDismissed: p.alreadyCoveredDismissed,
            showSummary: p.showSummary,
            showSummaryAbsence: p.showSummaryAbsence,
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
        // #1680: assigned after the memberwise init rather than inside it. That call is already at the
        // Swift type-checker's limit for one expression (adding this as an argument tips it into
        // "unable to type-check in reasonable time"), and one more field is not worth restructuring it.
        self.runSourceURLs = p.runSourceURLs
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
            outreachStoodDownAt: r.outreachStoodDownAt,
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

// #1500: the queue row, as the little the whole-night dismiss needs to decide. Here rather than in the
// domain so BulkDismiss stays independent of the view's QueueItem, and here rather than in the date header
// so the mapping is one definition instead of one per call site.
extension BulkDismiss.Show {
    init(_ item: QueueItem) {
        self.init(key: item.id, groupName: item.groupName,
                  performanceDate: item.performanceDate, runEndDate: item.runEndDate)
    }
}
