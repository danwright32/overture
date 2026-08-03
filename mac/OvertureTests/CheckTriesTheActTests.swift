import Testing
import Foundation
import SwiftData

// #1856: a contact check on a show whose only named party is the ACT has to go looking for the act.
//
// Dan, 2026-07-30, looking at the cards a check gives up on: "It should try the act directly. If I check
// reachability I'd want it to find the acts email".
//
// LIVE-STORE-CLAIM verified=2026-07-31 measure="open rows with no presenter and no contact check on file, by venue, and their listing hosts"
// 93 open rows have no presenter at all: The Green Room 42 (63), SoHo Playhouse (7), Jalopy Theatre (7),
// Roulette Intermedium (6), Under St Marks (5), and 5 more across four venues. Every one of those rooms
// rents itself out and books a different act every night, so the listing names the room and names the act
// and never says who is producing. 63 of the 93 listings are `thegreenroom42.venuetix.com` pages.
//
// Two separate things kept the check from ever looking:
//
// 1. THE INSTRUCTION. `docs/prep-runbook.md` §1 opens its named-performer route only when
//    `production == "self"`, and these shows are `unknown` (166 of the 169 flagged rows). So the run fell
//    through to hunting a producing organisation that does not exist, found nothing, and reported
//    `nothing_published`: a claim it never tested (L11).
// 2. THE CAPABILITY. Where the show is billed as a title ("Broadway's Bad Guys!") rather than a person
//    ("Delaney Brown"), the act's name is only on the listing page, and a VenueTix page is drawn by
//    JavaScript. #1824 gave the app the ability to render one and hand the text over, but only on a Prep
//    run, because only a draft was thought to need it.
//
// Dan's scope call, 2026-07-31: all 93, not only the 78 where Overture measured that it removed the room's
// own name. The evidence the queue carries is therefore "no organiser was named on this show at all",
// which is true of every one of them and needs no flag written by a later scout.
@MainActor
@Suite("A contact check tries the act when nobody else is named (#1856)")
struct CheckTriesTheActTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, PromotedProducer.self, DemotedHouse.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, group: String, presenter: String?,
                        venue: String = "The Green Room 42",
                        listing: String? = "https://thegreenroom42.venuetix.com/showdetails/1/2") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-11", venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: "2026-09-11", sourceListingURL: listing,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func tmp(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func listingPage() -> String {
        "<html><body><script>boot();</script><h2>About the Show</h2>"
        + "<p>An evening of new songs, hosted by Delaney Brown with Miggie Snyder.</p></body></html>"
    }

    // The fact the run needs, in the file the run actually opens. Without it the check cannot tell one of
    // these shows from any other, and #1679 is this repo's standing proof that a rule whose evidence never
    // reaches its consumer looks shipped and does nothing.
    @Test func theCheckIsToldWhenNoOrganiserWasNamed() throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Broadway's Bad Guys!", presenter: nil)

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [p.naturalKey])

        #expect(queue.items.count == 1)
        #expect(queue.items[0].onlyTheActIsNamed == true)
    }

    // THE FAILURE DIRECTION. A show at the very same rental room that DOES name a producer is untouched:
    // the check still aims at that producer, which is the whole reason #1817's gate exists.
    @Test func aShowThatNamesAProducerIsNotSentAtTheAct() throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Gotta Sing", presenter: "Ridgeline Productions")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [p.naturalKey])

        #expect(queue.items[0].onlyTheActIsNamed != true)
    }

    // A presenter that is only whitespace is not a presenter. The extraction guard writes an empty string
    // rather than nil when it drains a room's own name (#1787), so a nil-only test would pass while the
    // commonest real row in this class stayed shut out.
    @Test func aBlankPresenterCountsAsNoOrganiser() throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Echoes of Home", presenter: "   ")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [p.naturalKey])

        #expect(queue.items[0].onlyTheActIsNamed == true)
    }

    // The capability half. On a title-billed show the act's name exists nowhere but the listing page, and
    // 63 of the 93 are JavaScript-drawn VenueTix pages the run cannot read for itself (its browser tool is
    // denied by its own scope). So the app renders it and hands the text over, exactly as a Prep run does.
    @Test func theCheckIsHandedTheShowPageWhenItHasToFindTheAct() async throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Broadway's Bad Guys!", presenter: nil)
        let queueURL = tmp("q"), markerURL = tmp("m"), probeURL = tmp("p")
        defer { for u in [queueURL, markerURL, probeURL] { try? FileManager.default.removeItem(at: u) } }

        _ = try await PrepQueueService.startReachabilityProbe(
            keys: [p.naturalKey], from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
            probeRunURL: probeURL, render: { _ in self.listingPage() }, launch: {})

        let queue = try JSONDecoder().decode(PrepQueue.self, from: try Data(contentsOf: queueURL))
        #expect(queue.items[0].showListing?.status == ShowListing.read)
        #expect(queue.items[0].showListing?.text?.contains("Delaney Brown") == true)
    }

    // And it spends that render ONLY where it changes the answer. A show that already names its producer
    // has a target without reading anything, so paying seconds of Dan's launch per show there would be the
    // cost #1824 deliberately kept off this path.
    @Test func aCheckOnAShowWithAProducerStillSpendsNoRenders() async throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Gotta Sing", presenter: "Ridgeline Productions")
        let queueURL = tmp("q"), markerURL = tmp("m"), probeURL = tmp("p")
        defer { for u in [queueURL, markerURL, probeURL] { try? FileManager.default.removeItem(at: u) } }

        _ = try await PrepQueueService.startReachabilityProbe(
            keys: [p.naturalKey], from: ctx, now: Date(), queueURL: queueURL, markerURL: markerURL,
            probeRunURL: probeURL, render: { _ in self.listingPage() }, launch: {})

        let queue = try JSONDecoder().decode(PrepQueue.self, from: try Data(contentsOf: queueURL))
        #expect(queue.items[0].showListing == nil)
    }

    // The launch renders pages before the run starts, which takes real seconds. CLAUDE.md's standing rule:
    // a slow action must make working, still alive, and failed visibly different, so the check reports how
    // far along it is rather than sitting on an indefinite spinner.
    @Test func theCheckReportsHowManyShowPagesItHasRead() async throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Broadway's Bad Guys!", presenter: nil)
        let b = insert(ctx, group: "Echoes of Home", presenter: nil)
        let queueURL = tmp("q"), markerURL = tmp("m"), probeURL = tmp("p")
        defer { for u in [queueURL, markerURL, probeURL] { try? FileManager.default.removeItem(at: u) } }

        let seen = ProgressLog()
        _ = try await PrepQueueService.startReachabilityProbe(
            keys: [a.naturalKey, b.naturalKey], from: ctx, now: Date(), queueURL: queueURL,
            markerURL: markerURL, probeRunURL: probeURL, render: { _ in self.listingPage() },
            onListingProgress: { done, total in seen.record(done, total) }, launch: {})

        #expect(seen.totals.allSatisfy { $0 == 2 })
        #expect(seen.done.last == 2)
    }

    // Dan's call, 2026-07-31: "I don't need the badge to say try the act directly. it should just say hard
    // to reach if it's a generic inbox, email found if it found one or no email found". So the advice
    // #1795 added yesterday comes back off the card. The check still changes; the card just stops giving
    // instructions it cannot carry out itself.
    @Test func theCardGivesNoAdviceAboutTheActBeforeACheck() {
        // Read through the row the card actually draws, not the pure function beside it: the flag that
        // used to turn the advice on lives on the item, so a test that could not set it would go green
        // without touching the behaviour being removed.
        var flagged = queueItem(group: "Broadway's Bad Guys!")
        flagged.presenterWasTheRoom = true
        var unflagged = queueItem(group: "Echoes of Home")
        unflagged.presenterWasTheRoom = false

        // #1859 then took the "Hard to reach" verdict off these rows too, so what the card says about
        // them now is nothing at all, until a check has actually looked.
        #expect(flagged.reachabilityBadge() == .none)
        #expect(unflagged.reachabilityBadge() == .none)
    }

    private func queueItem(group: String) -> QueueItem {
        var i = QueueItem(id: group, groupName: group, discipline: "music",
                          venue: "The Green Room 42", performanceDate: "2026-09-11",
                          sourceListingURL: "https://thegreenroom42.venuetix.com/showdetails/1/2",
                          websiteURL: nil, priorRelationship: "none", production: "unknown",
                          profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                          fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                          possibleMatchName: nil, status: .new)
        i.presenter = nil
        return i
    }

    // The deterministic half of the runbook's own rule (L27): a contact may claim to be verified only when
    // it names the page it was read off. The rule has always been in the prompt ("only ever meaningful
    // when confidence == high") and nothing enforced it, which matters far more now the run is aimed at a
    // show TITLE and can land on an unrelated organisation of the same name.
    //
    // Measured on the live store 2026-07-31 before shipping it: 33 recipients are high with a source page,
    // 2 are high without one, so this downgrades two rows rather than repainting the queue.
    @Test func aFindThatNamesNoPageItWasReadFromIsNotAVerifiedFind() {
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: nil) == "low")
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: "  ") == "low")
    }

    // And the direction that must NOT change: a find that does name its page keeps its confidence, as do
    // the weaker grades, which never claimed a page in the first place.
    @Test func aFindThatNamesItsPageKeepsItsConfidence() {
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: "https://act.example/contact")
                == "high")
        #expect(ContactConfidenceGuard.confidence(raw: "medium", sourceURL: nil) == "medium")
        #expect(ContactConfidenceGuard.confidence(raw: "low", sourceURL: nil) == "low")
        #expect(ContactConfidenceGuard.confidence(raw: nil, sourceURL: nil) == nil)
    }

    // The guard where it actually runs: an ingested contact, not just the pure function beside it. A guard
    // and its wiring are two claims, and this repo has shipped the first without the second before.
    @Test func theGuardRunsOnAContactTheCheckBringsBack() throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Echoes of Home", presenter: nil)

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                       contacts: [PrepContact(name: "Echoes of Home", role: nil,
                                              email: "hello@echoesofhome.example",
                                              method: "generic_inbox", confidence: "high",
                                              formUrl: nil, provenance: "act", sourceUrl: nil)],
                       draft: nil)
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: Date(), isProbe: true)

        #expect(p.recipients.count == 1)
        #expect(p.recipients[0].contactConfidenceRaw == "low")
    }

    @MainActor private final class ProgressLog {
        var done: [Int] = []
        var totals: [Int] = []
        func record(_ d: Int, _ t: Int) { done.append(d); totals.append(t) }
    }
}
