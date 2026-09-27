import Testing
import Foundation
import SwiftData

// #4275: a scout landing reads the stored shows ONCE and keeps that working set current as each source
// lands (`ScoutLandingStore`), instead of fetching the whole table twice per source and once more per event
// reaching the run URL arm.
//
// The trap this suite exists for is a STALE working set. A later source's judgements have to see what an
// earlier source in the same landing wrote: the row it inserted, and the title it rewrote. Each scenario
// below is built so a stale set gives a DIFFERENT answer from a fresh read, and is checked two ways:
//
//   - against the answer the rule gives, written out (how many rows, which one re-keyed), and
//   - against the same landing run with `.everyRead`, which answers every question with a fresh fetch and a
//     fresh fold exactly as the code did before #4275, compared field by field over every stored row.
//
// Landed the way both callers land (`runScout`, `ScoutExtractIngest.ingest`): one `apply` per source, in
// order, sharing one working set, with nothing awaited between them.
@MainActor
@Suite("A scout landing judges every source against one current read of the store (#4275)")
struct ScoutLandingWorkingSetTests {
    private static let today = "2026-10-01"
    private static let room = "The Green Room 42"
    private static let token = "https://thegreenroom42.venuetix.com/showdetails"

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    private func stored(_ ctx: ModelContext, _ title: String, _ night: String, url: String,
                        venue: String = room) {
        ctx.insert(Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                                venue: venue),
                            groupName: title, discipline: "theatre", venue: venue, performanceDate: night,
                            sourceListingURL: url, priorRelationship: "none", production: "self",
                            profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                            fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                            possibleMatchName: nil))
    }

    private func event(_ title: String, _ night: String, url: String, venue: String = room) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: venue, venue: venue, performanceDate: night, sourceUrl: url)
    }

    // The sources of one landing, in the order they land.
    private typealias Landing = [(sourceId: String, events: [ExtractedEvent])]

    @discardableResult
    private func land(_ sources: Landing, into ctx: ModelContext, policy: ScoutLandingStore.Policy,
                      read: @escaping ScoutLandingStore.Read = ScoutService.readProspectTable)
        -> [ScoutService.Outcome] {
        let landing = ScoutLandingStore(context: ctx, read: read, policy: policy)
        return sources.map { source in
            ScoutService.apply(events: source.events, clients: [], history: [], blocked: .empty,
                               today: Self.today, sourceIds: [source.sourceId], landing: landing, into: ctx)
        }
    }

    // Every stored row, as the fields a landing writes, sorted so two stores compare by content.
    private func snapshot(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Prospect>()).map { p in
            [p.naturalKey, p.groupName, p.venue ?? "-", p.performanceDate ?? "-", p.runEndDate ?? "-",
             p.runNights.joined(separator: ","), p.sourceListingURL ?? "-",
             p.runSourceURLs.joined(separator: ","), p.sourceIds.joined(separator: ","), p.seriesId ?? "-",
             p.arrivedLookingLike ?? "-", p.arrivedOnAPitchedNight ?? "-", p.tier, String(p.fitScore)]
                .joined(separator: " | ")
        }.sorted()
    }

    // Lands `sources` twice, over two identical stores built by `seed`: once through the working set, once
    // reading fresh for every question. Returns the working set's store for the scenario's own checks.
    private func landBothWays(seed: (ModelContext) -> Void, _ sources: Landing) throws -> ModelContext {
        let current = try context()
        seed(current)
        try current.save()
        land(sources, into: current, policy: .once)

        let reference = try context()
        seed(reference)
        try reference.save()
        land(sources, into: reference, policy: .everyRead)

        let got = try snapshot(current)
        let want = try snapshot(reference)
        #expect(got == want, Comment(rawValue: "the working set landed a different store from a fresh read "
                                     + "per question.\nworking set:\n\(got.joined(separator: "\n"))\n"
                                     + "fresh reads:\n\(want.joined(separator: "\n"))"))
        return current
    }

    // A ROW AN EARLIER SOURCE INSERTED is what a later source re-keys onto. Source B lists the show source A
    // just brought in, at the same link on a moved night: the run URL arm must find A's new row and move it,
    // leaving one card. A working set that never took A's insert finds nothing and mints a second card.
    @Test func aLaterSourceReKeysOntoTheRowAnEarlierSourceJustInserted() throws {
        let ctx = try landBothWays(seed: { _ in }, [
            ("source-a", [event("Alpha Quartet", "2026-10-12", url: "https://a.example/alpha")]),
            ("source-b", [event("Alpha Quartet", "2026-10-15", url: "https://a.example/alpha")]),
        ])
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, Comment(rawValue:
            "source B could not see the row source A inserted, leaving \(rows.count) cards: "
            + "\(rows.map { "\($0.groupName) \($0.performanceDate ?? "-")" }.sorted())"))
        #expect(rows.first?.performanceDate == "2026-10-15")
    }

    // A ROW AN EARLIER SOURCE INSERTED can make a token ambiguous for a later one. A stored show and the one
    // source A brings in share a venue's production token under two titles, so the token is a season stamp
    // and must join nothing. Source B then lists the stored show again under that token on a new night: a
    // set that missed A's insert sees one title, calls the token clean, and joins B onto the stored row.
    @Test func aRowAnEarlierSourceInsertedPoisonsTheTokenForALaterOne() throws {
        let ctx = try landBothWays(seed: { ctx in
            stored(ctx, "Delta Show", "2026-10-11", url: "\(Self.token)/season/2026-10-11")
        }, [
            ("source-a", [event("Epsilon Show", "2026-10-20", url: "\(Self.token)/season/2026-10-20")]),
            ("source-b", [event("Delta Show", "2026-10-25", url: "\(Self.token)/season/2026-10-25")]),
        ])
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 3, Comment(rawValue:
            "a season token joined two nights it must not: expected 3 cards, got \(rows.count) "
            + "(\(rows.map { "\($0.groupName) \($0.performanceDate ?? "-")" }.sorted()))"))
    }

    // A TITLE AN EARLIER SOURCE REWROTE is what a later source's judgements must fold. Source A renames the
    // stored show (same link, same night, a subtitle added, so the run URL arm re-keys it and takes the new
    // title). Source B then lists the OLD title under the same token: over the rewritten title the token
    // now carries two, so it joins nothing and B's show is a card of its own. A set still holding the fold
    // of the old title calls the token clean and joins B onto A's renamed row.
    @Test func aTitleAnEarlierSourceRewroteIsFoldedAfreshForALaterOne() throws {
        let ctx = try landBothWays(seed: { ctx in
            stored(ctx, "Kappa Night", "2026-10-11", url: "\(Self.token)/kappa/2026-10-11")
        }, [
            ("source-a", [event("Kappa Night: Encore", "2026-10-11", url: "\(Self.token)/kappa/2026-10-11")]),
            ("source-b", [event("Kappa Night", "2026-10-30", url: "\(Self.token)/kappa/2026-10-30")]),
        ])
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.map(\.groupName).sorted() == ["Kappa Night", "Kappa Night: Encore"], Comment(rawValue:
            "expected the renamed row and a card of its own for the old title, got "
            + "\(rows.map { "\($0.groupName) \($0.performanceDate ?? "-")" }.sorted())"))
    }

    // A ROW AN EARLIER SOURCE INSERTED can make a listing page ambiguous for a later one. Source A brings a
    // second, different show onto a page the stored show already sits on, so the page now carries two shows
    // and the URL arms must ask the strict title test there. Source B then lists the stored show with a
    // subtitle added: over an ambiguous page that is a card of its own. Stored shows walked before A landed
    // call the page unambiguous and rename the stored row onto B's billing.
    @Test func aRowAnEarlierSourceInsertedMakesAPageAmbiguousForALaterOne() throws {
        let page = "https://merkin.example/season"
        let ctx = try landBothWays(seed: { ctx in
            stored(ctx, "Zeta Trio", "2026-10-11", url: page)
        }, [
            ("source-a", [event("Eta Band", "2026-10-20", url: page)]),
            ("source-b", [event("Zeta Trio: An Evening", "2026-10-11", url: page)]),
        ])
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.map(\.groupName).sorted() == ["Eta Band", "Zeta Trio", "Zeta Trio: An Evening"],
                Comment(rawValue: "a subtitle on an ambiguous page joined a stored row: got "
                        + "\(rows.map { "\($0.groupName) \($0.performanceDate ?? "-")" }.sorted())"))
    }

    // THE SAME SOURCE, event by event. Two listings in one batch whose second re-keys onto the first's new
    // row is the in-source half of the same rule; before #4275 every arm fetched afresh per event.
    @Test func withinOneSourceALaterEventSeesAnEarlierOnesWrites() throws {
        let ctx = try landBothWays(seed: { _ in }, [
            ("source-a", [event("Beta Trio", "2026-10-12", url: "https://b.example/beta"),
                          event("Gamma Duo", "2026-10-13", url: "https://b.example/gamma")]),
            ("source-b", [event("Beta Trio", "2026-10-14", url: "https://b.example/beta"),
                          event("Gamma Duo", "2026-10-16", url: "https://b.example/gamma")]),
        ])
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2, Comment(rawValue: "expected two cards, got \(rows.count)"))
    }

    // THE FAILURE PATH. The store cannot answer while source A lands, so A is judged against nothing: its
    // new show is refused rather than inserted blind, and the run says which reads failed. A failed read is
    // not cached, so source B reads again once the store answers, lands whole, and leaves a working set that
    // is exactly what a fresh fetch returns.
    @Test func aReadThatFailsMidLandingLeavesTheWorkingSetAndStoreConsistent() throws {
        struct StoreIsDown: Error {}
        let ctx = try context()
        stored(ctx, "Delta Show", "2026-10-11", url: "https://d.example/delta")
        try ctx.save()
        var down = true
        let flaky: ScoutLandingStore.Read = { ctx in
            if down { throw StoreIsDown() }
            return try ctx.fetch(FetchDescriptor<Prospect>())
        }
        let landing = ScoutLandingStore(context: ctx, read: flaky)

        let a = ScoutService.apply(events: [event("Omega Band", "2026-10-12", url: "https://o.example/omega")],
                                   clients: [], history: [], blocked: .empty, today: Self.today,
                                   sourceIds: ["source-a"], landing: landing, into: ctx)
        #expect(a.degradedReads.contains(.productionTokenCorpus)
                && a.degradedReads.contains(.reconcileStoredShows), Comment(rawValue:
            "the failed read was not named on the run: \(a.degradedReads)"))
        #expect(a.inserted == 0 && a.storeUnreadable == 1, Comment(rawValue:
            "a show judged against an unreadable store was not refused: inserted \(a.inserted), "
            + "refused \(a.storeUnreadable)"))

        down = false
        let b = ScoutService.apply(events: [event("Sigma Choir", "2026-10-13", url: "https://s.example/sigma"),
                                            event("Delta Show", "2026-10-11", url: "https://d.example/delta")],
                                   clients: [], history: [], blocked: .empty, today: Self.today,
                                   sourceIds: ["source-b"], landing: landing, into: ctx)
        #expect(b.degradedReads.isEmpty, Comment(rawValue: "the next source did not read again: \(b.degradedReads)"))
        #expect(b.inserted == 1 && b.updated == 1, Comment(rawValue:
            "source B did not land whole: inserted \(b.inserted), updated \(b.updated)"))

        let fresh = try ctx.fetch(FetchDescriptor<Prospect>())
        let held = try landing.rows()
        #expect(Set(held.map(ObjectIdentifier.init)) == Set(fresh.map(ObjectIdentifier.init))
                && held.count == fresh.count, Comment(rawValue:
            "the working set holds \(held.map(\.groupName).sorted()) where the store holds "
            + "\(fresh.map(\.groupName).sorted())"))
        #expect(fresh.map(\.groupName).sorted() == ["Delta Show", "Sigma Choir"])
    }
}
