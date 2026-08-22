import Foundation

// #1145 Layer 1: a free, always-on reachability heuristic read on SCOUT, where Dan triages, before the
// keep/dismiss decision. The expensive question ("what is the email address") is Prep's job; this answers
// the cheap, separate question ("is this org reachable at all") from signals already in hand after the
// scout, with no new fetch and no tokens. It exists to flag the known-dead cases so Dan never dismisses a
// reachable show in favour of a doubly-weak long shot he can't actually pitch.
//
// #1586, ON THE STAGE NAMED HERE: this and the three comments beside it named the Review stage until
// 2026-08-08, and that was true when #1145 was written. (Phrased without repeating the wording itself,
// because the guard on this file cannot tell a line describing the mistake from a line making it.)
// Since #1134's stage-only navigation, keep/dismiss happens on
// Scout (`StageNavigation.matches(.scout,)` is `status == .new` and still open, with `OpenForDecision` as
// the one definition of a show awaiting his decision), and `.review` means `status == .drafted`, a show
// whose email is already written. The stale wording was not cosmetic: it is what made a reading of this
// code conclude the feature worked as designed, and it hid #1585 (the check never surfacing where triage
// happens) for several days. So the older #1145/#1308/#1336 issue text, which predates the rename, should
// not be read literally where it says Review either.
//
// Deliberately coarse (the honest limit of free data): at triage a prospect has a presenter name and a
// source listing URL, but websiteURL is populated during Prep, so a "real website" can only ever be
// POSITIVE evidence when present, never required. Pure and exhaustively tested (a rule is only as real as
// its detection). Layer 2 (an opt-in per-date probe) upgrades this to a firmer email-found/not-found.
enum Reachability {
    enum Signal: Equatable { case likelyReachable, unclear, hardToReach }

    // #1308 Layer 2 Phase 2: what the triage row actually shows. Before a probe it is the free heuristic,
    // and only the hard case surfaces (a named presenter with no proven site stays silent, `.none`, so the
    // badge never over-promises). Once a probe has run it is the FIRM answer.
    // #1324: `weakContactOnly` is a probed show whose only found address is a venue front desk or a press
    // inbox (held by the venue/press guard, so not sendable). An email exists, so "No email found" would
    // be untrue; this names the weak result honestly without pretending it is sendable.
    // #1325: `staleProbe` is a probe whose result is older than the freshness window. The org may have
    // moved since, so the firm answer becomes a distinct "worth re-checking" state instead of a stale
    // firm claim.
    // #1626: `contactFormOnly` is a real way through, not a near miss, so it is its own state rather
    // than a shade of "no email". The row prints the link beside it.
    // #1856: there is no "try the act directly" state. #1795 added one and Dan took it off the card the
    // next day (2026-07-31): "I don't need the badge to say try the act directly. it should just say hard
    // to reach if it's a generic inbox, email found if it found one or no email found". The advice was
    // telling him to do by hand the thing the check itself now does, so the card reports and the check
    // acts, rather than both half-doing each other's job.
    // #1724: `checkMissedIt` is the one state here that is not a conclusion about the show. It says a check
    // ran over it and came home with nothing for it, so the row is still unchecked and Dan is about to be
    // offered it again at full price. Its own case rather than silence, which is what a never-checked show
    // shows, and rather than a shade of `noEmailFound`, which is a real finding this row does not have.
    // #2528: CaseIterable so the guard that keeps this vocabulary in step with ProbeResult can
    // ENUMERATE it rather than restate it. A hand-written list of badges inside a test would be a
    // fourth copy of the same vocabulary, and it would only ever check the cases somebody remembered
    // to add to it (L96), which is the exact defect the guard exists to catch.
    enum Badge: Equatable, CaseIterable {
        case none, hardToReach, noEmailFound, weakContactOnly, contactFormOnly, socialOnly,
             staleProbe, checkMissedIt, emailFound
    }

    // Dan's call, 2026-07-28, looking at the real cards: the badges' loudness was the exact INVERSE of
    // how much he would act on them. "Contact form only" was the loudest thing on the row, "No email
    // found" next, and "Email found", the one he can act on immediately, was the quietest.
    //
    // The cause is structural, not a bad colour pick: forest green on Overture's dark forest background
    // has almost no contrast, so `.confirmed` is inherently the faintest tone in the app, and the best
    // news therefore read as the least important. Tone now tracks ACTIONABILITY, which is what his
    // standing rule already said about gold (reserved for what he can act on):
    //
    //   emailFound       gold    an address he can write to right now, the loudest thing on the row
    //   noEmailFound     rust    still prominent: deciding to drop a show is also acting on it
    //   contactFormOnly  muted   a real way through, but one that costs him fifteen minutes at their
    //                            site rather than a send, so it is the last thing he picks up. This
    //                            REVERSES the gold it was given two days ago in #1626, on his look at it.
    //   weakContactOnly  muted   same reasoning: a venue front desk is real but not what he acts on first
    //
    // Lives here rather than in the view's switch so the decision is testable at all: a SwiftUI body is
    // not, and this is exactly the "#885, keep the decision out of the view" pattern the copy follows.
    // `onlyUnverified` describes the ADDRESSES a check found (#1628): true when it found one or more and
    // NONE of them was read off a page naming the act.
    //
    // Dan's call, 2026-07-28, arrived at over two rounds of looking at real cards. It was first gold, the
    // same as a verified find, and he said an address he would want to CHECK before writing must not be
    // painted as his most actionable row. So it went to rust. Looking at that: "unverified email looks
    // like no email. too similar." Rust made it distinct from a verified find and indistinguishable from
    // a failure, which is worse. It now has its own dim gold, so found-something stays in the gold
    // family, found-nothing stays rust, and the three read as three weights.
    //
    // It can only ever change the email-found badge; every other state ignores it, since a form or a
    // front desk carries no claim about verified addresses either way.
    static func tone(for badge: Badge, onlyUnverified: Bool = false) -> OVPillTone {
        switch badge {
        case .emailFound: return onlyUnverified ? .tentative : .pending
        case .noEmailFound: return .warning
        // #1724: neutral, with `staleProbe`, and for the same reason. Both say "this row has no current
        // answer and another check is how it gets one". It is not rust: rust is reserved for a finding, and
        // a missed show has none. Nothing here is a warning about the show itself.
        // #2612: a social DM sits with the contact form for the same reason: a real way through that
        // costs Dan his own time rather than a send, so it is not the loudest thing on the row.
        case .contactFormOnly, .socialOnly, .weakContactOnly, .hardToReach, .staleProbe, .checkMissedIt,
             .none:
            return .neutral
        }
    }

