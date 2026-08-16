import Foundation
import SwiftData

// The work-list the app hands to the Prep run: which kept prospects need a contact
// and a draft. `naturalKey` is an OPAQUE token the run must echo back verbatim into
// PrepResults (never reconstruct it; that is what caused the silent-mismatch risk).
// The human-readable fields are for the run's research only.

struct PrepQueue: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var items: [PrepQueueItem]
    // v7 (#1720): the organisations the app has already judged to be the BUILDING rather than the act,
    // each as ProducerGate's folded `key` plus one readable `name`. RUN-LEVEL, beside `items` rather than
    // inside them, because it is one answer about the whole store and not a fact about any one show.
    //
    // The run looks a name up here instead of deciding for itself. #1681: it named Henry Street
    // Settlement, put it in a search query, and reported that no contact existed without ever fetching
    // henrystreet.org. An organisation NOT on this list must be visited before the run concludes nothing
    // exists; one ON it is the house, refused exactly as the hard venue-disqualify rule already refuses
    // the show's own venue.
    //
    // Optional, so a queue file written before this phase still decodes. ABSENT and EMPTY mean different
    // things and the runbook is told so: absent means the file predates the field, empty means the app
    // looked and named nothing.
    var houses: [ProducerGate.House]? = nil
}

struct PrepQueueItem: Codable, Equatable, Sendable {
    var naturalKey: String        // opaque; echo verbatim, do NOT rebuild
    var groupName: String         // research only
    var venue: String?
    var performanceDate: String?  // the run's OPENING night (also the grouping/natural-key date)
    // v4 (#1122): the run's CLOSING night, nil for a single-night show. Present so a draft can pitch the
    // whole run (performanceDate through runEndDate), not just the opening night.
    var runEndDate: String? = nil
    var discipline: String
    var websiteURL: String?
    var sourceListingURL: String?
    var possibleMatchName: String?
    var priorRelationship: String
    var production: String?       // v2 (#586): self | agency | unknown, from Prospect.production/#349
    // v3 (#367): "draft_only" | "contacts_only", absent means do both. Set only for a prospect Dan
    // asked to re-prep; tells the run which half to skip for this item.
    var reprepMode: String? = nil
    // v4 (#1122): true only when this is a multi-night run whose OPENING night has already passed while
    // later dates remain. Absent (the common case: single-night, or a run not yet started) means "no
    // passed opening to work around". Derived with Swift date math (openingNightPassed below), never left
    // to the drafter to infer, so a draft never pitches or names the gone opening night.
    var openingNightPassed: Bool? = nil
    // v5 (#5): the opener archetype this item MUST use, when it belongs to an active A/B experiment. One
    // of the LIVE OpenerArchetype tokens (reason-first / direct-intent), copied from the app-assigned
    // Prospect.assignedArm. credential-first and observation-first were retired on 2026-07-31 and can no
    // longer be assigned (ExperimentEditing.start refuses them), though an arm stamped on a prospect
    // before that date is still a raw string here and the runbook tells the drafter to write the closest
    // live shape rather than a retired one. Absent (the common case: no
    // active experiment) means the drafter uses the normal #362 rotation. The runbook gives this field
    // PRECEDENCE over the rotation, so an experiment item genuinely randomizes what is produced.
    var experimentArmInstruction: String? = nil
    // v6 (#1597): the OTHER shows this one item answers for. Set only on a reachability check, and only
    // when ProducerGate has proved the presenter is a producer rather than a room that rents itself out.
    //
    // A check costs about $1.36 a show, so researching the same producer once per show is the single
    // largest waste in a multi-date run: a week hands over Carnegie Hall Presents eight times. Instead the
    // run researches the producer ONCE and reports the same contact under each key listed here, which
    // keeps Dan's "every show on the date, no exceptions" rule intact while paying once.
    //
    // Carrying the group in the QUEUE is what lets the results file hold a normal entry per show, so the
    // existing import path settles all of them with no second contact-copying code path to keep in step
    // with the first.
    //
    // #1804: it is no longer left to the run to produce those entries. The original note here said a run
    // that ignored this field simply left those shows to be offered again, "which is why it fails safe".
    // It did not: they were paid for a second time, never received the contact the first lookup found, and
    // were counted into #1769's shortfall sentence as never answered, which would have told Dan seven
    // shows went unanswered about a lookup that came home fine. The app wrote the grouping, so
    // `PrepGroupCredit` applies it at ingest and a terse run and a compliant one now settle identically.
    // The run is still asked for an entry per show, because only it can say anything show-specific.
    var alsoAnswersFor: [String]? = nil
    // v8 (#1824): what this show's OWN listing page says, read by the app and handed over as text.
    //
    // Nothing ever told the run what a show IS. On 2026-07-30 a solo singer-songwriter's cabaret concert
    // was pitched as if the recipient were a performing arts organisation, with the only nod to the
    // material ("intimate, funny") naming nothing, because `sourceListingURL` was passed and then never
    // mentioned again in the runbook. The listing said it outright.
    //
    // The run cannot read that page itself. Its tool scope denies every browser tool, and the page is
    // drawn client-side: the run fetched the URL, got an 11KB shell, asked to render it, was refused, and
    // drafted anyway. So the app renders it (`ShowListingReader`) and hands over the text.
    //
    // Absent means the app never looked (no listing URL, or a file written before this field existed),
    // which is a different answer from `unreadable` (it looked and could not read the page) and from
    // `read` with text that turns out to be a calendar rather than this show's own page. The runbook is
    // told all three, because the honest sentence differs for each.
    var showListing: ShowListing? = nil
    // v9 (#1856): nobody but the ACT is named on this show, so there is no producing organisation to
    // research and the act itself is the only party to try.
    //
    // Measured on the live store 2026-07-31: 93 open rows are in this state, 63 of them at one cabaret
    // room. Every venue in the list rents itself out and books a different act a night, so the listing
    // names the room and names the act and never says who is producing. Overture refuses to treat the room
    // as the producer (#1787), which is right, and left the check with no target at all: the run fell
    // through to the act waterfall against an organisation that does not exist, found nothing, and
    // reported `nothing_published`, a claim it never tested.
    //
    // A plain fact about THIS show rather than the `presenterWasTheRoom` flag behind it (Dan's scope call,
    // 2026-07-31): the flag is only written by scouts newer than #1787, and 15 of the 93 predate it or came
    // from pages that named nobody, while being every bit as organiser-less. The run needs to know it has
    // no producer to find, not why.
    var onlyTheActIsNamed: Bool? = nil
    // v10 (#1887): how well Dan already knows THIS room, as one of `shot_before` / `a_few` /
    // `regularly`, and NEVER a number.
    //
    // The band is the whole payload on purpose. Dan's rule is "never an exact number", and a rule
    // that lives only in the prompt is a hope (L27): the way to stop the drafter stating a count
    // is to leave it nothing to state. The count itself never leaves `VenueShootHistory`.
    //
    // Absent means SAY NOTHING, and the runbook is told so explicitly. Three different situations
    // produce an absent field and none of them licenses a guess: the app has no history for the
    // room, no history has been imported at all, or the show is at Carnegie Hall, where the tenure
    // credential the runbook already requires is about that exact room and a venue line beside it
    // would be one fact stated twice (Dan's call, 2026-07-31).
    var venueHistory: String? = nil
    // v11 (#2259): the producing company this show's own listing page credits in front of its title, read
    // by the app from `showListing.text`.
    //
    // `onlyTheActIsNamed` says one thing (the stored presenter field is empty) and the runbook restated it
    // as a much bigger one ("this listing named no producing organisation at all"). On ICB Productions'
    // "Summer Lovin'" the bigger claim was false: the page's own title line named the company, twice, and
    // the run was told there was nothing there to find. It spent eleven web calls on two individuals and
    // Dan's card read "No email found".
    //
    // Present means the app READ a credit off the page, and that organisation is a legitimate
    // `provenance: "presenter"` target running the full waterfall. Absent means the app's narrow parse
    // found none, which is NOT "the page names nobody": the run still reads the text itself, where a
    // founder's own company is often named in a bio the parse deliberately will not touch.
    var organisationNamedOnListing: String? = nil
    // v12 (#2392): addresses Dan has STRUCK on this show. Do not research them, do not write to them, and
    // do not report them back as contacts.
    //
    // They are here because the removal is meant to stop the run SPENDING on an address he already knew
    // was wrong, not merely to drop what it brings home. Dan's report was a card reading "10 found, 4
    // reachable" over three personal gmail accounts and the act's own domain: he could see at a glance
    // which were useless, and the only control anywhere was in the draft-review panel, after the run had
    // been paid for.
    //
    // The app refuses them again at INGEST regardless (PrepImporter reads the same refusal record), so a
    // run that ignores this field costs money rather than putting somebody back on Dan's card. Both
    // halves are wanted: a rule that lives only in a prompt is a hope (L27).
    //
    // ABSENT on the overwhelming majority of items and deliberately not an empty array, so the run is not
    // asked to reason about a list that is almost always nothing.
    var refusedEmails: [String]? = nil
}

