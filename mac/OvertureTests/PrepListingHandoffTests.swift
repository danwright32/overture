import Testing
import Foundation
import SwiftData
@testable import Overture

// #1824: the listing text actually reaching the file the Prep run reads.
//
// `ShowListingReaderTests` proves the reader reads a page. That it reaches the QUEUE is a separate claim,
// and this repo has already paid for treating the two as one: #1679's promotion override had a real
// implementation for months while every call site passed the empty default, so the feature looked shipped
// and did nothing. The run cannot render a page itself, so a listing that never reaches the file is a draft
// written blind, which is exactly the defect being fixed.
@MainActor
@Suite("The show listing reaching the Prep run (#1824)")
struct PrepListingHandoffTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, PromotedProducer.self, DemotedHouse.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, group: String, listing: String?,
                        status: ReviewStatus = .queued) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-11", venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "other", venue: "The Room",
                         performanceDate: "2026-09-11", sourceListingURL: listing,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func showPage() -> String {
        "<html><body><script>boot();</script><h2>About the Show</h2>"
        + "<p>A cabaret concert of new songs written by one songwriter.</p></body></html>"
    }

    private func tmp(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    // The whole point: the queue file the run opens carries what the show is.
    @Test func theQueueTheRunReadsCarriesWhatTheListingSays() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Nightingale Quartet", listing: "https://tickets.example/showdetails/abc")
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                 markerURL: markerURL,
                                                 render: { _ in self.showPage() },
                                                 launch: {})

        let queue = try JSONDecoder().decode(PrepQueue.self, from: try Data(contentsOf: queueURL))
        #expect(queue.items.count == 1)
        #expect(queue.items[0].showListing?.status == ShowListing.read)
        #expect(queue.items[0].showListing?.text?.contains("cabaret concert of new songs") == true)
    }

    // A show with no listing URL carries no listing at all, rather than a fabricated "we could not read
    // it": the run tells Dan a different thing about each, and only one of them is true here.
    @Test func aShowWithNoListingURLCarriesNoListingAtAll() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Nightingale Quartet", listing: nil)
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                 markerURL: markerURL,
                                                 render: { _ in self.showPage() },
                                                 launch: {})

        let queue = try JSONDecoder().decode(PrepQueue.self, from: try Data(contentsOf: queueURL))
        #expect(queue.items[0].showListing == nil)
    }

    // The launch renders pages before it starts the run, which takes real seconds, so it must be able to
    // say how far along it is. A launch that can only show an indefinite spinner is the defect CLAUDE.md's
    // progress rule names by name.
    @Test func theLaunchReportsHowManyListingsItHasRead() async throws {
        let ctx = ModelContext(try container())
        insert(ctx, group: "Nightingale Quartet", listing: "https://tickets.example/a")
        insert(ctx, group: "Harbour Winds", listing: "https://tickets.example/b")
        let queueURL = tmp("q"), markerURL = tmp("m")
        defer { try? FileManager.default.removeItem(at: queueURL); try? FileManager.default.removeItem(at: markerURL) }

        let seen = ProgressLog()
        _ = try await PrepQueueService.startPrep(from: ctx, now: Date(), queueURL: queueURL,
                                                 markerURL: markerURL,
                                                 render: { _ in self.showPage() },
                                                 onListingProgress: { done, total in seen.record(done, total) },
                                                 launch: {})

        #expect(seen.totals.allSatisfy { $0 == 2 })
        #expect(seen.done.last == 2)
    }

    // A reachability check finds contacts and never drafts, so there is nothing for a description to
    // ground. Rendering a page per show there would spend seconds of Dan's launch on material no draft
    // will ever use.
    @Test func aReachabilityCheckSpendsNoRendersOnListings() async throws {
        let ctx = ModelContext(try container())
        let p = insert(ctx, group: "Nightingale Quartet", listing: "https://tickets.example/a", status: .new)
        let queueURL = tmp("q"), markerURL = tmp("m"), probeURL = tmp("p")
        defer {
            for u in [queueURL, markerURL, probeURL] { try? FileManager.default.removeItem(at: u) }
        }

        _ = try PrepQueueService.startReachabilityProbe(keys: [p.naturalKey], from: ctx, now: Date(),
                                                        queueURL: queueURL, markerURL: markerURL,
                                                        probeRunURL: probeURL, launch: {})

        let queue = try JSONDecoder().decode(PrepQueue.self, from: try Data(contentsOf: queueURL))
        #expect(queue.items[0].showListing == nil)
    }

    // L2: a test must be structurally unable to reach a live service, not merely expected to remember the
    // seam. Every existing startPrep test builds prospects with a listing URL and passes no renderer, so
    // without this refusal the suite would quietly start loading real web pages in a hidden browser.
    @Test func theDefaultRendererRefusesToReachTheWebFromATest() async {
        let listing = await ShowListingReader.read(listingURL: "https://tickets.example/showdetails/abc")
        #expect(listing?.status == ShowListing.unreadable)
        #expect(listing?.text == nil)
    }

    // The pure join: listings are matched to items by natural key, the opaque token, and an item with no
    // answer keeps none. Held out of the service so the matching itself is directly testable.
    @Test func listingsAttachToTheirOwnItemByNaturalKey() {
        let items = [
            PrepQueueItem(naturalKey: "a", groupName: "A", discipline: "music", priorRelationship: "none"),
            PrepQueueItem(naturalKey: "b", groupName: "B", discipline: "music", priorRelationship: "none"),
        ]
        let queue = PrepQueueBuilder.build(from: items, generatedAt: "now", houses: [])
        let attached = PrepQueueBuilder.attaching(
            ["a": ShowListing(status: ShowListing.read, url: "https://x.example", text: "what it is")],
            to: queue)

        #expect(attached.items[0].showListing?.text == "what it is")
        #expect(attached.items[1].showListing == nil)
        #expect(attached.version == queue.version)
        #expect(attached.houses == queue.houses)
    }

    // A counter a Sendable progress closure can write into from the main actor.
    @MainActor private final class ProgressLog {
        var done: [Int] = []
        var totals: [Int] = []
        func record(_ d: Int, _ t: Int) { done.append(d); totals.append(t) }
    }
}
