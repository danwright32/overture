import Testing
import Foundation
import SwiftData

// #2229: correcting a source's address left the OLD page's facts on the row.
//
// `editURL` has always said what it intends, in its own comment: "a corrected URL is a BRAND-NEW source
// for reconcile". It carried that out with a hand-written list of field assignments, and the model grew
// past the list. This is L38's shape, touching N minus 1 of N linked things, and it was measured on the
// live store rather than imagined: `theplayerstheatre-com` was watched at an OvationTix address while
// still carrying kind `html`, 147 structural gaps, and a stored run note whose text described the
// theplayerstheatre.com HTML it no longer fetches.
//
// Three consequences, one per group of tests below: the source loses the free native adapter its new
// address routes to, the sheet describes a page it no longer watches, and its read history claims a
// currency it does not have. The last suite is the guard for the CLASS, so the next field added to
// WatchedSource cannot be forgotten here the way these were.
@MainActor
@Suite("Correcting a source's address (#2229)")
struct AddressCorrectionTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ kind: SourceKind = .html,
                        at url: String = "https://old.example/events") -> WatchedSource {
        WatchedSource(sourceId: "theplayerstheatre-com", orgName: "The Players Theatre",
                      listingsURL: url, kind: kind)
    }

    // MARK: - The kind must follow the address

    // The live case. Dan repointed The Players Theatre at the OvationTix calendar its own page was a front
    // for. `SourceKind.usesNativeExtractor` is what decides whether a source is parsed natively and free on
    // every run or handed to the paid extract run, and `SourceExtractorRegistry` returns nil for `.html`,
    // so the row stayed on the paid path indefinitely AND never had `venueName` / `venueLocation` threaded
    // into its shows. The add path has always derived this (`SourceKind.forListingURL`); only the edit path
    // did not.
    @Test func anAddressCorrectedOntoATicketingHostRoutesToThatFeedsNativeAdapter() throws {
        let ctx = try context()
        let s = source()
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://web.ovationtix.com/trs/cal/277", in: ctx)

        #expect(s.kind == .ovationTixFeed)
        #expect(s.usesNativeExtractor)
    }

    @Test func anAddressCorrectedOntoAVenueTixHostRoutesToThatFeedsNativeAdapter() throws {
        let ctx = try context()
        let s = source()
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://greenroom42.venuetix.com/", in: ctx)

        #expect(s.kind == .venueTixFeed)
    }

    // The other direction has to work too, or a source repointed AWAY from a feed keeps claiming a native
    // adapter that cannot read its new page.
    @Test func anAddressCorrectedAwayFromAFeedHostReturnsToTheReadPath() throws {
        let ctx = try context()
        let s = source(.ovationTixFeed, at: "https://web.ovationtix.com/trs/cal/277")
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://theplayerstheatre.com/events", in: ctx)

        #expect(s.kind == .html)
    }

    // #1450: Carnegie's listings URL is a display-only placeholder over a POST search API, so its kind is
    // seeded by hand and must never be rewritten from a URL. `hasEditablePage` keeps the UI away from this
    // path today, but the rule belongs where the rewrite happens rather than resting on a caller.
    @Test func carnegiesKindIsNeverRewrittenFromAnAddress() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "carnegiehall-org", orgName: "Carnegie Hall",
                              listingsURL: "https://www.carnegiehall.org/Calendar", kind: .algolia)
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://web.ovationtix.com/trs/cal/277", in: ctx)

        #expect(s.kind == .algolia)
    }

    // #1503: `.squarespaceFeed` is assigned by a CONTENT probe and `forListingURL` cannot return it, so a
    // correction demotes it to `.html`. That is correct rather than a regression: the new address may not
    // be Squarespace at all, and `ScoutService.promoteToSquarespaceIfEventsCollection` re-probes any
    // `.html` source on its next check, so a page that still is one is promoted straight back.
    @Test func aSquarespaceSourceIsDemotedToTheReadPathAndLetsTheProbePromoteItAgain() throws {
        let ctx = try context()
        let s = source(.squarespaceFeed, at: "https://old.example/events")
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://new.example/events", in: ctx)

        #expect(s.kind == .html)
    }

    // MARK: - The sheet must not describe a page this source no longer watches

    // The Dan-visible end of it. `readabilityNote` is the sentence in the Sources sheet, and it is built
    // from the drop counters. `lastReadableCount` and friends were already reset; `lastStructuralGapCount`
    // and `lastDroppedShowLabelsRaw` were not, so the row could say "147 of 147 listings named no venue,
    // so Overture left those out of the queue" and NAME two of those shows, about the old address.
    @Test func aCorrectedAddressSaysNothingAboutTheOldPagesDroppedShows() throws {
        let ctx = try context()
        let s = source()
        s.lastStructuralGapCount = 147
        s.lastDroppedShowLabels = ["Cirque du Soleil on Aug 3", "A Chorus Line on Aug 4"]
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://web.ovationtix.com/trs/cal/277", in: ctx)

        #expect(s.lastStructuralGapCount == 0)
        #expect(s.lastDroppedShowLabels.isEmpty)
        #expect(s.readabilityNote == nil)
    }

    // #986's placing history is about the old page as well: kept, the new address inherits a claim to have
    // placed shows it has never read.
    @Test func aCorrectedAddressCarriesNoPlacingHistory() throws {
        let ctx = try context()
        let s = source()
        s.lastPlacedCount = 92
        s.hadPlacedBeforeLastRun = true
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://new.example/events", in: ctx)

        #expect(s.lastPlacedCount == 0)
        #expect(!s.hadPlacedBeforeLastRun)
        #expect(!s.hasEverPlaced)
    }

    // MARK: - The read history must not claim a currency it does not have

    // #1758 made the row's largest slot say CHECKED only when something was actually read, precisely
    // because "Checked 1 hour ago" beside an org name reads as "we have current information about this
    // org". After a correction that sentence was about the previous address.
    @Test func aCorrectedAddressHasNeverBeenCheckedOrRead() throws {
        let ctx = try context()
        let s = source()
        let anHourAgo = Date(timeIntervalSince1970: 1_785_000_000)
        s.lastCheckedAt = anHourAgo
        s.lastSucceededAt = anHourAgo
        s.lastManualReadAt = anHourAgo
        s.pageCount = 4
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://new.example/events", in: ctx)

        #expect(s.lastCheckedAt == nil)
        #expect(s.lastSucceededAt == nil)
        #expect(s.lastManualReadAt == nil)
        #expect(s.pageCount == 0)
        #expect(SourceReadState.of(s) == .unreadChangesWaiting(lastRead: nil))
    }

    // The stored run note is the scout's own account of a specific page, and the live store's copy was a
    // paragraph about theplayerstheatre.com's HTML sitting on a row watched at ovationtix.com. Same for the
    // fetch observations: a hash of bytes from the old address, and an insecure-connection flag earned by a
    // host this source no longer touches.
    @Test func aCorrectedAddressCarriesNoNoteOrFetchObservationFromTheOldPage() throws {
        let ctx = try context()
        let s = source()
        s.notes = "This pinned page is a synthesized OvationTix ticketing-widget feed, NOT the raw HTML."
        s.lastObservedContentHash = "old-bytes"
        s.lastFetchWasInsecure = true
        s.pendingPageMonths = ["2026-08", "2026-09"]
        s.ticketingFeedURL = "https://web.ovationtix.com/trs/cal/277"
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://new.example/events", in: ctx)

        #expect(s.notes == nil)
        #expect(s.runNote == nil)
        #expect(s.lastObservedContentHash == nil)
        #expect(!s.lastFetchWasInsecure)
        #expect(s.pendingPageMonths.isEmpty)
        #expect(s.ticketingFeedURL == nil)
    }

    // MARK: - What must SURVIVE a correction

    // L5: never destroy good state. `venueName` and `venueLocation` are Dan's own assertions, not machine
    // facts about a page, and silently discarding an answer he typed is a different defect from the one
    // this issue fixes. Consent outranks everything (#800), and the client tag and merge rule are likewise
    // his answers about the ORG rather than about the page.
    @Test func aCorrectionKeepsEveryAnswerDanGaveHimself() throws {
        let ctx = try context()
        let s = source()
        s.venueName = "The Players Theatre"
        s.venueLocation = "115 MacDougal St, New York, NY"
        s.clientTagOverride = true
        s.clientTagClientId = "downbeat-42"
        s.mergeSameDateVenue = true
        let added = s.addedAt
        ctx.insert(s)
        try ctx.save()

        WatchlistEditing.editURL(s, to: "https://new.example/events", in: ctx)

        #expect(s.venueName == "The Players Theatre")
        #expect(s.venueLocation == "115 MacDougal St, New York, NY")
        #expect(s.clientTagOverride == true)
        #expect(s.clientTagClientId == "downbeat-42")
        #expect(s.mergeSameDateVenue)
        #expect(s.sourceId == "theplayerstheatre-com")   // stamped on every prospect the old page produced
        #expect(s.orgName == "The Players Theatre")
        #expect(s.addedAt == added)
    }

    // MARK: - The guard for the class

    // The whole defect is that the reset is a hand-maintained list beside a growing model, so a test that
    // only checks today's missing fields fixes the instance and leaves the class (L30). This fails when a
    // stored property is added to WatchedSource and is neither cleared by the correction nor named below as
    // deliberately surviving it.
    //
    // Seen to fail (L1): with `lastStructuralGapCount` removed from the clearing function, this reports it
    // by name rather than passing.
    @Test func everyStoredPropertyIsEitherClearedByACorrectionOrNamedAsSurviving() throws {
        let model = SourceGuardHelper.source("Overture/Domain/WatchedSource.swift")
        let editing = SourceGuardHelper.source("Overture/Domain/WatchlistEditing.swift")

        let classBody = try #require(SourceGuardHelper.propertyBody("final class WatchedSource {", in: model),
                                     "WatchedSource's class body could not be read")
        let cleared = try #require(
            SourceGuardHelper.bodyOfFunction(named: "clearStateDerivedFromTheWatchedPage", in: editing),
            "the correction's clearing function could not be found: it is what this guard measures")

        let unaccounted = storedProperties(in: classBody).filter { name in
            !survivesACorrection.keys.contains(name) && !cleared.contains("source.\(name)")
        }

        #expect(unaccounted.isEmpty, """
            \(unaccounted.joined(separator: ", ")): \
            neither cleared when a source's address is corrected nor listed in `survivesACorrection`.
            A corrected URL is a brand-new source for reconcile (#1027), so anything derived from the page
            it used to watch has to go. If the field is genuinely Dan's own answer or the row's identity,
            add it to that list with the reason.
            """)
    }

    // Named, with the reason, so the decision to keep each one is recorded rather than implied by absence.
    private let survivesACorrection: [String: String] = [
        "sourceId": "stamped on every prospect the old page ever produced (#1027)",
        "orgName": "who this is, not what page they publish at",
        "listingsURL": "the correction itself sets it",
        "kindRaw": "re-derived from the new address rather than cleared",
        "isActive": "consent, never a health signal (#800)",
        "inactiveReasonRaw": "consent, never a health signal (#800)",
        "addedAt": "when Dan started watching this org, unchanged by repointing it",
        // #2211: the STREAK is cleared by the correction (a run of empties is about the old page), but the
        // date survives. It answers "when did this org last list a show", which stays true whatever
        // address Overture reads them at, and zeroing it would make a corrected source claim it had never
        // listed anything, which is a stronger and falser statement than the one the correction fixed.
        "lastNonEmptyAt": "when this ORG last listed a show, still true at a new address",
        "venueLocation": "Dan's own answer (#1175), not a fact about the page",
        "venueName": "Dan's own answer (#1529), not a fact about the page",
        "clientTagOverride": "Dan's answer about the ORG (#1209)",
        "clientTagClientId": "Dan's answer about the ORG (#1358)",
        "mergeSameDateVenue": "Dan's answer about how the ORG lists concerts (#1236)",
        "hasUnreadChanges": "set TRUE by the correction so the next scout reads the new page",
        "healthRaw": "set to neverChecked by the correction: it has not been checked at this address",
    ]

    // A stored property, as opposed to a computed one. The distinction is exactly whether the declaration
    // carries a body, so that is what is measured rather than a list of names to keep in step.
    //
    // The test is "contains a brace", not "ends in one": WatchedSource writes both shapes, and a one-line
    // computed property (`var hasEverPlaced: Bool { hadPlacedBeforeLastRun || lastPlacedCount > 0 }`) ends
    // in a CLOSE brace. Reading only the last character reported six computed properties as unaccounted
    // stored ones on this guard's first real run.
    // #2009: the shared reading, so this guard and the outreach-field one cannot drift into two
    // definitions of "a stored property" (L26).
    private func storedProperties(in classBody: String) -> [String] {
        SourceGuardHelper.storedPropertyNames(inClassBody: classBody)
    }
}