// What the app read at a show's own listing URL, handed to the Prep run as material for the draft.
//
// Deliberately just the page's readable TEXT, not an app-side attempt to pick "the description" out of
// it. Roughly a third of the store's listing URLs point at a calendar or a season index rather than one
// show's own page, and no heuristic here can tell the difference reliably; the run has the show's name,
// date and venue in front of it and can. So the app answers the one question it CAN answer (could this
// page be read at all) and leaves the judgment to the reader that has the context.
struct ShowListing: Codable, Equatable, Sendable {
    // "read" (text present) or "unreadable" (the page did not load, or carried nothing to read). Two raw
    // strings rather than an enum, matching every other wire vocabulary in this file (`production`,
    // `reprepMode`, `experimentArmInstruction`).
    var status: String
    var url: String
    var text: String? = nil
    // Set only when the page was longer than `ShowListingReader.textLimit` and had to be cut, so a
    // description that fell past the cut is never reported as a page that published none (L11: a message
    // may claim only what its check actually measured). Absent means the whole page is here.
    var truncated: Bool? = nil

    static let read = "read"
    static let unreadable = "unreadable"
}

// #1666: the five facts the Prep-eligibility rule reads. A Prospect carries them and so does the queue
// card's snapshot of one, so both can be handed to the SAME function instead of a surface spelling the
// arguments out again. Spelled out is how the card came to promise a Prep run on a show Prep refuses:
// #1534's "Contact: pending Prep run" was keyed on `isKept`, which is not what decides it. A new fact
// added to `needsPrep` now has to be added here too, and every conformer fails to compile until it is.
protocol PrepEligibilityFacts {
    var status: ReviewStatus { get }
    var hasDraft: Bool { get }
    var reprepDraftRequested: Bool { get }
    var reprepContactsRequested: Bool { get }
    var hasUnclearedConflict: Bool { get }
}