    // #2912: the pill's TONE for that one reason, which is the half a sentence cannot carry. Every other
    // empty answer is rust, the colour of a finding of nothing, and that is right for them. This row has
    // a link on it that Dan can judge in seconds, so rust would tell him to stop looking at the one card
    // where looking is the whole point; gold would say he can write to somebody, which is the
    // substitution #2147 refuses. `tentative` is the tone whose own definition is "found something, but
    // cannot stand behind it".
    //
    // A function rather than a `tone(for:)` case, because the badge is still `.noEmailFound` and nothing
    // else about the verdict moves (#1722): the fit score, the ledger and the stored result see exactly
    // what they saw when such a profile was refused outright.
    static func emptyAnswerTone(_ reason: EmptyReason?) -> OVPillTone {
        reason == .unconfirmedSocialProfile ? .tentative : tone(for: .noEmailFound)
    }

    // #1325: how long a probe result is trusted before it reads as possibly out of date (~90 days,
    // roughly the pitch horizon). Past this the badge asks Dan to re-check rather than trusting the old
    // answer.
    static let probeFreshness: TimeInterval = 90 * 24 * 60 * 60

    // A probe result older than the freshness window. Never-probed (nil) is not stale.
    static func probeIsStale(probedAt: Date?, now: Date) -> Bool {
        guard let probedAt else { return false }
        return now.timeIntervalSince(probedAt) > probeFreshness
    }

    // #2261: what a row says about running the check AGAIN, in three states rather than a bare button.
    //
    // Only a row whose answer is FROZEN is offered one. A show already released by the clock is included
    // by the ordinary control, and a second route beside it would be two controls for one action (#843);
    // a show never checked at all has no answer to re-run and the offer would imply it had.
    enum RecheckState: Equatable {
        /// No frozen answer here: either nothing has ever been checked, or the clock already released it.
        case notOffered
        /// Frozen on an answer, and Dan can ask for it to be run again.
        case offer
        /// #2267: he pressed and the check is under way for THIS show. Its own state, with its own
        /// elapsed time on screen, because the run takes about two and a half minutes and a control that
        /// still looked pressable would get pressed again (L44).
        case running
        /// He asked and nothing is running. Either the run has not been started yet, or it ended without
        /// reaching this show. Deliberately the SAME state for both: from the row's point of view the
        /// question is outstanding and the answer is to try again, and claiming a run is in flight when
        /// none is would be a spinner over a dead run, which is the exact thing the global rule forbids.
        case requested
    }

    // #2621: whether a check ran over this row and came home without an answer for it, still inside the
    // freshness window. ONE definition, read by the card's offer, by the badge, and by
    // `QueueModel.keysMissedByACheck` (which adds only the candidacy rule on top), so "Check the rest"
    // can never run a set the cards never claimed to be in (L16).
    //
    // `probedAt == nil` is load-bearing: a row a later check ANSWERED is not missed any more, whatever an
    // earlier run did to it, and paying for a lookup that already succeeded is the one thing this must
    // never do. The mark ages on the same 90-day clock as every other reachability fact rather than
    // offering to spend money on one show forever.
    static func wasMissedByACheck(probedAt: Date?, unansweredAt: Date?, now: Date) -> Bool {
        probedAt == nil && unansweredAt != nil && !probeIsStale(probedAt: unansweredAt, now: now)
    }

    static func recheckState(probedAt: Date?, hasInheritedAnswer: Bool,
                             recheckRequestedAt: Date?, now: Date,
                             checkIsRunning: Bool = false,
                             isStillOpen: Bool = true,
                             missedByACheck: Bool = false) -> RecheckState {
        // #2267: a show past the keep-or-dismiss moment is not offered one, and this is asked FIRST so it
        // beats even an outstanding request. The candidacy rule already refuses to include such a show in
        // a check, so an offer here would sell an action the rest of the app declines, and the money would
        // buy an answer nothing reads. Caught by trying to look at this on a real store, where every
        // answered show was dismissed and past and all seven wore the control.
        //
        // `isStillOpen` is decided by the caller through OpenForDecision, the same predicate the candidacy
        // rule uses, so the control and the run can never disagree about which shows are still live (L16).
        guard isStillOpen else { return .notOffered }
        // Asked first, and deliberately without reference to the answer underneath. A request made just
        // before the clock released the answer must keep reading as acknowledged rather than flickering
        // back to an unpressed-looking control the moment the window expires.
        //
        // #2267: `checkIsRunning` is only ever consulted for a show that HAS an outstanding request, so a
        // run in flight for other shows never makes every card in the queue claim to be in it.
        if recheckRequestedAt != nil { return checkIsRunning ? .running : .requested }
        if hasInheritedAnswer { return .offer }
        // #2621: something DID run over this row and came home short. The guard below was written for a
        // show nothing has ever looked at, and swallowed this third case, leaving the one badge that
        // names a specific fault as the only one with nothing to act on.
        if missedByACheck { return .offer }
        guard probedAt != nil, !probeIsStale(probedAt: probedAt, now: now) else { return .notOffered }
        return .offer
    }

