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
    // #1145: the presenting org, read by the free reachability heuristic on Scout, where Dan triages
    // (#1586: no presenter => nothing to email). Defaulted so existing memberwise-init call sites are
    // unaffected.
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
    // #2261: Dan has asked for this show to be checked again despite its existing answer.
    var reachabilityRecheckRequestedAt: Date? = nil
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
    // #2524: Scout is holding this show ONLY because it is a returning client's, so the card says so.
    // Resolved once per queue build for the same reason `inheritedReachability` is: deciding it needs the
    // watched sources and Dan's client roster, and a card must not carry a whole-store lookup per row
    // (#1429). Defaulted so existing memberwise-init call sites are unaffected, and false is the honest
    // answer for a caller with no client window, which is Archive.
    var offeredEarlyAsAClient: Bool = false
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
    var showOutcome: ShowOutcome? = nil

    // Trigger 2: the drafted email, when present. Contact identity (name/role/email/confidence/
    // method/form URL) lives per-recipient on `contacts` now (#654); see `primaryContact`.
    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftEditedByDan: Bool = false
    // #2007: Dan wrote this email himself, with no Prep run (Prospect.draftWrittenByDan). Read via
    // draftAuthorLabel below, and by the voice-flag suppression, which treats his own words as his.
    var draftWrittenByDan: Bool = false
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
    // #2015: WHICH contact the next Send will actually email. Resolved from `SendService` itself rather
    // than re-derived here, so the card and the send can never disagree about who is about to receive it,
    // which is the whole failure this exists to close. Nil when nothing can send yet.
    // #2033: every contact the next press of Send reaches, not just the first. On a show sending
    // together that is all of them, and a card naming one person for an email going to two is the defect
    // #2015 was filed to fix, reintroduced.
    var nextRecipientIds: [String] = []
    // #2034: which way this event's email goes, and whether the choice is even offered. A show with one
    // contact is not offered it: a choice between one email and one email is not a choice, and a control
    // that changes nothing is worse than no control.
    var sendsTogether: Bool = true
    var offersSendModeChoice: Bool = false
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
    // #2395: whether an email actually WENT OUT, which is what decides which half of the outcome
    // vocabulary a row's menu offers. Deliberately NOT `hasEnteredSendHalf` above, and the two must not be
    // folded: that one is true for a show merely drafted, and offering "Never heard back" on a show Dan has
    // only drafted asks him how somebody replied to an email that never left.
    var wasPitched: Bool = false
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
    // #2545: the two ways the greeting inside the body can be wrong, each holding the send
    // (Recipient.isBlockedByGreeting), plus how many people the email reaches so the sentence beside
    // the button can say. `greetingOverridden` is Dan's confirmed override, for that exact text.
    var draftMissingGreeting: Bool = false
    var draftGreetingMisaddressed: Bool = false
    // #2579: the third way, and the two names it needs to say which are in disagreement. Carried rather
    // than re-derived on the card, so the sentence Dan reads names the same pair the hold judged.
    var draftGreetingNamesSomeoneElse: Bool = false
    var draftGreetedName: String? = nil
    var draftGreetedContactName: String? = nil
    var greetingAudienceSize: Int = 1
    var greetingOverridden: Bool = false
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
    // #3323: every night this run still plays, already with Dan's drops subtracted (`runNights` is
    // rewritten to the kept list by `RunNightDrop.dropNight`, and rebuilt minus the drops on every scout
    // through `DroppedNight.keeping`). Empty on rows stored before #1523, which is why every reader has to
    // say what it does with an empty list rather than treating it as "no nights".
    var runNights: [String] = []

    // #2864: whether the cold pitch names the show's own night, and never a different one. Advisory,
    // and DELIBERATELY not suppressed on a draft Dan edited, which is the one combination this lint did
    // not previously have. Advisory findings stand down on his own words (#2131, #459) on the grounds
    // that when he writes a sentence he means it. That reasoning holds for a judgment about wording and
    // fails for a contradicted fact: he cannot have meant July 18 for a July 25 show, and the sent draft
    // that proved it had `draftEditedByDan` set.
    //
    // `today` is a parameter so a test pins both ends of the comparison rather than one (L130).
    func eventDateWarning(today: String = EasternDate.today()) -> String? {
        guard let body = draftBody else { return nil }
        return EventDateInDraft.finding(subject: draftSubject, body: body,
                                        performanceDate: performanceDate, runEndDate: runEndDate,
                                        today: today)?.message
    }

    // #1699: the curtain time(s) this card may state, and whether a run's nights disagree. Both come
    // straight off the stored show; the decision about what a RUN may claim was made at scout time
    // (RunStartTimes.across), never here, because the member nights no longer exist by now.
    var performanceStartTimes: [String] = []
    var startTimesVary: Bool = false
    // #1699: every night's times, for the hover behind "Times vary".
    var nightStartTimes: [String] = []
    var partOfRelatedRun: Bool = false
    // #939: the same production at OTHER venues nearby (a recurring Carnegie community-calendar
    // pattern), distinct from partOfRelatedRun above (which means the same venue, a separate run).
    var linkedEngagementMembers: [EngagementLink.Member] = []
    // #3013: this show was left out of the last run Dan started, because another run was already on it.
    // The slot named is the run he PRESSED, not the one holding it, because that is what makes the
    // sentence actionable. nil for every show that was not left out, which is almost all of them.
    var heldBackFrom: String?
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
    // #1940: through the shared definition, so the badge and the Review stage that now excludes this show
    // can never disagree about what "queued" means.
    var isReprepQueued: Bool {
        ReprepRequest.isQueued(draftRequested: reprepDraftRequested,
                               contactsRequested: reprepContactsRequested)
    }
    // #367: re-prep is never offered once sent (.contacted) or given up on (.dismissed); redrafting
    // text already sent, or reviving a dismissed lead, are different actions from re-prep.
    var isReprepEligible: Bool { status != .contacted && status != .dismissed }
    var isHighFit: Bool { tier == "high" }
    var isKept: Bool { status == .queued || status == .drafted || status == .approved || status == .contacted }

    // #1666: the ONE place this card answers "what happens to this show at the next Prep run", and it
    // answers by asking the rule rather than deriving it. `isKept` above is the thing it is not: #1534's
    // "Contact: pending Prep run" was keyed on that, so it promised a run on a show Prep refuses over an
    // open date conflict, and promised a contact hunt on a show whose contact a probe had already found.
    // Deleting that line removed the instance; this removes the gap, so the next status line the card
    // grows has somewhere correct to read from and no reason to work it out again.
    var nextPrepRun: PrepRunIntent {
        PrepQueueBuilder.nextRunIntent(
            for: self,
            probedWithContact: PrepQueueBuilder.probedWithContact(
                probedAt: reachabilityProbedAt, contactEmails: contacts.map(\.email)))
    }

    // The plain yes or no, over the accessor above rather than beside it, so the two cannot disagree.
    var isAwaitingPrepRun: Bool { nextPrepRun != .notQueued }

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

    // #1145/#1308: the reachability badge shown on a triage row. Before a probe it is the free Layer 1
    // heuristic (only the hard case surfaces); after a probe it is the firm email-found/not-found answer.
    // #1586: an aid to the keep/dismiss decision, which happens on Scout, so it only shows while the show
    // is still a candidate (not yet pitched, not booked); a sent or booked show was clearly reachable.
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
                                  presenter: presenter, sourceListingURL: sourceListingURL)
    }

    // #1598 Phase 5: the addresses the row prints under its badge. A show researched itself shows ITS
    // contacts; only a show with none falls back to the organisation's. Mixing the two would put an
    // address on the card that no check on this show ever produced. Decided here (testable, #863) rather
    // than in the view, which used to read `contacts` directly.
    var displayedContactEmails: [String] { displayedContactAddresses.map(\.email) }

    // #2392: the same list, each address carrying whether there is a Recipient behind it. The card needs
    // that to offer a strike, because the two are removed by different routes and it cannot tell them
    // apart from a list of strings: a contact this show researched has a row to take out, while an
    // inherited address is printed from the organisation ledger and has none.
    //
    // `displayedContactEmails` is derived FROM this rather than restating the own-versus-inherited rule,
    // so the strings a card prints and the controls beside them can never disagree about which addresses
    // are on the card.
    struct DisplayedAddress: Identifiable, Equatable, Sendable {
        let email: String
        // nil means the address is inherited: there is no Recipient on this show to delete, and striking
        // it is a fact about the ORGANISATION (Dan's call, 2026-08-09).
        let recipientId: String?
        // nil for the same reason, and for the same address: an inherited one has no contact here to have
        // a send state. It is what decides whether the strike is offered (ContactRowControls).
        let sendState: SendState?
        // #2623: WHOSE address this is. The check that finds an address also names the person and their
        // role, and neither reached the screen, so a card printing a musical director's personal Gmail
        // looked exactly like one printing the billed artist's own. nil where nothing is stored, which is
        // six of the 29 shows measured on 2026-08-13, and always nil for an inherited address.
        let attribution: String?
        var id: String { email }

        // The one place the two stored fields become the line the card prints, so the model and any
        // future surface cannot spell it two ways. A blank stored value (a run writing "" rather than
        // omitting the field) reads as absent, never as an empty line or a stray comma.
        static func attribution(name: String?, role: String?) -> String? {
            func clean(_ s: String?) -> String? {
                let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            let parts = [clean(name), clean(role)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    var displayedContactAddresses: [DisplayedAddress] {
        let own = contacts.compactMap { c -> DisplayedAddress? in
            let email = (c.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return email.isEmpty ? nil : DisplayedAddress(
                email: email, recipientId: c.id, sendState: c.sendState,
                attribution: DisplayedAddress.attribution(name: c.name, role: c.role))
        }
        guard own.isEmpty else { return own }
        // An inherited address is printed from the organisation ledger, which stores addresses and not
        // who they belong to, so naming anybody beside one would assert something no check on this show
        // ever found (L75).
        return (inheritedReachability?.emails ?? [])
            .map { DisplayedAddress(email: $0, recipientId: nil, sendState: nil, attribution: nil) }
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
    // #2421: per CONTACT, not per show. It used to return nothing at all whenever ANY address was on the
    // show, which was right while a form-only contact was something to be tolerated and is wrong now that
    // a real form is a route Dan deliberately keeps (his call, 2026-08-10): on a mixed show it left the
    // form-only people reading "No email yet" with no way to act, which is the state he was looking at.
    //
    // A contact that HAS an address is still never offered a form: its address is the way in, and the
    // form beside it would be a second control for the same person.
    var displayedContactForms: [URL] { displayedContactRoutes().map(\.url) }

    // #2912: the same list, each link carrying whether the card has to say ON ITS OWN LINE that this one
    // is a guess. Derived from this rather than restated beside it, exactly as `displayedContactEmails`
    // is derived from `displayedContactAddresses`, so the links the card draws and the marks beside them
    // can never come from two readings of the same row (L16).
    struct DisplayedRoute: Identifiable, Equatable, Sendable {
        let url: URL
        // The run said only the NAME matched, so nobody established who is on the end of this link.
        let isNameMatchOnly: Bool
        // Whether the LINE says so. False when the badge above is already saying it for every link on the
        // row, which is the common case (one handle, one sentence), because a second line telling Dan
        // nothing the first did not is the #843 shape.
        let marksUnconfirmed: Bool
        var id: URL { url }
    }

    func displayedContactRoutes(now: Date = Date()) -> [DisplayedRoute] {
        let routes = contacts
            .filter { ($0.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { c -> (URL, Bool)? in
                usableContactFormURL(c).map { ($0, c.nameMatchOnly) }
            }
        // The badge can only speak for the row when it is actually carrying that sentence AND every link
        // under it is one of these. Read from the same badge and the same stored reason the card renders,
        // never from a second derivation of them, so the two can never disagree about whether the row has
        // already been told (L16). It fails CLOSED: a row whose badge says something else marks its own
        // lines rather than leaving a bare handle reading as a found contact (L42).
        let badgeSaysIt = reachabilityBadge(now: now) == .noEmailFound
            && reachabilityEmptyReason == .unconfirmedSocialProfile
            && !routes.isEmpty && routes.allSatisfy(\.1)
        return routes.map { DisplayedRoute(url: $0.0, isNameMatchOnly: $0.1,
                                           marksUnconfirmed: $0.1 && !badgeSaysIt) }
    }

    // #1961: the one predicate behind both the links the card offers and the count printed above them,
    // so the pill can never promise more ways in than the card shows (L16). Was inline in
    // displayedContactForms; extracted rather than copied, because two copies of "is this form one Dan
    // would use" is exactly how the card and the stored verdict drifted apart in the first place.
    // #2612: a social profile is one of them now. The card offers what Dan will act on, and he DMs an
    // Instagram by hand exactly as he fills in a form by hand; the two are told apart by the badge above
    // and by the label on the link, not by one of them being hidden.
    private func usableContactFormURL(_ c: RecipientSnapshot) -> URL? {
        guard let raw = c.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !VenueContactGuard.looksLikeVenue(formURL: raw, venue: venue),
              // #1636: and the press rule, kept in step with the stored verdict for the same reason
              // the venue one is.
              !PressContactGuard.looksLikePressContact(formURL: raw),
              let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    // #1961: how many of the people found on THIS show carry a route Dan can actually use. An address
    // counts even when a guard is holding it (the card prints it, and dismissing the check releases it);
    // a form counts only when the card would offer it, which it does only where there is no address at
    // all (#1626). Counted over the show's own contacts and never the organisation's inherited
    // addresses, so the number can never come out larger than the number of people found.
    // #2421: a contact counts as reachable when IT has a route, whether that is an address or a form the
    // card will offer. It used to count addresses and fall back to forms only on a show with no address
    // at all, so a kept form contact beside an emailable one read as a missing address: "7 found, 1
    // reachable" on a card where six of the seven were people, not gaps. Now that a real form is a route
    // Dan keeps deliberately, the number and the list under it say the same thing.
    // #2958: and never a social profile the run itself called a NAME MATCH ONLY. This number is a
    // promise about what the rows hold (L16), which is Overture ASSERTING that a way in exists, and
    // #2912 already settled that such an account cannot support that claim: it excluded exactly this
    // from `Prospect.socialRouteURLs` for the same reason. The handle stays ON the card, marked,
    // because looking at it costs Dan seconds; what changes is only whether it is counted.
    //
    // Measured 2026-09-01: 22 recipients carry the flag, all 22 with a URL and no address, 19 of them
    // on a social host, so 19 rows were counted as a way in by a number whose own app refuses them.
    //
    // SOCIAL only, matching `socialRouteURLs` exactly rather than testing the flag alone.
    // `Prospect.usableContactFormURLs` does not test `nameMatchOnly`, so a flagged NON-social form
    // still reads as `contactFormOnly` and its card still offers the form; dropping it from this count
    // alone would make the number contradict the badge, which is this defect pointing the other way.
    // Whether that list should test the flag too is a question about the VERDICT, not about this count.
    var reachableContactCount: Int {
        contacts.filter { c in
            let address = (c.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { return true }
            guard let form = usableContactFormURL(c) else { return false }
            return !(c.nameMatchOnly && Reachability.isSocialOnly(form.absoluteString))
        }.count
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
    // #1866: unless Dan has overruled the guard that put it here. A contact held down by
    // ContactConfidenceGuard stores `low` because the run named no page, not because anybody judged the
    // address weak; when he says the address really is theirs, that answer is the better evidence and the
    // card stops calling it unverified. Nothing else changes: the stored confidence still says what the
    // guard left, and contactSourceLinkURL still refuses to print a citation that does not exist.
    private static func isUnverified(_ c: RecipientSnapshot) -> Bool {
        if c.heldDownToUnverified && c.heldDownToUnverifiedDismissed { return false }
        return c.contactConfidence != .high
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

    // #1866: WHY the badge above says unverified, which is the half it could never say. Either the check
    // looked and was not sure, or the check WAS sure and ContactConfidenceGuard held it down for naming no
    // page. Same badge, same tone, same position: only the hover sentence differs (the #1722 rule the
    // weak-contact badge already follows).
    //
    // Only ever true where the badge is actually showing that wording, so a plain "Email found" row can
    // never reach the held-down explanation. Judged over the addresses the card PRINTS, because an
    // inherited address has no contact behind it and no guard ever ran on one.
    //
    // "EVERY" is load-bearing, the same way "all" is in onlyUnverifiedEmailsFound above, and for the same
    // reason: this badge speaks for the whole row rather than for one address (the per-address caveat was
    // retired in #1628). On a row holding one held-down find beside one ordinarily weak one, the held-down
    // sentence would be a true statement about half of what Dan is looking at, which is how the previous
    // wording came to say "this one" about a list. The general sentence stays true of everything shown.
    var unverifiedBecauseAGuardHeldItDown: Bool {
        heldDownReasonForTheWholeRow != nil || unverifiedBecauseEveryShownAddressWasHeldDown
    }

    // #2895: WHICH reason, when every held-down address on the row agrees on one.
    //
    // nil when they DISAGREE, and that is the point of asking it over the whole row rather than per
    // address: this badge speaks for the card, so naming one reason over a row holding both would be a
    // true statement about half of what Dan is looking at, which is exactly how the previous wording came
    // to say "this one" about a list (#1866's own note). A mixed row keeps #1866's general sentence, which
    // stays true of everything shown.
    var heldDownReasonForTheWholeRow: ContactConfidenceGuard.HoldDown? {
        guard unverifiedBecauseEveryShownAddressWasHeldDown else { return nil }
        let shown = displayedContactEmails
        let reasons = Set(contacts.filter(\.isHeldDownToUnverified)
            .filter { shown.contains($0.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
            .map { $0.heldDownReason ?? .namedNoPage })
        return reasons.count == 1 ? reasons.first : nil
    }

    private var unverifiedBecauseEveryShownAddressWasHeldDown: Bool {
        guard onlyUnverifiedEmailsFound else { return false }
        let held = Set(contacts.filter(\.isHeldDownToUnverified).compactMap {
            $0.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let shown = displayedContactEmails
        return !shown.isEmpty && shown.allSatisfy { held.contains($0) }
    }


    // #2657: the check came back with contacts and NONE of them can hire Dan.
    //
    // The case it was filed for: 13 contacts on a 54 Below show, every one a co-performer, every one
    // honestly tiered `secondary`, wearing the same gold "Email found" pill and "13 contacts" that a card
    // wears when the check reached the person whose show it is. The tier was computed and dropped (L46).
    //
    // nil in three different situations, and they are all the same answer to Dan (say nothing):
    //   - nobody was found, so there is nothing to judge and the row wears its own badge already;
    //   - somebody with authority WAS found, in which case a crowd of co-performers beside them is not
    //     worth a warning, exactly as one verified address keeps the plain badge in #1628;
    //   - nothing found carries a tier at all, which is unknown rather than weak. Rendering those as a
    //     warning would light up every contact stored before #2622 for no reason, and `ContactTier.best`
    //     already encodes it by answering nil rather than adding a fourth case.
    //
    // Judged over EVERY contact the show holds, deliberately, and not over the sendable-pending set that
    // `Prospect.contactTierFromRecipients` feeds the score. The two answer different questions and both
    // are right: the score asks how good a route Dan can actually use, and this asks who the check found.
    // Using the score's set here would let a producer held by a venue or duplicate guard vanish from the
    // judgment while their address is printed on the card two lines below, so the card would deny finding
    // somebody it is showing him.
    // Only ever spoken under "Email found", which is the one badge that claims Dan can write to somebody.
    // That gate is not a detail: the runbook emits a full contact for a named performer even when no
    // address was verified, so a tier can exist on a show whose badge is "No email found: nobody found to
    // write to". Two negatives, one under the other, the second adding nothing (L118, #843). Every other
    // badge already qualifies the find itself, and "Only a venue or press address" in particular is
    // already saying this in its own words.
    func contactAuthorityGap(now: Date = Date()) -> ContactTier? {
        guard reachabilityBadge(now: now) == .emailFound else { return nil }
        guard let best = ContactTier.best(of: contacts.map(\.contactTier)), best != .primary else {
            return nil
        }
        return best
    }

    // #596: a quick-glance hint when a prospect carries more than one recipient (e.g. 2 named
    // performers found for a self-produced show, #366), so Dan doesn't have to expand every row
    // to see when multiple people were found. nil for the common single-contact case (no clutter).
    // #1961: and it counted contact RECORDS, so a show with two performers who publish no address
    // between them read "2 contacts" beside a badge saying no email was found. Dan, on the live build:
    // "it says 2 contacts and then it says no email found and it has a link to a contact form. that's
    // confusing". It promised two ways in on a card that had one.
    //
    // His choice, 2026-08-02, shown the three renderings side by side: say both numbers, so a performer
    // found is never dropped and one who cannot be reached is never counted as a way in. The short form
    // survives for the healthy case, where every contact found is one he can write to and the second
    // number would only restate the first.
    var contactCountLabel: String? {
        guard contacts.count > 1 else { return nil }
        let reachable = reachableContactCount
        if reachable == contacts.count { return "\(contacts.count) contacts" }
        if reachable == 0 { return "\(contacts.count) found, none reachable" }
        return "\(contacts.count) found, \(reachable) reachable"
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

    // #2007: WHO wrote this draft, in one line, whether that was Dan or a model. An email he wrote by
    // hand carries no model stamp (nothing wrote it but him), so without this it would be the one draft
    // on the screen that says nothing at all about where its words came from.
    var draftAuthorLabel: String? { draftWrittenByDan ? "Written by you" : draftTraceLabel }

    // #1136: the draft trace for the ROW badge specifically. The draft-review panel renders exactly when
    // the item has a draft body (hasDraft) and shows this same "Drafted by opus" line next to "Edited", so
    // a row badge would state it twice. The badge is therefore shown only once the panel is gone (no draft
    // body), which is the archived case #879 built the row badge for: model-vs-outcome staying visible
    // after review. Decided here, tested, not in the SwiftUI row (#863).
    // #2007: reads the AUTHOR label, so an archived show Dan wrote himself keeps saying so here for the
    // same reason a model-written one does. Comparing outcomes across models is what #879 built this for,
    // and "he wrote this one himself" is exactly the row that must not be silently counted as a model's.
    var rowDraftTraceLabel: String? { hasDraft ? nil : draftAuthorLabel }

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
    // #2015: this contact is on the show but is NOT going to be emailed, because a guard is holding it
    // (a venue guess, a press address, a suspected duplicate, the draft lint). "Every email it's going to
    // send to" has to be honest about the ones it will not, or the list quietly overstates itself.
    var isHeldFromSending: Bool = false
    var replyDraftSubject: String? = nil
    var replyDraftBody: String? = nil
    var replyDraftRequestedAt: Date? = nil
    // #2869: the reply draft is on the clipboard and Dan has not said he sent it. On the snapshot
    // because the card decides from it whether to offer the confirm.
    var replyCopiedAt: Date? = nil
    // #2966: WHEN the reply draft this contact is still waiting on was asked for, or nil when nothing is
    // awaited. The ANSWER from `ReplyDraftRequest`, carried across rather than the inputs to it, for two
    // reasons. The snapshot then holds no copy of the rule at all, which is the whole point of there being
    // one (it used to ask "requested and nothing stored" for itself, missing the guard that a request
    // outlives the answer which consumed its draft, so the card offered to restart a run that had finished
    // hours earlier). And the default is the QUIET direction: a snapshot built without it draws no
    // drafting label, where carrying the raw stamps would have made a forgotten field draw a phantom one.
    var awaitedReplyDraftRequestedAt: Date? = nil
    // #2934: the two facts the reply block's mode is decided from, CARRIED rather than re-derived, for the
    // same reason as the line above. The queue's Answer control and the classify run both read
    // `Recipient.hasUnhandledReply`; a second reading of the same fields on the snapshot is how the
    // Archive card came to offer a paid drafting run on a conversation the run itself refuses (L16, L70).
    // Both default to the QUIET direction: a snapshot built without them offers nothing and claims
    // nothing, rather than offering a control the run would find nothing for.
    var hasUnhandledReply: Bool = false
    var replyIsAnswered: Bool = false
    var intentHint: String? = nil
    var replyDraftEditedByDan: Bool = false
    var replyDraftWrittenByDan: Bool = false   // #2131: he wrote it himself, with nothing to edit
    // #2063: everyone Dan's reply to this contact will reach, already resolved through
    // SendGroup.replyAudience (so it carries the fallback, not the raw captured value). The card names the
    // ones that are not this contact, because who a reply reaches is now a fact about the incoming message
    // rather than something he can read off the card he is looking at (L64).
    var replyAudience: [String] = []
    // #846: which model wrote this reply (Recipient.replyDraftModel). Read via replyDraftTraceLabel.
    var replyDraftModel: String? = nil
    // #642 (#634 Phase D): a performer's direct-address draft, so the review screen can show Dan
    // exactly what this specific contact will receive instead of the shared draft body. Only ever
    // set when provenance == .performer; defaulted so existing call sites don't need updating.
    var overrideBody: String? = nil
    var conversationRemindedAt: Date? = nil
    // #1740: Dan stood this contact's outreach down, and when. Carried so the card can SAY so rather than
    // just quietly showing no follow-up activity, which reads the same as a contact nobody got to.
    var outreachStoodDownAt: Date? = nil
    // #654: moved from the now-deleted lead-level QueueItem fields, since contact confidence/method/
    // form-URL are genuinely per-recipient data.
    var contactConfidence: ContactConfidence? = nil
    // #2657: WHOSE authority this contact has, as the run judged it (see ContactTier for Dan's
    // definition). Carried so the card can say when a check came back full of people who cannot hire him.
    // nil where the run declined to judge or the contact predates #2622, which is a different claim from
    // "somebody without authority" and must never be rendered as one.
    var contactTier: ContactTier? = nil
    var contactMethod: ContactMethod? = nil
    var contactFormURL: String? = nil
    // #2912: the run said the only thing matching was the NAME, so the card can mark the link as a guess.
    // False on every contact written before this shipped, which means nobody has said it is one.
    var nameMatchOnly: Bool = false
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
    // #1866: same shape again, for the guard that held a confident find down to unverified because it
    // named no page it was read off. Carried so the card can say WHICH of the two things made its
    // addresses unverified, and so the review panel can offer Dan the same overrule the three above have.
    var heldDownToUnverified: Bool = false
    var heldDownToUnverifiedDismissed: Bool = false
    // #2895: WHICH of the two held it down, so the badge's sentence can say. Carried rather than re-derived
    // here: the guard rewrites the confidence in place, so once `high` has become `low` the snapshot no
    // longer holds what the run claimed and nothing on this side could work it out again.
    var heldDownReason: ContactConfidenceGuard.HoldDown?
    // #2624: the fifth guard, carried the same way, so the review panel can name it and offer the overrule.
    var looksLikeAnotherPersons: Bool = false
    var looksLikeAnotherPersonsDismissed: Bool = false

    var isLooksLikeAnotherPersons: Bool { looksLikeAnotherPersons && !looksLikeAnotherPersonsDismissed }

    // #1866: mirrors Recipient.isHeldDownToUnverified, so the screen and the stored row answer "is this
    // hold in force" through one rule rather than two spellings of it.
    var isHeldDownToUnverified: Bool { heldDownToUnverified && !heldDownToUnverifiedDismissed }

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
    // #2131: Dan's own words are not linted, deliberately, and this now says so rather than inheriting it
    // from a flag that happened to be set. The lint exists to catch the DRAFTER asking for a date or venue
    // the show already carries; when Dan writes the sentence himself he means it, and flagging him was a
    // real complaint about this check. An untouched AI draft is still linted.
    func replyDraftFindings(title: String? = nil, knownsDate: Bool, knownsVenue: Bool) -> [DraftIssue] {
        guard !replyDraftEditedByDan, !replyDraftWrittenByDan, let body = replyDraftBody else { return [] }
        return DraftCheck.findings(in: body, title: title, knownsDate: knownsDate, knownsVenue: knownsVenue)
    }
    // #2063: the people the reply reaches who are NOT this contact. Empty on the ordinary one-to-one
    // reply, which is what keeps the card from restating itself (#843). Case-insensitive, because a stored
    // address spelled differently is the same person and not a second reader.
    // #2131: who wrote the reply on screen, mirroring the cold path's draftAuthorLabel. nil for a draft
    // straight from the drafter, which the trace label beside it already accounts for.
    var replyAuthorLabel: String? {
        if replyDraftWrittenByDan { return "Written by you" }
        if replyDraftEditedByDan { return "Edited" }
        return nil
    }

    var replyAlsoReaches: [String] {
        let own = (email ?? "").lowercased()
        return replyAudience.filter { $0.lowercased() != own }
    }

    // A draft was requested, hasn't arrived, and belongs to an exchange nobody has answered: show
    // progress. #2966: from the shared rule, carried on the snapshot, never re-derived here.
    var isDraftingReply: Bool { awaitedReplyDraftRequestedAt != nil }

    // #2934: what the reply block may offer for this conversation, from the one shared rule.
    var replyConversationMode: ReplyConversationMode {
        ReplyConversationMode.of(hasUnhandledReply: hasUnhandledReply, replyIsAnswered: replyIsAnswered,
                                 hasReplyDraft: hasReplyDraft, isDrafting: isDraftingReply)
    }

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
            // #2112: says what happened, not what they said. Nobody declined; nobody answered.
            case .neverHeardBack: return "Never heard back"
            }
        }
        if bounced { return "Bounced" }
        // #2951: an answered exchange used to read exactly like one waiting on him, forever. The facts
        // #2934 carried onto the snapshot are what let the label tell them apart; it reads the carried
        // answer rather than forming a second one from the stamps (L16).
        if replied { return replyIsAnswered ? "You answered them" : "In conversation" }
        switch sendState {
        case .sent: return "Awaiting reply"
        case .pending: return (email?.isEmpty == false) ? "Not sent yet" : "No email yet"
        case .suppressed:
            switch suppressionReason {
            case .bookedElsewhere: return "Paused (booked elsewhere)"
            case .declined: return "Paused (show declined)"
            case .removedByDan: return "Removed"
            // #2151: on the show because they wrote from this address, never pitched from it.
            case .joinedFromReply: return "Writes from here"
            }
        case .sending: return "Sending…"
        }
    }
}

enum QueueModel {

    // MARK: - Copy and filtering the queue used to do in its own body (#885)

    // The three-clause filter that feeds the "To send (N)" pill. It was written in the view body, so the
    // pill's number was only ever as trustworthy as its untested half. A count is a promise about rows
    // (#863).
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

    // #970. The geo gate, asked here and nowhere else, so no two surfaces can disagree about a row: a
    // count is a promise about the rows behind it (#863).
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
            // #2733: kept as a literal rather than interpolated from `Discipline.label`, so the
            // copy inventory carries a sentence Dan can READ rather than an expression. A test
            // asserts it still names both genres by their current labels, which is what catches
            // the next rename (L41 the other way round: derive the CHECK, not the copy).
            return "Music only travels to the five boroughs. As performing arts this would stay."
        case .insideTheBoroughs, .insideTheRegion, .noLocation, .couldNotPlace:
            return nil
        }
    }

    // #2348: `tooFar` and `tooFarCount` stood here, the rows the gate took and their number. Both ran
    // the filtered set through the retired second queue filter (`toSendQueue`), and nothing in the app
    // called either one, so they went with it. The gate itself (`isTooFar`, above) is unchanged and is
    // still the one place the question is asked.

    // #2707: `chipIsShown` (#996), `tooFarLabel` and `tooFarHelp` stood here, the "Too far" chip's
    // visibility, its label and its two explaining sentences. #1134 removed the four queue filters when
    // navigation became stage-only, and `ToolbarConsolidationGuardTests` pins that they stay gone, so
    // nothing had been able to render any of it since. The gate itself (`isTooFar` / `tooFarReason`,
    // above) is unchanged and still live: it decides which rows a stage shows.

    // #308: the heading on the focused view a multi-lead away alert lands on. It names how many leads it
    // is about to show, so it is a promise about the rows directly beneath it.
    static func newLeadsHeading(count: Int) -> String {
        "\(Plural.count(count, "new lead")) while you were away"
    }

    // #2707: `pendingBookingsHelp` stood here, the pending-bookings chip's two explaining sentences, and
    // it went the same way as its "Too far" twin: #1134 removed the toggle and left the copy. It hid one
    // step longer than the others because the only thing naming it was the COMMENT above `tooFarHelp`
    // saying the two mirrored each other, so it read as reachable until that comment was deleted with the
    // code it described.

    static func fitLabel(isHighFit: Bool) -> String { isHighFit ? "HIGH FIT" : "LONG SHOT" }

    // #885 (guard sweep): the bookings filter's own label, and the AI's read of an incoming reply. The
    // second one is a claim about what a MODEL concluded, so the words matter: "AI read" says whose
    // conclusion it is, which is the difference between a hint and a fact.
    //
    // #2397: the hint is shown as the MODEL wrote it, with no mapping into a vocabulary of ours. It used to
    // be translated through the conversation states, which are retired, and inventing a second translation
    // table would claim more than the hint does.
    //
    // Only its punctuation is touched: the model writes machine tokens ("wants_to_book"), and an underscore
    // on screen is the one part of that Dan should not have to read.
    // #2707: `confirmBookingsLabel` stood here. Removed by the same #1134 pass, and
    // `ToolbarConsolidationGuardTests.theBookingsFilterToggleIsGone` already asserted that QueueView must
    // not name it, which is the sharpest version of this whole class: a guard pinned the screen as gone
    // while its sentence stayed in the inventory for Dan to read.

    static func aiReadNote(hint: String) -> String {
        "AI read: \(hint.replacingOccurrences(of: "_", with: " "))"
    }

    // #2063: who ELSE this reply reaches, or nil when it reaches only the contact whose card it sits on.
    // Nil rather than an empty sentence, so the ordinary one-to-one reply shows no line at all instead of
    // one saying nothing (#843).
    static func replyAlsoReachesLabel(_ others: [String]) -> String? {
        guard !others.isEmpty else { return nil }
        return "Also goes to \(Plural.list(others))"
    }

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
        // #3369: a clash no longer blocks this. It used to, because `needsPrep` refused a clashed show
        // before it read the re-prep flags, so a run started here did nothing while the acknowledgement
        // said work began. Now the run takes it, and the launch confirm names the clash and lets Dan
        // press through, which is his call of 2026-09-01: "Maybe warn me, but let me do it."
        return .shown
    }

    // #2007: whether this card offers "Prep manually", and when it must say why it cannot.
    //
    // Same three states as `reprepOffer` above and for the same reasons: the rule lives here so a test can
    // reach it (#863), and a blocked control stays VISIBLE with its reason rather than vanishing, because
    // a control that disappears teaches nothing and this is a state Dan can clear himself.
    enum ManualPrepOffer: Equatable {
        case shown
        case hidden
        case blocked(String)
    }

    static func manualPrepOffer(for item: QueueItem) -> ManualPrepOffer {
        // Keep is the decision that makes a show prep work at all, and a show that already has an email
        // has nothing to prep, whoever wrote that email.
        guard item.status == .queued, !item.hasDraft else { return .hidden }
        // #1666: the state this control draws comes from the same answer the run itself obeys, never from
        // a flag beside it. #3369 removed the only thing that could make those disagree here: a clash used
        // to hold a kept, undrafted show out of the run, and this control correctly said so. It no longer
        // holds anything, so given the guard above there is nothing left to refuse.
        return .shown
    }

    // #1640: the LISTING link alone. There was a second half here, the act's own site, and it could
    // never be non-nil: `websiteURL` was populated by nothing, so the "Group website" link it fed has
    // never rendered on any card in this app's life. Removed with the field rather than left returning a
    // permanent nil, which is a tuple half nothing can write (L90).
    static func rowListingLink(_ item: QueueItem) -> URL? {
        url(item.sourceListingURL)
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
        listingLabel(listing: item.sourceListingURL, calendars: item.sourceCalendarURLs)
    }

    // The rule itself, over the two facts it needs rather than over a whole card, so a surface that is
    // handed a Prospect can reach it (#2816). One rule in one place: a card and a row describing the same
    // link in two different words is what #1825 was.
    private static func listingLabel(listing: String?, calendars: [String]) -> String {
        guard let listing else { return "Source listing" }
        let normalized = canonicalLink(listing)
        return calendars.contains(where: { canonicalLink($0) == normalized })
            ? "Venue calendar"
            : "Source listing"
    }

    // #2816: the way back to the show's own page, for a stage that draws a ROW rather than a card.
    //
    // Dan, on a Reached out row: "I'll need to add a source link to this page so I can see the source on
    // demand." Reached out is where he decides what to do about an open pitch, and that decision turns on
    // the show itself: what it is, how long it runs, who else is on the bill, whether the listing has
    // changed since the pitch went out. The only web address the row carried was the contact ROUTE, which
    // is the one place he does not need to go back to.
    //
    // Takes the prospect's own facts rather than a QueueItem, because these stages are handed a Prospect
    // and building a card per row would run the send-group derivation (#2046) for a show that has already
    // sent. Nil where there is nothing to link to, so the caller's `if let` is the whole of the empty
    // branch: no heading, no gap, no dead control (L45).
    struct RowListingLink: Equatable, Sendable {
        let url: URL
        let label: String
    }

    static func rowListingLink(listingURL: String?, sourceIds: [String],
                               calendars: [String: String]) -> RowListingLink? {
        guard let url = url(listingURL) else { return nil }
        // The row's OWN sources, never every watched source, so a show can never inherit a calendar
        // address from a source it was not found on (#1825's rule, same resolution as `items(from:)`).
        return RowListingLink(url: url,
                              label: listingLabel(listing: listingURL,
                                                  calendars: sourceIds.compactMap { calendars[$0] }))
    }

    // #1825's table: which watched source publishes which calendar address. Built ONCE by a caller and
    // read per row, never rebuilt per card (#1121). Lifted out of `items(from:)` by #2816 so the rows on
    // Reached out and Follow-ups resolve their links against the same table the queue card does rather
    // than a second copy of it.
    static func sourceCalendarIndex(_ sources: [WatchedSource]) -> [String: String] {
        Dictionary(
            sources.compactMap { s -> (String, String)? in
                guard let u = s.listingsURL, !u.isEmpty else { return nil }
                return (s.sourceId, u)
            },
            uniquingKeysWith: { first, _ in first })
    }

    // A trailing slash is not a different page, and the fallback link is the source URL verbatim, so one
    // character of spelling would otherwise make a calendar link read as this show's own page.
    private static func canonicalLink(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func rowHasReferenceLinks(_ item: QueueItem) -> Bool {
        rowListingLink(item) != nil
    }

    private static func url(_ raw: String?) -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: raw)
    }

    // #350: Choral is no longer its own category (folded into Music); a leftover raw "choral"
    // string degrades to the fallback below rather than a dedicated label.
    //
    // #1657: the words themselves live on `Discipline`, since the picker and the fit reason say the same
    // ones and a second copy here is how they would come to disagree. This function survives only because
    // it takes a RAW STRING: a stored value the enum no longer has is a genre this app cannot state,
    // which is the same answer as one it never read.
    static func disciplineLabel(_ discipline: String) -> String {
        (Discipline(rawValue: discipline) ?? .other).label
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
        // #1929: the possible-match QUESTION is not a flag, and it does not live here. It carries a
        // show's own name, so it is a sentence of unbounded length, and it was rendered as a pill
        // beside "Self-produced" and "Likely uncovered". See possibleMatchQuestion below.
        return nil
    }

    // The possible-match question, which is a QUESTION and not a label (#1929).
    //
    // Dan saw "Possible match to a show you dismissed in Overture: Thomas F. Hulbert Music
    // International Piano Competition Winners Recital?" run off the right edge of the card. Every
    // other history flag is a fixed phrase Overture chose; this one ends in a name Overture did not
    // choose and cannot bound, which is what makes it a different kind of thing from the pills it was
    // sitting among. It gets its own wrapping line, like the row's other explaining sentences.
    static func possibleMatchQuestion(_ item: QueueItem) -> String? {
        guard let name = item.possibleMatchName else { return nil }
        return "Possible match to \(possibleMatchOrigin(item.possibleMatchSource)): \(name)?"
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
    //
    // #1571: THIS IS THE ONE PLACE the queue window and the scout horizon are related, because they
    // are two numbers in two units in two files and nothing used to connect them.
    //
    //   DEMAND  this constant, 90 days, is how far ahead Dan wants to look.
    //   SUPPLY  [[CalendarMonthIndex.defaultHorizon]], 4 whole calendar months, is how far ahead an
    //           ordinary watched source is read. [[ClientHorizon.clientMonths]], 12 months, is the
    //           wider supply for a known client's own calendar.
    //
    // Dan's call, 2026-08-09: 90 days stays, and the scout keeps reading further on purpose, so a show
    // is already in the store by the time it rolls into the window. The gap between the two is the
    // buffer, not an oversight.
    //
    // The one place the buffer runs out, recorded here so it is not rediscovered as a bug: four whole
    // months is 122 days ahead at its furthest and 89 at its shortest, and the short case is 31 January
    // of a year that is not a leap year (February plus March plus April). Asked on that one date the
    // queue's ninetieth day is 1 May and only April has been read, so a show that far out is picked up
    // the following night instead. One day late, one date a year.
    //
    // `QueueWindowAndScoutHorizonTests` measures all of this from the constants themselves and fails if
    // either moves, so changing one is a deliberate act rather than a silent drift.
    //
    // WHERE THIS IS ENFORCED, and on what (#2359): [[StageNavigation]] applies it, in its `.scout` branch
    // alone, so a show more than this many days out is not offered for triage. Nothing else is bounded by
    // it: a show Dan has already kept, prepped, drafted, approved or pitched keeps its place on its stage
    // whatever its date, and an inquiry ignores the window entirely because somebody is waiting on a reply.
    //
    // It reads this constant from the one shared predicate rather than restating 90 anywhere, which is
    // what #1567 and #1575 are about. Between #2348 and #2359 nothing applied it at all: the last caller
    // was `queueOrder`, a second filter unreachable from the app since #1567 and deleted in #2348, and
    // for that gap this comment described a window that did not run. Measured on the live store on
    // 2026-08-09, 119 of the 585 untriaged shows ahead of Dan were past this edge, out to June 2027.
    static let leadTimeWindowDays = 90

    // #2365: the same window for a PAST CLIENT'S show, and the whole of Dan's rule is these two numbers.
    // His words, 2026-08-11: "90 days for anything that isn't a past client. and then the extended check
    // for past clients. we should show everything in scout from those two groups, don't hide anything."
    //
    // ELEVEN, not twelve, and the difference is load-bearing rather than cautious. The supply side reads a
    // client's calendar for the current month plus eleven ([[ClientHorizon.clientMonths]] is 12 counting
    // the current one), so it reaches the END of the twelfth month. A demand window of "today plus twelve
    // months" lands eleven days INTO a thirteenth month that is never fetched, which is the supply/demand
    // inversion the paragraph above exists to prevent, pointing the other way. Eleven months from any day
    // is inside the twelfth month, so demand can never outrun supply.
    //
    // In MONTHS rather than days because the supply it must stay inside is in months, and a day count
    // standing in for it holds only until the month lengths move (L81). Eleven months is 334 days asked on
    // 31 January and 365 asked on 31 July, and a fixed day count would have to be the smallest of those to
    // be safe, throwing away a month of a client's season for eleven months of the year.
    //
    // Measured 2026-08-11 on a clone of the live store: 124 untriaged shows sit beyond 90 days, ALL of
    // them within 11 months, the furthest being 2027-06-13. So this window reaches every far-out show
    // Overture currently holds, and `QueueWindowAndScoutHorizonTests` measures it against the fetch
    // horizons rather than restating either number.
    static let clientLeadTimeWindowMonths = 11

    // Whether a performance falls within `months` whole calendar months of `today`, in Overture's one
    // zone. An undated show is IN, on the same rule as `isWithinLeadTime`'s day arm and for the same
    // reason: nothing has measured it as far out, so dropping it would lose a real lead on a fact nobody
    // established (#861 made that call at the past edge).
    //
    // Lifted out of `PrepQueueBuilder.defaultsIncludedInPrepRun`, which #2365 deleted along with every
    // other date rule on the Prep side. The arithmetic is unchanged; it simply now serves the one surface
    // Dan said may apply a window.
    // #2524: is this show in Scout ONLY because it is a returning client's?
    //
    // Since #2365 a past client's show is offered up to 11 months ahead while everything else is held to
    // 90 days, so a date ten months out sits beside next week's with nothing saying why. Without a word on
    // the card it reads as a mistake rather than a deliberate reach, and it hides the fact that makes it
    // worth acting on: Dan has worked with these people before, which is the warmest opener the product
    // has.
    //
    // Built from the SAME two rules `StageNavigation.isWithinLeadTime` applies, in the same order, so the
    // line can never appear on a row the window did not actually reach for, nor be missing from one it
    // did (L16). Past the ordinary edge AND inside the client one is exactly "here early because of the
    // client rule".
    //
    // False for a show inside the ordinary window, which is most of them: the line exists to explain an
    // unusual row and would be noise on every card.
    // #2524: the card's own sentence, explaining the DATE and nothing else.
    //
    // It went through the cold read as "Here early: you've worked with them before", and that wording was
    // wrong twice over. The card already carries `historyFlag`'s "Worked together before" pill on a booked
    // row, so on the commonest arm it was the same sentence twice on one card, which is #843 exactly. And
    // on the arm where there is no pill it was a claim nothing measured: `isPastClientShow` is true of a
    // show that merely came off a returning client's CALENDAR, and the act performing on it that night is
    // routinely a stranger (L11).
    //
    // So it names the RULE, which is true of every arm, and leaves the relationship to the pill beside it,
    // which is the only thing that has actually established one. It quotes no arithmetic: "11 months"
    // means nothing to anybody reading a card.
    static let offeredEarlyAsAClientLine = "Here early: returning clients are shown further ahead"

    static func isOfferedEarlyAsAClient(performanceDate: String?, isPastClient: Bool, today: String) -> Bool {
        guard isPastClient else { return false }
        guard !isWithinOrdinaryLeadTime(performanceDate: performanceDate, today: today) else { return false }
        return isWithin(months: clientLeadTimeWindowMonths, performanceDate: performanceDate, today: today)
    }

    // The ordinary arm of the same rule, named so `StageNavigation.isWithinLeadTime` and the sentence
    // above are two readings of ONE predicate rather than two spellings of it (L16). An undated show is
    // IN here, which is why the sentence never appears on one: nothing has measured it as far out, so
    // there is nothing to explain.
    // #2524: does THIS surface say it? Dan's call, 2026-08-16, on reading that the first version said it
    // everywhere.
    //
    // The far reach applies to ONE list. `StageNavigation.isWithinLeadTime` is asked for `.scout` and
    // nowhere else, deliberately, because a show Dan has kept, prepped, drafted, approved or pitched is
    // work in flight and keeps its place whatever its date. So once he keeps a far-out client's show, the
    // client rule is no longer what is holding it on screen: his own decision is. A card still saying
    // "here early" there explains a decision that is not the one keeping the row, which is the quiet kind
    // of wrong that reads as correct until somebody asks what the line is for (#1547's shape).
    //
    // A function rather than a test written into the view's body, because a membership rule stated in a
    // SwiftUI body is one no test can reach (#863).
    static func saysOfferedEarlyAsAClient(_ item: QueueItem, stage: StageFocus?) -> Bool {
        stage == .scout && item.offeredEarlyAsAClient
    }

    static func isWithinOrdinaryLeadTime(performanceDate: String?, today: String) -> Bool {
        guard let days = daysUntil(performanceDate: performanceDate, today: today) else { return true }
        return days <= leadTimeWindowDays
    }

    static func isWithin(months: Int, performanceDate: String?, today: String) -> Bool {
        guard let performanceDate, let showDay = EasternDate.date(from: performanceDate) else { return true }
        guard let todayStart = EasternDate.date(from: today),
              let boundary = EasternDate.calendar.date(byAdding: .month, value: months, to: todayStart)
        else { return true }
        return showDay <= boundary
    }
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

    // #2348: `queueOrder` stood here, the second answer to "will the Queue show this show". #1567 had
    // already moved that judgment to StageNavigation, which every surface now asks, and nothing in the
    // app called this any more. Its rules live on where they are still the product's: an opened run
    // leaves triage through Prospect.hasOpened (StageNavigation `.scout`, pinned by
    // PastShowsLeaveTheScoutQueueTests), and a too-close show keeps its date position because no surface
    // reorders rows at all (#1014/#901).

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
            guard let due = inquiry.nextReachOutDate(now: now),
                  let row = inquiryRows([inquiry], now: now).first else { return nil }
            return .inquiry(inquiry: inquiry, row: row, next: due)
        }
        // Stable: equal dates keep prospects before inquiries rather than reordering run to run.
        return (prospectEntries + inquiryEntries).sorted { $0.next < $1.next }
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
                               geo: GeoRefusals = .none,
                               // #1616: how long one round of concurrent lookups takes, learned by the
                               // caller from the checks that have actually run. An argument, and defaulted
                               // to the hand-set constant, so this function stays pure and a test can price
                               // a selection without reaching Dan's real history file.
                               secondsPerRound: TimeInterval = ProbeSelection.fallbackSecondsPerRound)
    -> (ProbeSelection.Summary, [String])? {
        // The bar belongs to Scout, because the checkboxes do. Ticking dates and switching stage left it
        // pinned at the top offering to start a run against a selection Dan could neither see nor change
        // (his walk of the Debug build, 2026-07-27). The selection itself survives the trip: hiding is
        // not discarding, and losing his ticks for glancing at another stage would be the worse bug.
        guard stage == .scout else { return nil }
        guard !dates.isEmpty else { return nil }
        let groups = groupByDate(rows()).filter { dates.contains($0.id) }
        guard !groups.isEmpty else { return nil }
        let selected = groups.flatMap(\.items)
        // #2371: per ticked DATE, so a date with nothing outstanding contributes its answered shows (a
        // tick on it can only mean "check this again") while a date with work left still contributes only
        // that work, its answered shows riding along free as they always have.
        let candidateKeys = Set(groups.flatMap { probeKeysForTickedDate($0.items, now: now, today: today, geo: geo) })
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
            overrides: overrides,
            secondsPerRound: secondsPerRound)
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
    // FOUR questions in order now, and the order IS the rule: a name the gate cannot key has no
    // organisation in it at all; a correction already in force always keeps its way back; what remains is
    // offered only where a correction could actually move the verdict; and, since #1732, only where it
    // would be worth something.
    //
    // #1732: the last question is the new one. This control was on 618 of 724 rows when Dan asked for it
    // to show "only where it looks uncertain", and #1763 took it to 306 by removing the rows where a
    // correction was applied, stored and then ignored by the gate. What was left was still most of the
    // queue, on the surface he triages in, and this repo's own rule is that a repeated control earns only
    // its action.
    //
    // The bar is `OrganisationListing.shortlistMinimumRows`, the SHORTLIST's own, deliberately rather than
    // a number chosen here: the Presenters sheet surfaces the same candidates, and two definitions of
    // "worth correcting" are how the row and the sheet come to disagree (#1702, L16). An organisation
    // carrying one or two shows is one where a correction saves nothing and protects nothing.
    //
    // It is LAST for the counter-risk Dan named when he chose this: a correction already in force keeps
    // its control however few rows the organisation carries, so he can never set one on a small
    // organisation and be stranded with a verdict he cannot revisit. That is #1679's shape, and putting
    // the row-count test above the standing test would reintroduce it.
    static func correctableOrganisation(_ presenter: String?,
                                        venueBrands: ProducerGate.VenueBrands,
                                        standing: ProducerOverrideEditing.Standing,
                                        rowCount: Int) -> String? {
        guard let presenter, ProducerGate.key(presenter) != nil else { return nil }
        if standing != .none { return presenter }
        if venueBrands.isRoomName(presenter) { return nil }
        return rowCount >= OrganisationListing.shortlistMinimumRows ? presenter : nil
    }

    // #1732: how many rows each organisation carries, folded the same way the gate folds a presenter, so
    // the count this rule reads and the organisation it is about are the same thing.
    //
    // One pass over the corpus per queue build, not one per row. Deciding this per row would walk every
    // prospect for every prospect, which is the cost #1687 and #1121 record freezing the machine.
    static func organisationRowCounts(_ presenters: [String?]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for presenter in presenters {
            guard let key = ProducerGate.key(presenter) else { continue }
            counts[key, default: 0] += 1
        }
        return counts
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

    // #1716: the order of the shows WITHIN one night, stated rather than incidental.
    //
    // Best fit first was already happening, through `QueueView`'s own `@Query` (`performanceDate`
    // forward, then `fitScore` reverse), and it stays the first key here because this function now owns
    // the whole order: applying only the tiebreak would silently drop it. What never happened is
    // anything BELOW the score, and ties are the ordinary case rather than the exception. Measured
    // during #1648 Phase B across 559 untriaged shows: 280 sit at exactly 0 and 58 high-fit shows at
    // exactly 8, because every axis contributes a small integer from a short fixed set.
    //
    // Dan's call, 2026-08-18: a stated tiebreak, and the weights and axes are NOT touched. A weight
    // change would not re-score what is already stored (`fitScore` is written once by
    // `ProspectAssembler`), so the queue would hold two generations of scores side by side, which is
    // the confusion #2004 already records. This is applied at ORDER time, so it needs no backfill and
    // reaches every row already in the store.
    //
    // The keys, and why in this order. A reachable contact is what Dan can act on tonight, and it is
    // two-valued, so it goes above the many-valued keys: a criterion below one of those is consulted
    // only on an exact tie of everything above it, which would make it permanently inert while reading
    // as a criterion that ranks (L170). His originally proposed second key was the soonest date, and
    // that is exactly the trap: every row in a date group already SHARES its date, so a date key here
    // could never decide anything. Shown that, his call on 2026-08-28 was the venue instead.
    //
    // The natural key is last and is not decoration: without it two shows alike on every key above keep
    // the store's own order, which is not stable between launches, so the queue would reorder under him
    // for no change in his data at all.
    static func orderedWithinNight(_ items: [QueueItem]) -> [QueueItem] {
        items.sorted { a, b in
            if a.fitScore != b.fitScore { return a.fitScore > b.fitScore }
            let (ra, rb) = (reachabilityRank(a), reachabilityRank(b))
            if ra != rb { return ra < rb }
            let (va, vb) = (a.venue ?? "", b.venue ?? "")
            if va != vb {
                // A show with no venue sorts AFTER one with a name, rather than first as an empty
                // string otherwise would: a nameless room tells Dan less than a named one.
                if va.isEmpty { return false }
                if vb.isEmpty { return true }
                return va.localizedCaseInsensitiveCompare(vb) == .orderedAscending
            }
            return a.id < b.id
        }
    }

    // Three states, not two. An UNCHECKED show is unknown, not unreachable, and ranking it with the
    // shows a check proved have no route would state something no check ever measured (L11). Dan triages
    // on Scout before any check has run, so unchecked is the common case rather than an edge.
    private static func reachabilityRank(_ item: QueueItem) -> Int {
        switch item.reachabilityResult {
        case .some(.noEmailFound): return 2
        case .none: return 1
        case .some: return 0   // every other verdict is a way in: an address, a form, a social profile
        }
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
            // #1716: applied HERE, where the groups are built, because every queue surface renders
            // through this one function. Applied anywhere else it would reach some screens and not
            // others, and the order Dan reads is the only thing this issue is about.
            let bucket = orderedWithinNight(buckets[key] ?? [])
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
                hasUnhandledReply: inquiry.hasUnhandledReply,
                answeredReplyLine: AnsweredReplyNote.line(for: inquiry, now: now),
                bounced: inquiry.bounced,
                bookingSuggested: inquiry.bookingSuggested,
                followUpNudgeDue: inquiry.followUpNudgeDue(now: now),
                shouldSuggestClosing: inquiry.shouldSuggestClosing(now: now),
                threadIdDegraded: inquiry.threadIdDegraded,
                threadingDegraded: inquiry.threadingDegraded,
                sendError: inquiry.sendError,
                conversationAttachedAt: inquiry.conversationAttachedAt
            )
        }
    }

    // #2348: `combinedQueueRows` stood here, one list holding both scouted shows and inquiries. It ran
    // the shows through the retired second filter (`toSendQueue`) and nothing called it: the queue is
    // stage scoped, so a stage renders its shows and its inquiries as two blocks (QueueRenderPass, then
    // QueueView). The rule it was written to protect is unchanged and now holds by construction, since no
    // date window is applied to either kind: an inquiry is live because someone awaits Dan's reply,
    // whatever the event date, so a past, far-future or unknown date must never remove it. That is pinned
    // against the live path in InquiryQueueTests.

    // Groups QueueRows by date, mirroring groupByDate's shape (a bucket per date, the undated one naming
    // itself). Buckets appear in the order the rows arrive, so a caller wanting date order hands over
    // rows already in it.
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

    // #2348: `toSendQueue` stood here, `queueOrder` with the already-pitched shows dropped. Its rule (the
    // "To send" and "Reached out" pipelines never show the same show twice) is StageNavigation.queueKeys',
    // which excludes the reached-out keys for the same reason, and nothing called this one.

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

    // #1699: the one string the card shows beside the date, or nil to say nothing at all.
    //
    // Nil is the majority answer and renders as NOTHING: no placeholder, no empty separator, no invented
    // midnight. A show whose source never published a time reads exactly as it does today, so the time is
    // additive information and never a claim, and an untimed show never looks worse at triage than a
    // timed one merely because of which feed it came from (Dan's framing on #1699).
    //
    // A specific time beats the vary flag. The scout never stores both (the fold clears the times when it
    // sets the flag), so this only arbitrates a state that means something upstream already went wrong,
    // and in that case the concrete fact is worth more than the vaguer sentence.
    static func cardStartTime(startTimes: [String], timesVary: Bool) -> String? {
        if let label = ClockTime.listLabel(startTimes) { return label }
        return timesVary ? runTimesVaryLabel : nil
    }

    // #1699: the schedule behind "Times vary", one line per night, or nil when there is nothing to show.
    //
    // Dan's call (2026-08-02) once the real numbers landed: "Times vary" is the MAJORITY of timed cards
    // (16 of 30 measured on his two live ticketing venues), not the rare case it was offered as, because
    // almost any run longer than a few nights carries a weekend matinee. So the card keeps the short
    // honest summary and the actual schedule hangs off a hover, instead of overstating one night or
    // sending him to the venue's site.
    //
    // Each entry is SELF-DESCRIBING ("yyyy-MM-dd HH:mm") rather than a second array that has to stay
    // lined up with `runNights`. Two parallel lists drift the moment one is written without the other,
    // and the drift stays silent (L15/L41); this shape cannot misalign because every time carries its
    // own night.
    static func nightTimesTooltip(_ nightStartTimes: [String]) -> String? {
        let byNight = nightTimes(nightStartTimes)
        let cal = easternCalendar
        // ISO day strings sort chronologically as text, so this is date order: a hover is read as a
        // schedule, not as whatever order the feed happened to list.
        let lines = byNight.keys.sorted().compactMap { iso -> String? in
            guard let d = day(iso), let times = byNight[iso],
                  // The SAME phrasing the card uses for a double bill, so the hover speaks in one voice
                  // rather than inventing a second format for the same fact.
                  let joined = ClockTime.listLabel(times.sorted()) else { return nil }
            return "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d)) at \(joined)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // #1699, Dan's call from the rendered options (2026-08-02): a run whose nights start at DIFFERENT
    // times says so, rather than showing nothing. Drawn beside the alternatives, silence made a run with
    // a matinee look identical to a show whose source published no time, which is a different fact.
    static let runTimesVaryLabel = "Times vary"

    // #1699: the stored "yyyy-MM-dd HH:mm" entries read back as each night's own raw "HH:mm" times.
    // A malformed entry costs only ITSELF; the real nights still reach Dan.
    //
    // One parser, because two things read these entries and must agree on which are real: the hover that
    // SHOWS the whole schedule, and the clash check that pulls ONE night out of it to compare curtains.
    // A night the hover displayed but the clash check could not read would be a night Dan was shown and
    // Overture silently treated as unknown.
    static func nightTimes(_ nightStartTimes: [String]) -> [String: [String]] {
        var byNight: [String: [String]] = [:]
        for entry in nightStartTimes {
            let parts = entry.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, day(String(parts[0])) != nil,
                  ClockTime.minutesOfDay(String(parts[1])) != nil else { continue }
            byNight[String(parts[0]), default: []].append(String(parts[1]))
        }
        return byNight
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
        // #2261: a request to re-check releases the show, and it is asked FIRST so it releases BOTH ways a
        // show can be frozen. The inherited case is the one that would otherwise be missed: a show can be
        // held not by its own check but by one paid for on a sibling of the same organisation, and a
        // release that only overrode the own-answer branch would refuse on exactly those rows while the
        // button sat there offering.
        //
        // What a re-check does NOT do is touch the organisation's ledger answer. It cannot need to: the
        // fan-out skips any show carrying its own answer (`OrgAnswerLedger.inherited`, `!hasOwnAnswer`), so
        // the re-checked show is immune to its own organisation's older answer the moment its new one
        // lands. Rewriting the org answer from one re-check would instead reach siblings Dan never
        // selected. (The ledger holds 0 rows on the live store as of 2026-08-07, so this decides the rule
        // before the situation exists rather than after.)
        if i.reachabilityRecheckRequestedAt != nil { return false }
        if i.inheritedReachability != nil { return true }
        return i.reachabilityProbedAt != nil
            && !Reachability.probeIsStale(probedAt: i.reachabilityProbedAt, now: now)
    }

    // #1805: the shows a check was given and never reached, gathered so the shortfall report can offer to
    // finish them instead of naming a number and stopping.
    //
    // No new bookkeeping: the settle already stamps a show it never reached (#1724), and #1594 is
    // deliberate that such a show is NOT given a probe date, so it is already a candidate. The only thing
    // missing was collecting them, which is why the report could name the count while Dan reconstructed
    // the set by hand.
    //
    // An ANSWER wins over the mark. A row can carry both if one run missed it and a later one answered it,
    // and paying for a lookup that already succeeded is the one thing this must never do. The candidacy
    // rule holds too, so a show past deciding is not offered whatever any run did to it, and the mark ages
    // on the same clock as every other reachability fact rather than offering to spend money forever.
    static func keysMissedByACheck(_ items: [QueueItem], now: Date = Date(),
                                   today: String = QueueModel.easternToday(),
                                   geo: GeoRefusals = .none) -> [String] {
        items.filter { i in
            probeIsWorthOffering(i, today: today, geo: geo)
                // #2621: one definition of "a check missed this row", shared with the per-card offer.
                && Reachability.wasMissedByACheck(probedAt: i.reachabilityProbedAt,
                                                  unansweredAt: i.reachabilityUnansweredAt, now: now)
        }.map(\.id)
    }

    // #2268: the shows a date-level re-check marks. Dan asked for it directly: the shows needing a re-run
    // arrive in batches (one producing company re-derived across a run is roughly 22 rows), so a
    // per-card-only route serves the bulk case worst.
    //
    // It MARKS rather than runs, and that is the whole design. Everything after the mark is the ordinary
    // selection: the date's tick box comes back, the bar states the count and the cost from the same
    // candidate list as always, and the confirm is the one that already exists. A date-level action that
    // started its own run would be a second way to spend money with its own sentence about what it costs.
    //
    // Two exclusions, both load-bearing. A show past the keep-or-dismiss moment is never marked, because a
    // date-level action must not quietly widen what a check pays for beyond what the per-card one would
    // (L16, the count Dan approves is the count that runs). And a show with no answer is left alone: it is
    // already a candidate and already counted, so marking it would make the action look bigger than it is.
    static func keysToReofferForRecheck(_ items: [QueueItem], now: Date = Date(),
                                        today: String = QueueModel.easternToday(),
                                        geo: GeoRefusals = .none) -> [String] {
        items.filter { probeIsWorthOffering($0, today: today, geo: geo)
                        && hasFreshReachabilityAnswer($0, now: now) }.map(\.id)
    }

    // #2371: what ticking THIS date puts into a run, and, because it is the same question, whether the
    // date offers a tick box at all. Dan, 2026-08-09: "now that we have the ability to check reachability
    // again, we shouldn't hide the checkbox on nights that have already been checked."
    //
    // A date with something outstanding contributes exactly that (unchanged, and in particular a PARTLY
    // checked date still rides its answered shows along for free, which is #1597's deliberate pricing).
    // A date with nothing outstanding contributes its answered-but-still-open shows, because on such a
    // date that is the only thing a tick could possibly mean, and a tick that adds nothing is a control
    // that moves neither the selection bar's count nor the confirm's cost.
    //
    // Nothing is written to the store either way. That is the whole reason the tick, rather than the
    // "Check again" link it replaces, is the route: ticking is something Dan undoes by ticking again, and
    // the link marked every answered show on the date before the selection was even priced, so changing
    // his mind left the requests standing (#2375).
    //
    // One function for both questions on purpose: the tick box appears exactly where it has something to
    // contribute, so its presence can never promise rows the run does not get (L16).
    static func probeKeysForTickedDate(_ items: [QueueItem], now: Date = Date(),
                                       today: String = QueueModel.easternToday(),
                                       geo: GeoRefusals = .none) -> [String] {
        let outstanding = reachabilityProbeCandidateKeys(items, now: now, today: today, geo: geo)
        guard outstanding.isEmpty else { return outstanding }
        return keysToReofferForRecheck(items, now: now, today: today, geo: geo)
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
        if i.showOutcome == .hadPaidWork { return true }  // dismissed BECAUSE booked elsewhere: still committed
        if i.isLost { return false }                          // #1248: a pitch marked lost frees the date, even if it was sent
        if i.status == .dismissed { return false }            // any other dismissed show is dead; ignore it
        if i.sentAt != nil { return true }                    // a live pitch is already out
        return (i.status == .drafted || i.status == .approved) && i.hasDraft  // an in-progress draft
    }

    // #1699 part 3: the curtain time(s) this row plays on the night the clash check compares, or empty
    // when nothing published one for that night.
    //
    // A RUN is the case worth spelling out. Its card states a single time only when every night agrees
    // (RunStartTimes.across), so a run with a weekend matinee carries no card time at all, and reading
    // one off it would say nothing about the night in question. The per-night schedule kept for the
    // hover DOES name that night, so that is what is read: the most specific true answer available.
    // When it names nothing for this night, the answer is nothing, never the run's other nights.
    static func selfBookingStartTimes(_ i: QueueItem, on date: String) -> [String] {
        if let night = nightTimes(i.nightStartTimes)[date] { return night }
        // A run whose nights disagree may not lend one night's time to another (the card refuses to
        // state one for exactly this reason), so a run that said nothing about THIS night says nothing.
        guard !i.startTimesVary else { return [] }
        return i.performanceStartTimes
    }

    // #3323: every night this row plays, for the self-booking comparison.
    //
    // `runNights` is already the KEPT list (`RunNightDrop.dropNight` rewrites it, and a scout rebuilds it
    // through `DroppedNight.keeping`), so a night Dan dropped is not compared and cannot raise a warning
    // about a night he is no longer pitching.
    //
    // An EMPTY list falls back to `performanceDate` ALONE, never to a span walk. Measured on the live
    // store 2026-09-01, 22 rows carry a span with no recorded nights, 11 of them live. For those the
    // nights genuinely are not known, and walking `performanceDate` through `runEndDate` would invent
    // clashes on the dark nights of a weekly series, which is the one direction of this change that
    // manufactures a warning rather than finding one. `BlockedCalendar.conflict` falls back the OTHER way
    // for its own stated reason, and the asymmetry is deliberate: there, clearing a real clash on no
    // evidence is what loses safety; here, inventing one is.
    static func selfBookingNights(_ i: QueueItem) -> [String] {
        let recorded = Set(i.runNights).sorted()
        if !recorded.isEmpty { return recorded }
        return i.performanceDate.map { [$0] } ?? []
    }

    static func selfBookingShow(_ i: QueueItem) -> SelfBookingConflict.Show {
        let nights = selfBookingNights(i)
        var times: [String: [String]] = [:]
        for night in nights {
            let published = selfBookingStartTimes(i, on: night)
            if !published.isEmpty { times[night] = published }
        }
        return SelfBookingConflict.Show(key: i.id, nights: nights,
                                        isCommitment: selfBookingIsCommitment(i),
                                        engagementKey: i.groupName, name: i.groupName,
                                        timesByNight: times)
    }

    // #3323: the whole comparison set, indexed by night, built ONCE for a render pass. Everything below
    // takes it rather than an item array, so a per-row call cannot rebuild it (the #1772 defect, which
    // this change would otherwise multiply by a run's length).
    static func selfBookingIndex(_ items: [QueueItem]) -> SelfBookingConflict.NightIndex {
        SelfBookingConflict.NightIndex(items.map(selfBookingShow))
    }

    // The OTHER committed shows clashing with `item` on any night it plays, across the WHOLE queue (never
    // scoped to one stage, so the warning never vanishes when a show changes stage, #1246). Empty = every
    // night is clear.
    static func selfBookingConflicts(for item: QueueItem,
                                     in index: SelfBookingConflict.NightIndex) -> [SelfBookingConflict.Overlap] {
        SelfBookingConflict.conflicts(for: selfBookingShow(item), in: index)
    }

    static func hasSelfBookingConflict(for item: QueueItem,
                                       in index: SelfBookingConflict.NightIndex) -> Bool {
        !selfBookingConflicts(for: item, in: index).isEmpty
    }

    // #1699 part 3: the plain, non-warning note for a night that holds another committed show the clock
    // proves Dan can work alongside this one. Nil when there is none, and nil whenever the row ALSO
    // holds a real clash: that night needs the warning, and stacking a reassuring line beside an
    // actionable one would bury the thing he has to decide about.
    static func selfBookingWorkableNote(for item: QueueItem,
                                        in index: SelfBookingConflict.NightIndex) -> String? {
        guard !hasSelfBookingConflict(for: item, in: index) else { return nil }
        let target = selfBookingShow(item)
        return SelfBookingCopy.workableRowMarker(target: target,
                                                 others: SelfBookingConflict.workable(for: target,
                                                                                      in: index))
    }

    // The names of the OTHER committed shows on this row's nights, so a warning can name them, each named
    // ONCE however many nights of the run it collides on. NOTE (#901/#863): this must never be wired into
    // needsPrep or a stage-pill count; it is confirm-to-proceed, not a hard gate, so the counts stay honest.
    static func selfBookingConflictNames(for item: QueueItem,
                                         in index: SelfBookingConflict.NightIndex) -> [String] {
        var seen = Set<String>()
        return selfBookingConflicts(for: item, in: index).compactMap { overlap in
            seen.insert(overlap.other.key).inserted ? overlap.other.name : nil
        }
    }

    // #3323: the EARLIEST night any of those clashes falls on, so the copy can name it. Nil when the row
    // is clear, which is what keeps a caller from rendering a night for a show that has no clash.
    static func selfBookingClashNight(for item: QueueItem,
                                      in index: SelfBookingConflict.NightIndex) -> String? {
        selfBookingConflicts(for: item, in: index).first?.night
    }

    // #3323: the row marker, assembled here so the view does not have to hold the night and the names
    // together itself (the #863 rule: a sentence built in a view is invisible to the copy inventory).
    static func selfBookingRowMarker(for item: QueueItem,
                                     in index: SelfBookingConflict.NightIndex) -> String? {
        SelfBookingCopy.rowMarker(selfBookingConflictNames(for: item, in: index),
                                  clashNight: selfBookingClashNight(for: item, in: index),
                                  performanceDate: item.performanceDate)
    }

    // #1244: the self-booking warning shown at the send-confirm moment, as one shared helper so BOTH send
    // paths (the main queue's requestSend and Archive's) surface a clash identically and can never
    // drift on when or how it is named. nil when every night is clear. The comparison set is the WHOLE
    // queue, so a clash with a show in any stage still counts.
    static func sendSelfBookingWarning(for item: QueueItem,
                                       in index: SelfBookingConflict.NightIndex) -> String? {
        SelfBookingCopy.confirmWarning(selfBookingConflictNames(for: item, in: index),
                                       clashNight: selfBookingClashNight(for: item, in: index),
                                       performanceDate: item.performanceDate)
    }

    // The queue-wide date-header note: shown when any row in this date group faces a self-booking conflict
    // against the WHOLE queue, so it stays visible even after the other show has moved to another stage.
    // #3323: the note also says WHERE. A run in the group clashing on a later night makes "on this date"
    // a claim about the header it sits under that the check never measured, so the group is asked whether
    // every clash it holds really falls on the header's own date.
    static func selfBookingNote(_ group: [QueueItem], on date: String?,
                                in index: SelfBookingConflict.NightIndex) -> String? {
        let clashing = group.filter { hasSelfBookingConflict(for: $0, in: index) }
        guard !clashing.isEmpty else { return nil }
        guard let date else { return SelfBookingCopy.dateHeaderNote(allOnThisDate: false) }
        let onThisDate = SelfBookingConflict.everyClashIsOn(date, for: clashing.map(selfBookingShow),
                                                           in: index)
        return SelfBookingCopy.dateHeaderNote(allOnThisDate: onThisDate)
    }

    // #1219: which of the shows ABOUT TO BE PREPPED (by key) sit on a night that already holds a committed
    // OTHER show, and the names of those clashes, so a prep-launch confirm can name them. Shared by BOTH
    // prep entry points, the "Prep these N" sheet AND the per-row Re-prep (red-team FLAW 1: Re-prep
    // launches a run directly, so gating only the sheet leaves a hole). Empty = no clash, run freely.
    static func selfBookingPrepClashes(forKeys keys: Set<String>, among items: [QueueItem]) -> [SelfBookingPrepClash] {
        let index = selfBookingIndex(items)
        return items
            .filter { keys.contains($0.id) }
            .compactMap { selfBookingClash(for: $0, in: index) }
    }

    // The single-row clash (this show + the committed OTHER shows on its nights), or nil when every night
    // is clear. Used by the Approve and per-row Re-prep confirms, where one specific row is being committed.
    static func selfBookingClash(for item: QueueItem,
                                 in index: SelfBookingConflict.NightIndex) -> SelfBookingPrepClash? {
        let names = selfBookingConflictNames(for: item, in: index)
        guard !names.isEmpty else { return nil }
        return SelfBookingPrepClash(groupName: item.groupName, conflictNames: names,
                                    clashNight: selfBookingClashNight(for: item, in: index),
                                    performanceDate: item.performanceDate)
    }

    // #3366: which of the shows ABOUT TO BE PREPPED sit on a night the CALENDAR has spoken for (a booked
    // shoot, or a day Dan blocked), carrying the sentence the card already shows for that clash.
    //
    // The self-booking check above compares two Overture prospects to each other; this one reads the
    // conflict the scout wrote from Downbeat and Dan's days off. Both reach the same confirm, because both
    // are the same question about the same night.
    static func calendarClashesForPrep(forKeys keys: Set<String>,
                                       among items: [QueueItem]) -> [PrepCalendarClash] {
        items
            .filter { keys.contains($0.id) && $0.hasUnclearedConflict }
            .compactMap { item in
                // No note means nothing to say. A clash with no readable reason would put an empty line in
                // front of Dan under a title asking him to confirm it, which is worse than saying nothing.
                item.conflictNote.map { PrepCalendarClash(groupName: item.groupName, note: $0) }
            }
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
        // #2612: a social profile's host is the same for every act ("instagram.com"), so the host alone
        // would tell Dan nothing about WHO he would be writing to, which is the whole job this label was
        // given in #1626. The handle is the identifying half, so it comes too.
        guard Reachability.isSocialOnly(url.absoluteString) else { return host }
        let handle = url.path.split(separator: "/").first.map(String.init)
        return handle.map { "\(host)/\($0)" } ?? host
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
                      // #2392: the addresses Dan has struck, read once by the caller and handed in.
                      // Defaulted empty so every call site that only wants rows is unaffected.
                      refusals: ContactRefusal.Ledger = .none,
                      // #2524: which watched calendars are a returning client's, so each row can carry
                      // whether the client reach is what is keeping it in Scout. Defaulted to `.none`,
                      // which answers false for every row: right for Archive, where a line about a show
                      // being offered EARLY has nothing to explain, and right for a test that is not
                      // asking about the window.
                      clients: ClientWindow = .none,
                      now: Date = Date(),
                      // Overture's day. Optional and last for the same reason `StageContext`'s is: the
                      // ordinary spelling derives it, and pinning one is what a test goes out of its way
                      // to do.
                      // #3014: the shows a live run is already on, which take no INHERITED org answer
                      // while it works (the fan-out would otherwise change a contact under a draft).
                      // Defaulted to empty, unlike `OrgAnswerLedger.inherited`'s own parameter, and the
                      // difference is deliberate: there the default would hide the block from the one
                      // caller that matters, while here most callers (Archive, and every test not asking
                      // about a live run) genuinely have no run state and "nothing held" is the right and
                      // only answer for them. The production caller is asserted to pass a real value.
                      heldKeys: Set<String> = [],
                      today: String? = nil) -> [QueueItem] {
        let day = today ?? EasternDate.today(now)
        let linked = EngagementLink.group(prospects.map(EngagementLink.Row.init))
        let inherited = inheritedAnswers(answers, corpus: corpus ?? prospects,
                                         overrides: overrides, refusals: refusals,
                                         heldKeys: heldKeys, now: now)
        // #1687: built ONCE here from the same whole-store corpus the gate above judges against, never per
        // row. Deciding whether a presenter is really its building's brand walks every presenter in the
        // store against every venue spelling in it (roughly 400 by 114 on Dan's), which is a cost a card
        // must not pay on every render. The corpus is deliberately the unfiltered store rather than the
        // caller's rows, so a dismissal cannot quietly change which names draw.
        let venueBrands = ProducerGate.VenueBrands(
            shows: (corpus ?? prospects).map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
            overrides: overrides)
        // #1732: how many rows each organisation carries, over the SAME unfiltered corpus venueBrands
        // judges against, so a dismissal cannot quietly take an organisation under the bar and remove the
        // control from the rows still showing. Built once here for the same reason as venueBrands above.
        let rowCounts = organisationRowCounts((corpus ?? prospects).map(\.presenter))
        func organisationRowCount(_ presenter: String?) -> Int {
            guard let key = ProducerGate.key(presenter) else { return 0 }
            return rowCounts[key] ?? 0
        }
        // #1825: built ONCE, for the same reason as venueBrands above. Every row resolves its own sources
        // through this rather than walking the watchlist per card.
        // #2816: the table lives on QueueModel now, because the reached-out and follow-up rows resolve
        // their own links against it too, and two builds of one table are two things to drift.
        let calendarBySourceId = sourceCalendarIndex(sources)
        return prospects.map {
            var item = QueueItem($0)
            // #2524: inside the sweep that was already happening. Asked as its own pass over the store it
            // was a ninth whole-store sweep per render, which `QueueRenderPassCostTests` refused.
            item.offeredEarlyAsAClient = isOfferedEarlyAsAClient(
                performanceDate: $0.performanceDate, isPastClient: clients.isPastClientShow($0), today: day)
            item.sourceCalendarURLs = $0.sourceIds.compactMap { calendarBySourceId[$0] }
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
            // #1732: and only where the correction would be worth something. The counts are worked out
            // once for the whole build, above, never per row.
            item.correctableOrganisation = correctableOrganisation(
                $0.presenter, venueBrands: venueBrands, standing: item.producerStanding,
                rowCount: organisationRowCount($0.presenter))
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
                                         refusals: ContactRefusal.Ledger,
                                         heldKeys: Set<String>,
                                         now: Date) -> [String: OrgAnswerLedger.Inherited] {
        guard !answers.isEmpty else { return [:] }
        let flat = answers.compactMap { row -> OrgAnswerLedger.Answer? in
            guard let result = row.result else { return nil }
            return OrgAnswerLedger.Answer(orgKey: row.orgKey, result: result, probedAt: row.probedAt,
                                          presenterName: row.presenterName, emails: row.foundEmails)
        }
        // #2392: struck addresses come out HERE, before the ledger decides anything, so the badge and the
        // addresses under it are answering from one list. An organisation whose every address Dan struck
        // is left with none, and `OrgAnswerLedger.inherited` already refuses to inherit a positive with
        // nothing to show, so the card stops claiming a way in it cannot offer (L16).
        let usable = refusals.allowedAnswers(flat)
        let shows = corpus.map {
            OrgAnswerLedger.Show(key: $0.naturalKey, presenter: $0.presenter, venue: $0.venue,
                                 hasOwnAnswer: $0.reachabilityProbedAt != nil)
        }
        return OrgAnswerLedger.inherited(from: usable, shows: shows, now: now, heldKeys: heldKeys,
                                         overrides: overrides)
    }

    // #939: distinct from relatedRunNote above (same venue, a separate run): this production also plays
    // one or more OTHER venues nearby, so two queue rows Dan might otherwise treat as separate leads are
    // actually one touring engagement. Each case is one complete sentence (not built by joining pieces),
    // so the copy-inventory (docs/copy-inventory.md) shows it as the one whole line Dan actually reads.
    // #3013: why this show was not in the run Dan just started. A card note rather than only a launch
    // message, because the launch message clears while the situation does not, and afterwards a skipped
    // show is indistinguishable from one he never picked (L126). It stops appearing the moment a run
    // carries the show, or the run holding it ends, both of which clear the stamp behind it.
    static func heldBackNote(_ item: QueueItem) -> String? {
        guard let slot = item.heldBackFrom else { return nil }
        switch slot {
        case RunSlot.prep.rawValue:
            return "Left out of your last prep run: a contact check was already working on this one."
        case RunSlot.check.rawValue:
            return "Left out of your last contact check: a prep run was already working on this one."
        default:
            // An unrecognised slot is a store written by a newer build. Say the true half rather than
            // guessing which run it was, and never drop the note entirely: the show really was skipped.
            return "Left out of your last run: another run was already working on this one."
        }
    }

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

// #1666: the card carries every fact the Prep-eligibility rule reads, so it is handed to that rule
// whole rather than reciting its arguments. A new fact added to `needsPrep` breaks this conformance
// until the card carries it too, which is the point: the card cannot silently answer an older rule.
extension QueueItem: PrepEligibilityFacts {}

extension QueueItem {
    init(_ p: Prospect) {
        self.init(p, sendGroups: SendGroup.CardGroups(of: p))
    }

    // #2046: the send groups are worked out once, by the caller above, and handed in. Three of the fields
    // below are the same question ("who does this show's email reach") asked three ways, and each used to
    // ask it again from scratch: every ask filters the recipients through the sendable predicate, which
    // runs the draft lint over each contact's whole letter, for a card being built to be scrolled past.
    init(_ p: Prospect, sendGroups: SendGroup.CardGroups) {
        // #1700: the closure-bearing answers are worked out HERE, one small expression each, rather than
        // inside the memberwise call below.
        //
        // That call is one expression with about sixty arguments, and adding a single field to it in
        // #1680 tipped it into "the compiler is unable to type-check this expression in reasonable time",
        // which names no field and suggests no cause, so it reads as a broken toolchain rather than as one
        // oversized expression. The workaround then was to assign the new field AFTER the init, which left
        // the file with two conventions for the same job and only a comment explaining why.
        //
        // These eight are the expensive ones: each is a closure whose types the checker has to infer, and
        // inference inside a sixty-argument call is where the cost compounds. Pulled out, each is checked
        // on its own, and the three fields that had been exiled below are back where they belong.
        let voiceLearningCandidate = p.sentAt != nil && p.originalDraftBody != nil
        let nextRecipientIds = sendGroups.pending.map(\.id)
        let weakContactHoldReason = p.recipients.compactMap(\.holdReason).first
        let formPitch = FormPitch.state(of: p)
        let draftGreetedContactName = p.recipients.first { $0.sendState == .pending && $0.greetingNamesSomeoneElse }?.name
        let conflictBlockedDate = p.conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date
        let draftGreetedName = p.recipients
            .first { $0.sendState == .pending && $0.greetingNamesSomeoneElse }
            .flatMap { DraftGreeting.greetedName($0.effectiveBody) }
        let draftLintBlockers = DraftIssue.orderedBlockers(
            Set(p.recipients.filter { $0.sendState == .pending }.flatMap(\.draftLintBlockers)))
        let contacts = p.recipients
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
            .map(RecipientSnapshot.init)
        let offersSendModeChoice = p.recipients.filter { $0.email?.isEmpty == false }.count > 1
        let hasWeakContactEmail = p.recipients.contains(where: \.isHeldByAGuard)
        let hasAnyEmailContact = p.recipients.contains { $0.email?.isEmpty == false }
        let draftMissingGreeting = p.recipients.contains { $0.sendState == .pending && $0.draftIsMissingGreeting }
        let draftGreetingMisaddressed = p.recipients.contains { $0.sendState == .pending && $0.greetingMisaddressed }
        let draftGreetingNamesSomeoneElse = p.recipients.contains { $0.sendState == .pending && $0.greetingNamesSomeoneElse }
        let greetingOverridden = !p.recipients.contains { $0.sendState == .pending && $0.isBlockedByGreeting }
        let draftLintBlocked = p.recipients.contains { $0.sendState == .pending && $0.isBlockedByDraftLint }

        self.init(
            id: p.naturalKey,
            groupName: p.groupName,
            discipline: p.discipline,
            venue: p.venue,
            performanceDate: p.performanceDate,
            sourceListingURL: p.sourceListingURL,
            presenter: p.presenter,
            reachabilityProbedAt: p.reachabilityProbedAt,
            reachabilityRecheckRequestedAt: p.reachabilityRecheckRequestedAt,
            // #2664: what the show HOLDS, not what a check once concluded, so a contact Dan deletes by
            // hand takes the badge's claim with it instead of leaving it promising a route that is gone.
            reachabilityResult: p.reachabilityResultAsHeld,
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
            // #1700: back inside the call, in declaration order, now that seventeen computed
            // arguments are hoisted above it. They were assigned AFTER the init from #1680 and #2395
            // onwards because adding any of them tipped the call into "unable to type-check in
            // reasonable time"; the file carried two conventions for one job and a comment explaining
            // why. One convention now.
            showOutcome: p.showOutcome,
            draftSubject: p.draftSubject,
            draftBody: p.draftBody,
            draftEditedByDan: p.draftEditedByDan,
            draftWrittenByDan: p.draftWrittenByDan,
            draftModel: p.draftModel,
            outcome: p.outcome,
            performanceStatus: p.performanceStatus,
            sentAt: p.sentAt,
            // #244/#1773: a sent show with the AI's original wording still recorded is something the
            // voice loop can learn from. Resolved once here, so the card is handed the answer instead
            // of searching the whole store for its own model to work it out.
            voiceLearningCandidate: voiceLearningCandidate,
            excludedFromVoiceLearning: p.excludedFromVoiceLearning,
            hasPendingRecipient: sendGroups.hasPending,
            nextRecipientIds: nextRecipientIds,
            sendsTogether: p.sendsTogether,
            offersSendModeChoice: offersSendModeChoice,
            // #1324: a real address held by a guard, so the badge can say so rather than "No email found"
            // when that is all a check found. #1798: the same shared definition the stored verdict uses,
            // because these were two copies of one rule and both were missing the duplicate guard.
            hasWeakContactEmail: hasWeakContactEmail,
            // #1798: WHY it is held, so the sentence beside it is true of this row.
            weakContactHoldReason: weakContactHoldReason,
            runSourceURLs: p.runSourceURLs,
            formPitch: formPitch,
            // #1311: any recipient with a real address at all, so the Send surface can tell "no email to
            // send to" apart from "an email exists but is held for a review".
            hasAnyEmailContact: hasAnyEmailContact,
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
            // #2545: judged over the recipients that would actually receive this draft, the same way the
            // lint below is, so what the card says holds the send is what `isSendablePending` holds it on.
            draftMissingGreeting: draftMissingGreeting,
            draftGreetingMisaddressed: draftGreetingMisaddressed,
            // #2579: the first pending recipient the greeting misnames, and the pair of names from THAT
            // recipient, so the card cannot show one contact's name beside another's greeting.
            draftGreetingNamesSomeoneElse: draftGreetingNamesSomeoneElse,
            draftGreetedName: draftGreetedName,
            draftGreetedContactName: draftGreetedContactName,
            greetingAudienceSize: p.greetingAudienceSize,
            // "nothing is held any more", NOT "somebody has an override", and the difference is the whole
            // safety of it: this flag both tones the warning down and REMOVES the Override button, so
            // reading it the second way would take the way out away while the send is genuinely still
            // blocked. One contact overridden beside one added later and still held is reachable in
            // ordinary use, and it is the dead-end shape #2052 and #2012 were filed for. Same shape as
            // `draftLintBlocked` above: the finding stays reported, only the BLOCK clears.
            greetingOverridden: greetingOverridden,
            draftLintBlockers: draftLintBlockers,
            draftLintBlocked: draftLintBlocked,
            outcomeSourceRaw: p.outcomeSourceRaw,
            hasUnclearedConflict: p.hasUnclearedConflict,
            conflictNote: p.conflictNote,
            conflictBlockedDate: conflictBlockedDate,
            runEndDate: p.runEndDate,
            runNights: p.runNights,                           // #3323
            performanceStartTimes: p.performanceStartTimes,   // #1699
            startTimesVary: p.startTimesVary,                 // #1699
            nightStartTimes: p.nightStartTimes,               // #1699
            partOfRelatedRun: p.partOfRelatedRun,
            heldBackFrom: p.heldBackAt == nil ? nil : p.heldBackBySlot,
            disappearedFromFeed: p.disappearedFromFeed,
            contacts: contacts,
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
                  isHeldFromSending: r.isBlockedAwaitingReview,
                  replyDraftSubject: r.replyDraftSubject, replyDraftBody: r.replyDraftBody,
                  replyDraftRequestedAt: r.replyDraftRequestedAt,
                  replyCopiedAt: r.replyCopiedAt,
                  // #2966: the shared rule's answer, so the card and the reply panel cannot disagree about
                  // whether a run is still going.
                  awaitedReplyDraftRequestedAt: r.awaitedReplyDraftRequestedAt,
                  hasUnhandledReply: r.hasUnhandledReply,
                  replyIsAnswered: r.replyIsAnswered,
                  intentHint: r.intentHint,
                  replyDraftEditedByDan: r.replyDraftEditedByDan,
                  replyDraftWrittenByDan: r.replyDraftWrittenByDan,
                  replyAudience: SendGroup.replyAudience(of: r),
                  replyDraftModel: r.replyDraftModel,
                  overrideBody: r.overrideBody,
                  conversationRemindedAt: r.conversationRemindedAt,
            outreachStoodDownAt: r.outreachStoodDownAt,
                  contactConfidence: r.contactConfidence,
                  contactTier: r.contactTier,
                  contactMethod: r.contactMethod,
                  contactFormURL: r.contactFormURL,
                  nameMatchOnly: r.nameMatchOnly,
                  contactSourceURL: r.contactSourceURL,
                  delayNoticeAt: r.delayNoticeAt,
                  looksLikeVenue: r.looksLikeVenue,
                  looksLikeVenueDismissed: r.looksLikeVenueDismissed,
                  looksLikePressContact: r.looksLikePressContact,
                  looksLikePressContactDismissed: r.looksLikePressContactDismissed,
                  looksLikeDuplicateContact: r.looksLikeDuplicateContact,
                  looksLikeDuplicateContactDismissed: r.looksLikeDuplicateContactDismissed,
                  heldDownToUnverified: r.heldDownToUnverified,
                  heldDownToUnverifiedDismissed: r.heldDownToUnverifiedDismissed,
                  heldDownReason: r.heldDownReason,
                  looksLikeAnotherPersons: r.looksLikeAnotherPersons,
                  looksLikeAnotherPersonsDismissed: r.looksLikeAnotherPersonsDismissed)
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

// #1742: the genre control's own words and glyph, named here rather than inline so the sentence a
// person HEARS appears in the copy inventory beside the ones they read, and so the label cannot quietly
// become a raw stored value ("other" is a database word, "Performance" is Dan's).
enum GenreControlCopy {
    // Sits after the genre at rest, never on hover alone: Dan met this row in a screenshot, and a cue
    // that needs a mouse does not exist in one. A chevron rather than the title's pencil because what
    // opens is a one-picker popover, and the glyph should promise the thing that actually happens.
    static let icon = "chevron.down"
    static let help = "Set this show's genre"

    static func accessibilityLabel(for discipline: String) -> String {
        // #1657: the two states are different sentences, because "Genre: No genre read. Change it."
        // announces a genre and then says it is not one. An unread genre has nothing to change, so what
        // this control offers there is to SET it.
        guard let read = Discipline(rawValue: discipline), read != .other else {
            return "\(Discipline.other.label). Set it."
        }
        return "Genre: \(read.label). Change it."
    }
}