extension Prospect: PrepEligibilityFacts {}

// #1666: what the next Prep run will do with ONE show, as one answer. Two rules decide it and a surface
// stating it has to obey both: `needsPrep` refuses a show with an open date conflict outright, and
// `prepMode` downgrades a show whose contact a reachability probe already found to writing the draft
// alone. Anything telling Dan what happens to a show next asks this rather than deriving it again.
enum PrepRunIntent: Equatable, Sendable {
    // The next run will not take this show up at all: it is untriaged, dismissed, already drafted with
    // no re-prep asked for, or kept on a night Dan cannot work.
    case notQueued
    // The full prep: research a contact, then write the email.
    case contactsAndDraft
    // A contact is already in hand, so only the email is written.
    case draftOnly
    // The email stands, only the contact is researched again.
    case contactsOnly
}

enum PrepQueueBuilder {
    static let version = 12

    // #1666: the wire vocabulary of a queue item's `reprepMode` (#367), named rather than written out at
    // each use, so the string that crosses to the run and the string a surface reads back are one spelling.
    static let draftOnlyMode = "draft_only"
    static let contactsOnlyMode = "contacts_only"

    // v4 (#1122): true when `performanceDate` (the opening night) is behind us AND the run is still live
    // (its closing night, runEndDate ?? performanceDate, is today or later). A fully past run is false
    // (no dates remain to pitch), and so is a single-night show whatever its date, since there is no
    // "opening passed but later dates remain" case for one night. Judged through the same closing-night
    // helper the queue label and filter use (EasternDate.runLastNight/runHasPassed), so all three agree.
    static func openingNightPassed(performanceDate: String?, runEndDate: String?, today: String) -> Bool {
        let lastNight = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: performanceDate)
        guard !EasternDate.runHasPassed(lastNight: lastNight, today: today) else { return false }
        guard let performanceDate else { return false }
        return performanceDate < today
    }

    // A prospect is "to prep" when Dan kept it (.queued) and it has no draft yet, OR (#367) he
    // explicitly asked for a re-prep on a prospect that already has one, restricted to statuses
    // that still make sense to redraft/re-research (never .contacted or .dismissed). This is the
    // single source of truth every other eligibility check below should call, plain-Swift call
    // sites can call this function directly; the one SwiftData #Predicate-driven @Query
    // (RootView's "Prep kept" button gate) can't call an arbitrary function from inside a
    // #Predicate macro, so needsPrepPredicate below expresses the SAME logic as a standalone
    // Predicate value and PrepQueueEligibilityParityTests pins the two never drifting apart.
    // `hasUnclearedConflict` is deliberately NOT defaulted, and it is the only argument here that isn't.
    //
    // Defaulted, it was silently wrong the moment it shipped: StageNavigation called this without it, so
    // the Prep pill counted a show Dan is booked against and took him to it, while the Prep run refused to
    // draft it. That is exactly #863 (a pill's number is a promise about rows), reappearing in a new place
    // through a default value that made forgetting invisible. Required, forgetting it is a compile error.
    static func needsPrep(status: ReviewStatus, hasDraft: Bool,
                          reprepDraftRequested: Bool = false,
                          reprepContactsRequested: Bool = false,
                          hasUnclearedConflict: Bool) -> Bool {
        // #901: a show on a day Dan cannot work is not drafted until he says he can work it. Not a drop
        // (he still sees it, flagged, and decides), but no contacts are researched and no email is
        // written for a night he is already booked or away for: that is his money and the model's time
        // spent on a show that cannot happen.
        if hasUnclearedConflict { return false }
        if status == .queued && !hasDraft { return true }
        let reprepEligible = status == .queued || status == .drafted || status == .approved
        return reprepEligible && (reprepDraftRequested || reprepContactsRequested)
    }

    // A (Prospect) -> Bool wrapper over needsPrep, for passing straight to `.filter(...)` instead
    // of a closure with named arguments and defaults (the latter is slow enough for the Swift
    // type-checker to warn about in a plain-array `.filter { ... }`, this form checks instantly).
    // #1666: generic over PrepEligibilityFacts rather than over Prospect alone, so the queue card's
    // snapshot reaches this exact function instead of restating its arguments. Behaviour for a Prospect
    // is unchanged; every existing call site still passes one.
    static func needsPrepEligible<Facts: PrepEligibilityFacts>(_ p: Facts) -> Bool {
        needsPrep(status: p.status, hasDraft: p.hasDraft,
                 reprepDraftRequested: p.reprepDraftRequested,
                 reprepContactsRequested: p.reprepContactsRequested,
                 hasUnclearedConflict: p.hasUnclearedConflict)
    }

    // #1666: whether a reachability probe has already found this show a contact, which is the fact
    // `prepMode` reads to decide a first prep can skip the hunt. One definition, because the queue card
    // and the service that writes the handoff file both have to reach the same answer, and each spelling
    // it out would be two copies of one rule (which is the whole shape of this issue).
    static func probedWithContact(probedAt: Date?, contactEmails: [String?]) -> Bool {
        probedAt != nil && contactEmails.contains { !($0 ?? "").isEmpty }
    }

    // #1666: the one accessor a surface asks for "what happens to this show at the next Prep run".
    // Composed of the two rules that decide it, never a third statement of either: `needsPrepEligible`
    // says whether the run takes the show up at all (the conflict gate included), and `prepMode` says
    // which half of the work it does. `probedWithContact` is not defaulted, for the same reason
    // `needsPrep`'s conflict gate is not: a default is how a caller forgets a gate invisibly.
    static func nextRunIntent<Facts: PrepEligibilityFacts>(for p: Facts,
                                                           probedWithContact: Bool) -> PrepRunIntent {
        guard needsPrepEligible(p) else { return .notQueued }
        switch prepMode(hasDraft: p.hasDraft,
                        reprepDraftRequested: p.reprepDraftRequested,
                        reprepContactsRequested: p.reprepContactsRequested,
                        probedWithContact: probedWithContact) {
        case draftOnlyMode: return .draftOnly
        case contactsOnlyMode: return .contactsOnly
        default: return .contactsAndDraft
        }
    }

    // #1583/#1691: the same question with the date-clash gate lifted, which is what the `.prepBlocked`
    // stage needs to ask ("would this show be prep work if Dan were free that night?").
    //
    // It goes through `needsPrep` rather than restating the status-and-draft rule, so `.prep` and
    // `.prepBlocked` cannot drift into disagreeing about which shows are prep work at all. Passing the gate
    // `false` is not the same as defaulting it: the argument is still spelled out at the one call site that
    // deliberately ignores it, and every other caller is still forced to supply the real value.
    static func needsPrepIgnoringConflict(_ p: Prospect) -> Bool {
        needsPrep(status: p.status, hasDraft: p.hasDraft,
                 reprepDraftRequested: p.reprepDraftRequested,
                 reprepContactsRequested: p.reprepContactsRequested,
                 hasUnclearedConflict: false)
    }

    // #2365: which kept prospects a Prep run defaults to covering, which is now ALL of them.
    //
    // Dan's rule, 2026-08-11: "I don't think prep needs to worry about filtering out. Scout should be
    // solely responsible for filtering out based on how far away it is. If it gets to prep I want to be
    // able to prep it."
    //
    // The argument for that is his design rather than a simplification: Scout is the one surface that
    // applies a lead time window, so a show can only have REACHED this list by Dan deliberately keeping
    // it, and a second date rule here would second-guess a decision he already made. It also ends a real
    // disagreement, since triage cut at 90 days while this defaulted at four whole months, so a show 100
    // days out was refused for triage and would have defaulted into a run.
    //
    // Kept as a named function returning the keys rather than inlined in the sheet, so the rule (even now
    // that it is "every one") has a seam a test can reach and the view holds no rule of its own (#863).
    static func prepDefaultSelection(prospects: [Prospect]) -> Set<String> {
        Set(prospects.map(\.naturalKey))
    }

    // The #Predicate mirror of needsPrep above, for the one call site (RootView's toPrep @Query)
    // that needs a compiled SwiftData predicate rather than a plain Swift function. Kept as a
    // single named, shared value so there is exactly one place this expression lives, not one
    // reinvented inline in RootView.swift.
    static var needsPrepPredicate: Predicate<Prospect> {
        #Predicate<Prospect> { p in
            // #901: the conflict gate. It reads the SAME stored column Prospect.hasUnclearedConflict
            // does, rather than re-deriving the rule from the two keys, which is both why it is trivial
            // here and why it cannot drift from the plain-Swift function above. (Expressed inline from
            // the keys, it overran the #Predicate type-checker outright; see Prospect.conflictOpen.)
            !p.conflictOpen
            && ((p.statusRaw == "queued" && p.draftBody == nil)
                || ((p.reprepDraftRequested || p.reprepContactsRequested)
                    && (p.statusRaw == "queued" || p.statusRaw == "drafted" || p.statusRaw == "approved")))
        }
    }

    // #367: the wire value for a queue item's reprepMode, derived from the prospect's two
    // independent flags. Both true (a "both" request) or both false (a normal, never-drafted
    // prospect) both mean "do both", so both collapse to nil, exactly as an absent field always
    // has: the run's default behavior.
    static func reprepModeString(draftRequested: Bool, contactsRequested: Bool) -> String? {
        switch (draftRequested, contactsRequested) {
        case (true, false): return draftOnlyMode
        case (false, true): return contactsOnlyMode
        default: return nil
        }
    }

    // #1308 Layer 2 Phase 4: which half of a prep to run for this item. An explicit Dan re-prep wins (that
    // is a deliberate request). Otherwise, a first prep of a show whose contact a reachability probe already
    // found skips the hunt (draft_only) and only drafts, so the expensive contact research is paid once, at
    // the probe. A never-probed show, or one the probe found no contact for, still does the full prep (nil).
    static func prepMode(hasDraft: Bool, reprepDraftRequested: Bool, reprepContactsRequested: Bool,
                         probedWithContact: Bool) -> String? {
        if reprepDraftRequested || reprepContactsRequested {
            return reprepModeString(draftRequested: reprepDraftRequested, contactsRequested: reprepContactsRequested)
        }
        if !hasDraft && probedWithContact { return draftOnlyMode }
        return nil
    }

    // `houses` is deliberately NOT defaulted, and it is the only argument here without a default, for the
    // same reason `needsPrep`'s conflict gate is not: a defaulted empty set is exactly how the producer
    // gate's promotion override spent months looking wired while every call site quietly passed nothing
    // (#1679). Required, forgetting it is a compile error rather than a silently house-less run that sends
    // the model hunting the building's own inbox.
    static func build(from prospects: [PrepQueueItem], generatedAt: String,
                      houses: [ProducerGate.House]) -> PrepQueue {
        PrepQueue(version: version, generatedAt: generatedAt, items: prospects, houses: houses)
    }

    // #1824: put each show's own listing text onto its item, matched by `naturalKey` (the opaque token,
    // never rebuilt). An item with no answer keeps none, which is the "there was no page to read" state and
    // is deliberately different from an `unreadable` one. Pure, and held out of the service, so the join
    // itself is directly testable rather than only observable through a written file.
    static func attaching(_ listings: [String: ShowListing], to queue: PrepQueue) -> PrepQueue {
        var out = queue
        out.items = queue.items.map { item in
            var copy = item
            copy.showListing = listings[item.naturalKey]
            // #2259: read the page's own credit in the SAME step that attaches the page, so a listing can
            // never reach the run with a company named on it and nothing said about that company. The
            // parse is the app's (deterministic, free, and testable against the stored text), not a
            // sentence of runbook the run is trusted to obey.
            copy.organisationNamedOnListing = ListingOrganiser.producerNamed(
                inListingText: copy.showListing?.text,
                showTitle: item.groupName,
                venue: item.venue)
            return copy
        }
        return out
    }

    static func encode(_ queue: PrepQueue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(queue)
    }

    static var defaultURL: URL {
        RunSlot.prep.queueURL(in: StoreLocation.handoffDirectory)
    }
}