    // #1596 Phase 3: what a check CONCLUDED, stored on the row rather than re-derived from its recipients
    // every time it draws. Deliberately NOT reusing `Badge`, whose `.none` means "render nothing"; a nil
    // result here means "no check has ever run", and two meanings for one token inside one feature is how
    // the #863 class of bug starts.
    // #1626: `contactFormOnly` is a show with no email whose act takes messages through a form on its
    // OWN site. Measured on the first real multi-date run (#1603): the check identified the act on 14 of
    // 14 shows, and 6 of those published only a form or an Instagram. Every one was stored with the link
    // and rendered "No email found", so Dan was told to give up on shows he could have written to.
    // Dan's rule (2026-07-27): a form on the act's own site counts and he fills it in by hand; an
    // Instagram or other social DM does not and stays a dead end.
    enum ProbeResult: String, Equatable, Sendable, CaseIterable {
        case emailFound = "email_found"
        case weakContactOnly = "weak_contact_only"
        case contactFormOnly = "contact_form_only"
        // #2612: no address and no form on their own site, but they take messages on a social profile.
        // Dan, 2026-08-13, on the Song & Word card: "I changed my mind and I actually do want to know when
        // it's instagram only with no contact form. This actually feels like a perfect fit for me but they
        // don't have a website so I'm going to DM them on instagram." That reverses #1626 and #2421, both
        // his own, which made a social handle a dead end and then deleted the ones already stored.
        //
        // Its OWN verdict rather than a shade of `contactFormOnly`, because what Dan does differs (a DM in
        // the Instagram app, not a form on a website) and because the volume of each matters to him. A
        // fifth case reaches the fit score, the ledger and the badge, which is precisely why it is one:
        // every one of those was giving the wrong answer about a show he calls a perfect fit.
        case socialOnly = "social_only"
        case noEmailFound = "no_email_found"
    }

    // #1722: WHY a check came back with nothing usable. Deliberately NOT a fifth ProbeResult and NOT an
    // eighth Badge: the verdict really is "no email found", and adding a case would reach the fit score
    // (#1648 Ranker.contactRoutePoints), ContactScoreAdjustment (which overwrites the pre-check score on
    // every transition), the organisation ledger, ContactFormResultMigration, a stored-string migration
    // whose unknown values read as "never checked", and a pill tone the palette has no free slot for.
    // What was wrong was never the verdict; it was the SENTENCE. So only the sentence varies.
    //
    // It has to be EMITTED by the run rather than inferred here: the runbook DISQUALIFIES a venue address
    // and therefore never sends one, so the app sees an entry with no contacts and, without this, cannot
    // tell a search that found the room's own inbox and refused it from one that found nothing at all.
    // Both used to read "No email found", which is LESSONS L11: a message may claim only what its check
    // actually measured.
    //
    // Each value has to earn a DISTINCT sentence Dan can act on differently; a reason that would render
    // identically to another belongs in that one. Three at first (#1722), four since #1817.
    enum EmptyReason: String, Equatable, Sendable, CaseIterable {
        // The check found an address, and it was the room's own. Dan's standing rule is that a venue's
        // inbox is a wrong result, not a weak one, so it was refused rather than kept at low confidence.
        case onlyVenueContact = "only_venue_contact"
        // The check found an address, and it was a press or PR desk: the wrong department to pitch
        // photography to (#635), refused for the same reason at any confidence.
        case onlyPressContact = "only_press_contact"
        // The check looked and this show's people genuinely publish no address anywhere. This is the one
        // case where today's "No email found" was always true, so it keeps that wording exactly.
        case nothingPublished = "nothing_published"
        // #2265: the check reached a social profile and stopped there. Its own value, and deliberately
        // NOT a shade of `nothingPublished`, whose wording is documented above as the one case that was
        // always true: a run that found a doorway and did not open it has not established that nothing is
        // published, and on 2026-08-07 the address really was one fetch away
        // (devin@devinmarlowe.example, published, no login). Collapsing the two made that documentation
        // false and hid the state where a re-check is most likely to succeed.
        case onlySocialProfile = "only_social_profile"
        // #1817: the check could not work out WHO to write to. No producing organisation was named, and no
        // performer could be named either (the listing page could not be read, or it named nobody), so the
        // search for an address never had a target and never really ran.
        //
        // Its own value because it is a different FINDING from the one above, not a shade of it, and Dan
        // does a different thing with it: "nobody publishes an address" is a finished search he can give
        // up on, while this is a show where his own knowledge of a room beats the run's, and one he can
        // open the listing for himself. Reporting it as `nothing_published` is the L11 overclaim that
        // opened #1817 in the first place.
        case noOneIdentified = "no_one_identified"
        // #2259: the check worked out WHO, and no way to reach any of them. The live instance is the
        // Summer Lovin' run of 2026-08-07, which named Isabella Borte and Ani Chong and gave each
        // `form_or_dm` with no address and no form URL, so the importer discarded both and the card said
        // "No email found" about a run that had found two people.
        //
        // Its own value, not a shade of the three above, because Dan does a different thing with it.
        // `nothingPublished` is a finished search he can give up on; `noOneIdentified` is one where his
        // own knowledge of the room beats the run's; `onlySocialProfile` is a doorway worth another
        // check. This one hands him NAMES with no route, which is the state where a two-minute hand
        // search is most likely to beat the machine, because it starts from something.
        case namedButNoRoute = "named_but_no_route"
        // #2893: the check DECLARED a way in and supplied none. `method: "form_or_dm"` means "reach this
        // person through a form or a DM", so a contact carrying it with no `formUrl` names the way in and
        // gives none; the same holds for a named decision maker or a generic inbox carrying no address.
        //
        // Its own value, and specifically not a shade of `namedButNoRoute`, whose comment above cites
        // exactly this shape as its live instance. That was the mistake: `namedButNoRoute` is a fact
        // about the WORLD (these people publish nothing), and this is a fact about the RUN (it stated a
        // route type and did not finish the step that finds one). Both arrive as "no contacts survived",
        // and telling Dan a search finished when it did not is the L11 overclaim. He acts on them
        // differently too: this one is worth another check, where names with no route is worth his own
        // two minutes on the listing.
        case routeNamedButNotSupplied = "route_named_but_not_supplied"
        // #2912: the check found a social profile carrying the target's NAME and nothing tying it to this
        // show, and Dan asked to see it rather than have it withheld. So the show has a handle on it and
        // still has nobody Overture can say it reaches.
        //
        // Its own value, and specifically not a shade of the two nearest ones, because both would be
        // false about the card Dan is looking at. `onlySocialProfile` calls the account "this act's",
        // which is the substitution #2147 forbids said in a sentence instead of a field. `namedButNoRoute`
        // says the search finished and found no way in, and sends him to the listing to search by hand,
        // while this card is showing him a possible way in he can judge in seconds.
        //
        // It is the one empty reason under which the card SHOWS him something to act on, which is why it
        // is also the one that changes the pill's tone (see `emptyAnswerTone`).
        case unconfirmedSocialProfile = "unconfirmed_social_profile"
    }

    // Whether a contact names a route it does not carry. Exhaustive over `ContactMethod`, so a method
    // added later breaks the build here and has to declare which field it promises, rather than
    // defaulting into "nothing is missing" (L113).
    //
    // An absent or unrecognised `method` is NOT a contradiction: nobody declared a route, so nothing is
    // contradicted, and reading silence as a claim would fire this on every older run.
    static func declaredRouteIsMissing(_ contact: PrepContact) -> Bool {
        guard let method = ContactMethod(rawValue: contact.method ?? "") else { return false }
        func absent(_ value: String?) -> Bool {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch method {
        // Both are addresses: the method says which desk, and either way the promise is an email.
        case .namedDecisionMaker, .genericInbox: return absent(contact.email)
        // A bare homepage root as the `formUrl` is deliberately ACCEPTED here, and it is a real case (two
        // in the 2026-08-17 run). It is a weaker route than a form, but it is a route: it lands Dan on
        // the act's own site, where he can find the contact page in seconds. Refusing it would delete a
        // usable way in to enforce a tidier shape, which is a worse trade than keeping it (L116).
        case .formOrDM: return absent(contact.formUrl)
        // #2893: promises nothing, so it can contradict nothing. This is the value a run uses to say it
        // found the person and no route, which is a finished answer rather than a broken one.
        case .noRouteFound: return false
        }
    }

    // #2259: why a check that emitted contacts still left the show with nobody to write to.
    //
    // `emptyReason` (#1722) existed only for a run that emitted NO contacts, so a run that emitted two
    // unusable ones fell through every door and the card said nothing. This closes that: it is asked
    // after the ingest, when how many contacts SURVIVED is known, which is the only moment the
    // difference between "found somebody" and "found somebody reachable" is visible.
    //
    // nil means there is nothing to explain: either the run emitted nothing (a case #1722 already
    // covers, and whose own reported reason must not be overwritten here), or somebody usable survived.
    static func emptyReason(afterIngesting contacts: [PrepContact],
                            usableRecipients: Int) -> EmptyReason? {
        guard !contacts.isEmpty, usableRecipients == 0 else { return nil }
        // #2893: asked FIRST, because it is the only one of the three that is a fact about the RUN
        // rather than about the show, and it is the only one that says the search did not finish. A
        // single contradictory contact is enough: the run has already shown it will state a route it did
        // not find, so nothing it emitted for this show establishes that anything was searched properly.
        if contacts.contains(where: declaredRouteIsMissing) { return .routeNamedButNotSupplied }
        // #2912: asked BEFORE the social reason below, because the sentence below asserts the profile is
        // the act's own and here nothing established that. Every social profile this run found is a name
        // match, so there is no confirmed handle on the card for that sentence to be true of.
        //
        // Asked over the profiles rather than over every contact, deliberately: a person the run found
        // with no route at all beside the guess does not turn this back into names with no route, because
        // the card IS showing a handle and the line above it has to be about the handle.
        let profiles = contacts.filter(isSocialRoute)
        if !profiles.isEmpty, profiles.allSatisfy({ $0.nameMatchOnly == true }) {
            return .unconfirmedSocialProfile
        }
        // A doorway found and not opened keeps its own reason: it is the state most likely to change on
        // a re-check, and collapsing it into the new one would hide that (#2265).
        if onlySocialRoutes(contacts) { return .onlySocialProfile }
        return .namedButNoRoute
    }

    // #2912: a contact whose only way in is a social profile. Extracted from `onlySocialRoutes` below
    // rather than written a second time, so "is this route a social profile" has one definition and the
    // reason above and the verdict cannot answer it differently (L16).
    static func isSocialRoute(_ contact: PrepContact) -> Bool {
        let hasEmail = !(contact.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasEmail, let form = contact.formUrl else { return false }
        return isSocialOnly(form)
    }

    // nil means no check has ever run, which is a different thing from a check that came back empty. The
    // old signature could not tell those apart: it asked whether the row currently has a sendable
    // recipient, so a checked-and-empty show and a never-checked show both answered "no".
    // #1598 Phase 5: `inherited` is an answer paid for on a DIFFERENT show by the same organisation, and
    // it renders IDENTICALLY to one paid for here (Dan's call, 2026-07-27); only the hover text says
    // where it came from. A sixth badge state would be the #843 shape: a second line telling him nothing
    // the first did not. It is consulted only when this show has no answer of its own, and only ever
    // carries a positive, because OrgAnswerLedger refuses to fan out anything else.
    // #1724: `missedByACheck` is whether a check ran over this show and came home with no answer for it,
    // still inside the freshness window. Ranked BELOW every real answer, its own and an inherited one, so a
    // show that has since been answered never reports the earlier miss, and ABOVE the free heuristic below,
    // because a fact measured about a real run beats a guess made from the listing's shape.
    static func badge(result: ProbeResult?, probeIsStale: Bool = false,
                      inherited: ProbeResult? = nil, missedByACheck: Bool = false,
                      presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Badge {
        if let result {
            // A stale result (found or not) reverts to "worth re-checking", so it never misleads.
            if probeIsStale { return .staleProbe }
            switch result {
            case .emailFound: return .emailFound
            case .weakContactOnly: return .weakContactOnly
            case .contactFormOnly: return .contactFormOnly
            case .socialOnly: return .socialOnly
            case .noEmailFound: return .noEmailFound
            }
        }
        // Freshness was already judged when the ledger was built, against the ORIGINAL check's date, so
        // it is not re-derived here: one decision, in one place.
        if inherited == .emailFound { return .emailFound }
        if missedByACheck { return .checkMissedIt }
        switch assess(presenter: presenter, sourceListingURL: sourceListingURL, websiteURL: websiteURL) {
        case .hardToReach:
            // #1859: only the MEASURED dead end still speaks. A social-only listing is one Overture has
            // actually tested (a raw fetch returns a login wall, and lead intake refuses these outright),
            // so it warns whoever is billed.
            //
            // A show that simply names no organiser is NOT a dead end any more: since #1856 a check on one
            // pursues the act itself, and 93 open shows are in that state. Calling it hard to reach before
            // anything has looked is a verdict no check reached (L11), which is what Dan said when he was
            // asked what such a card should say: nothing, until a check runs. So the row stays silent and
            // the check, not the badge, is what answers.
            if let listing = sourceListingURL, isSocialOnly(listing) { return .hardToReach }
            return .none
        case .likelyReachable, .unclear: return .none
        }
    }

    static func assess(presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Signal {
        // Dead ends FIRST, so a website can never swallow them (#1335). A website is positive evidence only
        // ALONGSIDE a presenter on a non-social listing, never a standalone override of these known-dead cases.
        // A social-only source is a verified dead end: a raw fetch of these returns a login wall, and lead
        // intake already refuses them. Hard to reach whatever else is known, website or not.
        if let listing = sourceListingURL, isSocialOnly(listing) { return .hardToReach }
        // No presenting org identified, just a venue and a title: there is nothing to email, website or not.
        if (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .hardToReach }
        // With a presenter in hand and a non-social listing, a confirmed real (non-social) website is
        // positive evidence: outreach has a live target.
        if let site = websiteURL, isRealWebsite(site) { return .likelyReachable }
        // A named presenter on a normal listing, but no proven website: Overture cannot cheaply confirm
        // reachability here, so it stays silent rather than over-promising.
        return .unclear
    }

    // Reuses LeadIntake's verified login-walled-host list (#1004) so the two never drift.
    // #1626 made it internal rather than adding a second list: the question "is this link a social page
    // behind a login" is now asked in two places (the free heuristic here, and whether a contact form is
    // one Dan will actually use), and two lists would eventually disagree about Instagram.
    // #2265: every route this run found is a social profile and nothing else. That is the shape the
    // 2026-08-07 run produced on 2 of its 3 shows, and it is checkable from what it EMITTED without
    // trusting its account of what it read (#2269).
    //
    // Every one of them, not merely one: a run that also found a real address or a form on the target's
    // own site did reach somewhere Dan can use, and labelling that a social dead end would be false. An
    // empty list is not this case either; that is the run coming back with nothing, which has its own
    // reason and its own branch.
    static func onlySocialRoutes(_ contacts: [PrepContact]) -> Bool {
        guard !contacts.isEmpty else { return false }
        return contacts.allSatisfy(isSocialRoute)
    }

    static func isSocialOnly(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return LeadIntake.knownUnreadableHost(url) != nil
    }

    private static func isRealWebsite(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return LeadIntake.knownUnreadableHost(url) == nil
    }
}

// #1145 copy. Kept out of the view (testable, #885) and named so the copy-inventory shows the whole
// sentence Dan reads.
enum ReachabilityCopy {
    // #2261: asking for a frozen answer to be researched again. The control says what it DOES; why Dan
    // might want it (the check has got better since) is his own knowledge, not a sentence the row repeats
    // on every answered show.
    static let checkAgain = "Check again"
    // #2267: the press runs it, so the help says that plainly and says it costs. Dan asked for exactly
    // this: "if we can find their own site we should check it without me."
    static let checkAgainHelp =
        "Research this show's contacts again now, instead of keeping this answer until it's 90 days old. It costs one lookup, and you'll see what it will spend before it starts."
    // Why the control is greyed. Names the reason rather than leaving a dead button, since the run it is
    // waiting on is one Dan started himself and can see elsewhere on screen.
    static let checkAgainBusyHelp =
        "Another run is going. This can start once that finishes."

    // #2392: striking one address before the show is prepped. The help says what removing it BUYS, which
    // is the reason to do it here rather than after the draft comes back: the run never researches it and
    // never writes to it, so the money is not spent on somebody Dan already knew was wrong.
    //
    // "Remove", deliberately, and never "do not contact": the row's Dismiss menu already carries a
    // control called "Do not contact", and that one records that an ORGANISATION asked Dan to stop, which
    // is the one decision in the app that cannot be taken back. This is an ordinary removal he can undo by
    // typing the address in again, and it borrows the draft-review panel's own word for the same action
    // (its "Remove this contact"), so one word means one thing across both surfaces.
    static let removeAddressHelp =
        "Remove this address. Prep won't research it or write to it, and later checks won't put it back."
    // The icon has no words of its own, so this is the only thing VoiceOver can read. It names the
    // address, because "Remove" over four identical buttons says nothing about which one this is.
    static func removeAddressLabel(_ email: String) -> String { "Remove \(email)" }
    static let recheckRunning = "Researching this show again"
    // Asked for, and nothing running: not started yet, or a run ended before reaching this show. The
    // sentence says only what is true of both, and the control beside it says what to do.
    //
    // NOT "not researched yet", which was the first wording: this line sits directly under a badge naming
    // what a check already found, so a sentence saying nothing has been researched contradicts the line
    // above it. What has not happened is the re-run.
    static let recheckOutstanding = "Waiting to be checked again."
    static let checkAgainRetry = "Try again"
    static let hardToReachBadge = "Hard to reach"

    // #1859: the sentence names the ONE thing that can still produce this badge. It used to offer two
    // reasons, "no presenting org, or only a social page", and only the second can happen now; leaving the
    // first in would have the card explaining a card Dan is no longer looking at.
    static let hardToReachHelp =
        "The only listing for this one is a social page, which sits behind a login, so there's no way in from there. You can still keep it and add a contact by hand. This is a heads up so you don't dismiss a reachable show in its place."

    // #1308 Layer 2 Phase 2: the firm result once a probe has run.
    static let emailFoundBadge = "Email found"
    static let emailFoundHelp = "A reachability check found a contact you can email for this show."

    // #1598 Phase 5: the same badge, on a show whose answer was paid for on a different show by the same
    // organisation. The provenance lives here and nowhere else on the card, so a reused answer never
    // reads as a claim that this particular show was researched.
    static func inheritedEmailFoundHelp(organisation: String) -> String {
        "A reachability check on another \(organisation) show found this contact, so this show didn't need checking again."
    }
    static let noEmailFoundBadge = "No email found"
    static let noEmailFoundHelp =
        "A reachability check couldn't find an email for this show. You can still keep it and add a contact by hand."

    // #1722: the same badge, saying what the check actually measured. Dan's call 2026-07-29: the VISIBLE
    // sentence changes, not just the hover text, because a tooltip fix would leave the untrue claim on
    // screen, which is the whole complaint. Same rust tone, same icon, same position, so the row says
    // something truer without getting louder.
    //
    // A missing reason falls back to today's wording rather than guessing at a cause. The reason comes
    // from a prompt (L27), so it WILL sometimes be absent, and with none in hand the app knows only that
    // nothing usable came back, which is exactly what the old sentence says.
    static func emptyAnswerBadge(_ reason: Reachability.EmptyReason?) -> String {
        switch reason {
        case .onlyVenueContact: return "Only the venue's address"
        case .onlyPressContact: return "Only a press address"
        // #1817: names what happened, and deliberately does not use the words "no email", because no
        // search for one ever ran. Same rust tone and same position: what varies is only the sentence.
        //
        // NOT "couldn't tell who to write to", which was the first wording: the card can already carry
        // "Couldn't tell who's putting this on: the listing named only the room" (#1788), and two lines
        // opening the same way, one under the other, is the #843 shape. This one is about the CHECK
        // coming back with nobody to research, which is the thing the other line does not say.
        case .noOneIdentified: return "Nobody found to write to"
        // #2265: says where the check STOPPED, which is a different fact from what it failed to find,
        // and the one Dan can act on: it is the state most likely to change on a re-check.
        case .onlySocialProfile: return "Only a social profile"
        // #2259: says the check got somewhere, and where it stopped. Deliberately not the words "no
        // email", which would throw away the part Dan can use: it came back with names.
        //
        // Dan's wording, chosen 2026-08-07 from four rendered against the lines it sits beside. It leads
        // with "Only", matching three of the five, so the set reads as one family rather than as one
        // sentence dropped among labels.
        case .namedButNoRoute: return "Only names, no way to reach them"
        // #2893: names what the CHECK did, not what the show is like, because that is the difference
        // this reason exists to carry and the thing Dan acts on. It deliberately breaks the "Only"
        // family the four above share: those four report a finished search that found little, and this
        // one reports a search that stopped mid step, so reading as one of them is exactly the confusion.
        case .routeNamedButNotSupplied: return "Check named a route it never found"
        // #2912: says the two things at once that decide what Dan does next, and it has to say both. A
        // profile exists, so this is not a row to give up on; nobody confirmed whose it is, so it is not
        // a contact either. It joins neither family above on purpose: not the "Only" four, which report
        // a finished search that found little, and not the route badges, which promise a way in.
        case .unconfirmedSocialProfile: return "Possible profile, not confirmed"
        case .nothingPublished, nil: return noEmailFoundBadge
        }
    }

    static func emptyAnswerHelp(_ reason: Reachability.EmptyReason?) -> String {
        switch reason {
        case .onlyVenueContact:
            return "A reachability check found an address for this show, but only the venue's own, and a venue's inbox is never who you're pitching. You can still keep it and add a contact by hand."
        case .onlyPressContact:
            return "A reachability check found an address for this show, but only a press or PR desk, which is the wrong department to pitch photography to. You can still keep it and add a contact by hand."
        case .noOneIdentified:
            return "The check couldn't name anyone to research for this show, so it never got as far as looking for an address. If you know who puts this on, add a contact by hand and it's back in play."
        // #2265: says what it DID reach and what that is worth, because the difference matters here.
        // A social profile is a login wall rather than an address, but it also means somebody was found,
        // which is a better starting point than nothing and often means an address exists elsewhere.
        // Deliberately NOT phrased like `hardToReachHelp`, which also mentions a social page behind a
        // login. That one is about the LISTING Overture was given before any check ran; this is about
        // where a check that really ran ended up, and the two would otherwise read as one sentence twice
        // (#843). What only this one can say is the last clause: an address may well exist elsewhere.
        case .onlySocialProfile:
            return "A check ran and got no further than this act's social profile, which needs a login. Their own site may still publish an address, so of all the shows with no contact this is the one most likely to give one up on another check."
        // #2259: what it DID establish, and the next step that follows from it.
        //
        // Careful about one thing, caught reading this cold: a contact with no address and no form is
        // DISCARDED by the importer, so the people the check named are not on this card and this
        // sentence must not point at them as though they were. What it can honestly point at is the
        // listing, which is where the check read them in the first place.
        case .namedButNoRoute:
            return "A check worked out who is putting this on and found no way to reach any of them, so it kept none of them. The listing still names them, and a search by name often turns up an address the check missed."
        // #2893: says plainly that the fault is the check's, and what follows from that. The last clause
        // is the only thing this sentence can say that no other one can: another check is worth more
        // here than his own search, which is the reverse of the advice above it.
        case .routeNamedButNotSupplied:
            return "A check said there was a way to reach these people and then did not give one, so there was nothing to keep. That is the check falling short rather than the show being hard to reach, so another check is worth more here than a search by hand."
        // #2912: what the check DID establish, what it could not, and whose call the rest is. The middle
        // clause is the one no other sentence here can say, and it is the reason the handle is not being
        // counted as a contact: an account with the right name on it is not the same as the right person.
        case .unconfirmedSocialProfile:
            return "A check found a profile carrying the right name and nothing in its bio or recent posts tying it to this show, so who is on the end of it is not settled. If you recognise the handle below, the DM is yours to send."
        case .nothingPublished, nil:
            return noEmailFoundHelp
        }
    }

    // #2912: the same fact printed on the LINE of one link, for the row that carries more than one and
    // where the badge above can no longer say WHICH. A confirmed handle and a stranger's, side by side
    // and reading identically, is the exact shape #2147 refuses, and it is the shape a two performer show
    // produces the moment one of them is searchable and the other is not.
    //
    // Deliberately NOT printed when the row shows a single link: the badge directly above is already
    // saying it, and a second line telling Dan nothing the first did not is the #843 shape (his own call
    // in #1628, about the caveat that used to sit beside every address).
    //
    // Short enough for the right justified meta column, and it names the missing half rather than only
    // announcing doubt: "not confirmed" alone leaves him guessing whether the doubt is about the person,
    // the address or the show.
    static let unconfirmedProfileNote = "Name matches, nothing ties it to this show"

    // #1626: no email, but the act takes messages through a form on its own site. A way through that
    // costs Dan a few minutes rather than a send, so it says what he would have to do.
    static let contactFormOnlyBadge = "Contact form only"
    static let contactFormOnlyHelp =
        "The act takes messages through the form on their own site. You'd fill that in yourself; Overture can't send it for you."

    // #2612: no address and no form on their own site, and they take messages on a social profile.
    // Deliberately distinguishable from the form badge above: what Dan does about it is different (a DM in
    // the app on his phone, not a form in a browser), and he asked to be told which he is looking at.
    static let socialOnlyBadge = "Social DM only"
    static let socialOnlyHelp =
        "No address and no form on their own site, but they take messages on the profile linked here. You'd send the pitch as a DM yourself; Overture can't send it for you."

    // #1324: a probe found an address, but only the venue's front desk or a press inbox, not the
    // presenter's own. Real, but weak: worth naming honestly rather than calling it no email at all.
    static let weakContactOnlyBadge = "Weak contact only"
    static let weakContactOnlyHelp =
        "A reachability check found only a venue or press address for this show, not the presenter's own. You can still keep it and add a stronger contact by hand."

    // #1798: the same badge, saying which hold it actually is. Measured on the live store 2026-07-31: the
    // one show in this state was held by the duplicate guard alone, on FRIGID's own office address, with
    // the venue and press guards both clear. The sentence above would have called a real presenter address
    // a venue or press one, which is the L11 overclaim in a new place.
    //
    // Only the SENTENCE varies (#1722's rule): same verdict, same tone, same position, so nothing reaches
    // the fit score, the ledger or the palette.
    // #1798: and the badge itself, for the same reason. "Weak contact only" is true of a front desk or a
    // press desk and false of a real presenter's own office address that is merely held, so the row would
    // have carried a word its own hover text contradicts (#843, a line that disagrees with the one beside
    // it). Same tone, same icon, same position.
    static func weakContactBadge(reason: Recipient.HoldReason) -> String {
        switch reason {
        case .venueOrPress: return weakContactOnlyBadge
        case .duplicate: return "Held as a duplicate"
        // #2624: neither of the two above is true of it, and the difference is what Dan acts on.
        case .unaccountedAddress: return "Held, address in another name"
        }
    }

    static func weakContactHelp(reason: Recipient.HoldReason) -> String {
        switch reason {
        case .venueOrPress: return weakContactOnlyHelp
        case .duplicate:
            return "This address is already in play on another show at this venue within a few days, so Overture is holding it rather than writing to the same person twice. If they are different bookings, clear the duplicate flag on the contact and it is sendable again."
        case .unaccountedAddress:
            return "The address found here is in a different name from the contact on this show, and no page was recorded showing it reaches them. A pitch would greet one person and arrive with another, so Overture is holding it. If it does reach them, clear the flag on the contact and it is sendable again."
        }
    }

    // #1628: printed beside a contact the check itself recorded as a guess, so a guess stops reading like
    // a find. Two words, in the address line's own quiet meta styling, because it qualifies the address
    // rather than competing with Keep and Dismiss.
    //
    // Dan's call, 2026-07-28: said ONCE here rather than beside every address. The per-address caveat it
    // replaces went through three layouts and broke the address column each time, the last by making a
    // long address wrap, and he can already tell a generic inbox by looking at it.
    //
    // Only used when NOTHING found was verified. One address read off a page naming the act is enough to
    // write to, so a weaker sibling beside it earns no warning.
    static let unverifiedEmailFoundBadge = "Unverified email found"
    // Speaks for EVERY address on the row, not one caveat beside a single line, and has to read for one
    // address as well as several. It no longer mentions contact forms, which never reach this badge.
    //
    // The sentence it replaces was written for the retired per-address caveat and said "this one". When
    // that caveat went, the sentence was orphaned: it stayed in the code, nothing referenced it, and
    // hovering the new badge explained the wrong thing entirely. Caught only by re-reading the copy in
    // the place that now produces it, which is exactly the cold read this project requires.
    static let unverifiedEmailFoundHelp =
        "Nothing found here was verified as belonging to this act. Only an address read off a page naming them counts; a generic inbox or an inferred address doesn't. It may still be right, so it's worth a look before you write."

    // #1866: the same badge, saying which of the two things put it there. One badge had two causes: the
    // check looked and was not sure, or the check said it was sure and named no page it read the address
    // off, so Overture held its answer down. Those ask different things of Dan, and the second one is about
    // an address that may be perfectly good.
    //
    // Only the SENTENCE varies (#1722's rule, the same way the weak-contact badge splits): same wording on
    // the badge, same tone, same position, so nothing reaches the fit score, the ledger or the palette.
    // Written for the ROW, like the sentence above it, because this badge speaks for every address on the
    // card. It also carries the way out: naming what is wrong and giving Dan nowhere to go is the L80 half
    // of this defect, and the overrule is the whole reason the fact is now recorded.
    // #2895: two ways to be overruled now, one sentence each. Both keep #1866's shape (what the check
    // claimed, what Overture did about it, and the way out), because the overrule is the whole reason the
    // fact is recorded and naming a problem with nowhere to go is the L80 half of the defect.
    static let confidenceHeldDownHelp =
        "The check said it had verified the address here but never named the page it read it off, so Overture isn't treating it as verified. It may well be right: if you recognise it, say so on the review panel and it stops being called unverified."

    // #2895: the page exists and is not in question. Who is on it is. A performer's own site can carry
    // their address and say nothing about this booking, which is a misidentification risk rather than a
    // weak address, so the sentence says what was and was not established.
    static let citationDoesNotCorroborateHelp =
        "The check named the page it read this address off, but that page doesn't tie this person to this performance, so Overture isn't treating it as verified. If you know it's them, say so on the review panel and it stops being called unverified."

    // A row held down BEFORE #2895 recorded no reason, and there was exactly one reason then, so reading a
    // missing one as that reason is a fact about the code that wrote those rows rather than a guess about
    // them (L90).
    static func confidenceHeldDownHelp(_ reason: ContactConfidenceGuard.HoldDown?) -> String {
        switch reason {
        case .pageDoesNotCorroborate: return citationDoesNotCorroborateHelp
        case .namedNoPage, nil: return confidenceHeldDownHelp
        }
    }

    static func unverifiedEmailFoundHelp(heldDown: Bool,
                                         reason: ContactConfidenceGuard.HoldDown? = nil) -> String {
        heldDown ? confidenceHeldDownHelp(reason) : unverifiedEmailFoundHelp
    }

    // #2657: the check found people and none of them can hire Dan.
    //
    // ONE badge for both answers, with the sentence carrying which one, the same #1722 rule the weak
    // contact and unverified badges already follow: same wording, same tone, same position, so the card
    // says something truer without getting louder. The badge states the consequence rather than the
    // finding, because the finding ("13 contacts") is already on the card and is exactly what read as
    // thirteen ways in.
    static let noAuthorityBadge = "Nobody who can hire you"

    // Each sentence names WHO was found, since that is the fact that says what the list is worth, and
    // each ends somewhere Dan can go. Naming a fault and leaving him nowhere is the L80 half of this
    // defect, and the listing's credits block is where he found the producer himself in seconds.
    static func noAuthorityHelp(tier: ContactTier) -> String {
        switch tier {
        case .secondary:
            return "Everyone found here is on the show without running it: a co-performer, a music director or a guest. Nobody with a say over the booking was found. The listing's credits are usually where the producer is named, and you can add them by hand."
        case .tertiary:
            return "Everything found here represents them rather than runs the show: a manager, an agent, a publicist or a booking agency. That may still get you an answer, but nobody who owns the show was found. The listing's credits are usually where the producer is named."
        // Unreachable: `contactAuthorityGap` returns nil for a primary, so this badge never renders over
        // one. Answered rather than crashed, because a switch that cannot answer for every value is a trap
        // waiting for the first caller who does not know the rule.
        case .primary:
            return emailFoundHelp
        }
    }

    // #1325: the earlier probe result has aged past the freshness window, so it may no longer be true.
    static let staleProbeBadge = "Reachability may be out of date"
    static let staleProbeHelp =
        "This show was checked over 90 days ago, so that earlier result may have changed. Run Check reachability again to refresh it before you decide."

    // #1724: a check ran over this show and came home with nothing for it. Says what HAPPENED, not what was
    // found, because nothing was: the run never got as far as this row. The distinction is the whole point,
    // since "No email found" beside it is a finding and this is the absence of one.
    static let checkMissedItBadge = "A check missed this show"
    // Names what it costs him, in the order he needs it: it is still unchecked, and checking it again is
    // the only thing that changes that. It deliberately does not guess WHY the run came home short, which
    // is not recoverable from anything the row holds.
    //
    // "never got an answer for it" is the shortfall sentence's own phrase (ReachabilityRunSummary), reused
    // rather than reworded. Dan meets both about the same event, minutes apart: the run tells him 2 of 5
    // shows never got an answer, and these are those two shows. Two spellings of one fact read as two
    // different things.
    // #2621: it used to end "picking its date again is what gets it an answer", which sent Dan to a run
    // over the whole date while the card itself now carries a link that re-runs this one show. Two
    // spellings of one remedy, and the coarser of the two was the one written down (#843).
    static let checkMissedItHelp =
        "An earlier check included this show but never got an answer for it, so it's still unchecked. Nothing re-checks it on its own."
}

// #1308 Layer 2: the opt-in per-date probe (Layer 2). Kept out of the views (testable, #885), named so the
// copy-inventory shows the whole sentence Dan reads.
enum ReachabilityProbeCopy {
    static let controlLabel = "Check reachability"
    // #1595, then Dan's walk of the Debug build (2026-07-27): the callout had TWO headlines, one naming how
    // many shows compete for the date and one telling him to re-check a stale result. Both are gone with the
    // rest of the callout chrome. The control sits on all 169 of his dates, so a sentence there is noise on
    // 169 rows to earn its keep on one; and the stale sentence was a second telling of what the row's own
    // "Reachability may be out of date" badge already says beside it (#843).
    // #1323: shown while the control's own run already holds its slot, so the greyed-out control explains
    // itself instead of failing after the tap.
    // #2761: it used to say "a run", which was right when any run held the single slot. After #3015 a Prep
    // run does not grey this out at all, so the only thing that can is another contact check, and the
    // sentence says so rather than describing a state Dan cannot see and would go looking for.
    static let controlBusyHelp =
        "Your contact check is still going. This will be available once it finishes."

    // #1617: what a date says once every open show on it has an answer. It takes the button's own slot,
    // so Dan reads it exactly where he went looking for the control, and it names reachability rather
    // than saying a bare "Checked" that leaves the date line claiming nothing in particular.
    static let dateCheckedMarker = "Reachability checked"
    // #2268's "Check again" link on the heading, and its help, are GONE with #2371: the tick box beside
    // the date now stays on a finished date and carries that job, so the words that duplicated it have no
    // reader left. The per-CARD "Check again" (ReachabilityCopy.checkAgain) is untouched.

    // #1334: reads for a single show (a lone stale re-check) as well as several, rather than "these 1 shows".
    static func confirmTitle(count: Int) -> String {
        count == 1 ? "Check reachability for this show?" : "Check reachability for these \(count) shows?"
    }
    static func confirmMessage(dateLabel: String, count: Int) -> String {
        count == 1
            ? "This looks up a real contact for the still-open show on \(dateLabel), so you can tell whether it's still emailable before you keep it. It spends a little on that lookup, only for the show you check here."
            : "This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    }
    static let confirmProceed = "Check"

    // #1685: what Cancel actually does on a PAID run, said next to the control rather than after it.
    //
    // Measured 2026-07-28: Dan stopped a check on 5 shows at the "1 of 5 done" mark and all five lookups
    // had already run, so stopping bought him one answer and the cost of five. Cancel reads as "stop this",
    // and on a paid action a reasonable person hears "stop this before it costs me". Nothing corrected that.
    //
    // Says nothing in dollars, per his standing rule on a Max plan (2026-07-27): the app talks about spend
    // in plain terms, never a figure. It also does not discourage cancelling, because cancelling is often
    // the right thing to do; it just stops the control promising a saving it cannot make.
    static let cancelSpendCaveat =
        "Lookups already under way will finish and still count as spent, so stopping now only saves the ones that haven't started."

    // #1684: the same fact once the stop has been accepted, in the tense that is then true. The caveat
    // above helps him decide; this one tells him what is happening while he waits, and it is the reason
    // the wait is not instant. Kept as its own sentence rather than reusing the caveat, which talks about
    // a choice he has already made by this point.
    static let stoppingSpendNote =
        "The lookups already under way are finishing, so this takes a moment. Their answers will still be saved."
}
