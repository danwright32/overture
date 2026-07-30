import Testing
import Foundation
import SwiftData
@testable import Overture

// #1776 (milestone 34): one derivation naming, for every organisation in the corpus, what Overture
// decided about it and why. #1731 needs it to STATE the verdict, #1729 needs it to rank the ones most
// likely to be wrong, and #1702 is the reason it is derived here rather than written again in a view.
@Suite("What Overture decided about each organisation (#1776)")
struct OrganisationListingTests {

    private func show(_ presenter: String?, at venue: String?, _ title: String) -> OrganisationListing.Show {
        OrganisationListing.Show(presenter: presenter, venue: venue, title: title)
    }

    // The three verdicts, on the three shapes the live store actually holds.
    @Test func everyOrganisationCarriesItsVerdict() {
        let shows = [
            // Spelled exactly like a room: the building, and no correction can move it (#1763).
            show("The Green Room 42", at: "The Green Room 42", "A Cabaret"),
            // Named inside a room: the building, but promotion reaches this one.
            show("Carnegie Hall Presents", at: "Carnegie Hall", "A Recital"),
            show("Carnegie Hall Presents", at: "Zankel Hall", "Another Recital"),
            // Two distinct venues and no name overlap: a producer, so one answer may be shared.
            show("Young Concert Artists", at: "Merkin Hall", "A Debut"),
            show("Young Concert Artists", at: "The Cutting Room", "A Second Debut"),
            // One venue, no name overlap: refused, and each show is paid for separately.
            show("FRIGID New York", at: "Under St Marks", "A Fringe Show"),
        ]
        let listing = OrganisationListing.build(shows: shows)
        func entry(_ name: String) -> OrganisationListing.Entry? {
            listing.first { $0.name == name }
        }

        #expect(entry("The Green Room 42")?.verdict == .theBuilding)
        #expect(entry("The Green Room 42")?.reason == .spelledExactlyLikeARoom)

        #expect(entry("Carnegie Hall Presents")?.verdict == .theBuilding)
        #expect(entry("Carnegie Hall Presents")?.reason == .namedInsideARoom)

        #expect(entry("Young Concert Artists")?.verdict == .sharesOneAnswer)
        #expect(entry("Young Concert Artists")?.reason == nil)

        #expect(entry("FRIGID New York")?.verdict == .paidForSeparately)
        #expect(entry("FRIGID New York")?.reason == nil)
    }

    // Dan's own correction is stated as HIS, never as something Overture worked out, because #1719's
    // whole point was that a verdict he set and one a rule reached invite different responses.
    @Test func aCorrectionIsAttributedToDanRatherThanToARule() {
        let shows = [show("FRIGID New York", at: "Under St Marks", "A Fringe Show")]
        let listing = OrganisationListing.build(
            shows: shows, overrides: ProducerOverrides(demoted: ["frigid new york"]))
        let frigid = listing.first { $0.name == "FRIGID New York" }
        #expect(frigid?.verdict == .theBuilding)
        #expect(frigid?.reason == .yourOwnCorrection)
        #expect(frigid?.standing == .demoted)
    }

    // The evidence each entry carries, which is what #1729 shows Dan so he can judge in seconds.
    @Test func eachOrganisationCountsItsRowsShowsAndVenues() {
        let shows = [
            show("FRIGID New York", at: "Under St Marks", "Show One"),
            show("FRIGID New York", at: "Under St Marks", "Show Two"),
            show("FRIGID New York", at: "Under St Marks", "Show Two"),
        ]
        let frigid = OrganisationListing.build(shows: shows).first { $0.name == "FRIGID New York" }
        #expect(frigid?.rowCount == 3)
        #expect(frigid?.distinctShowCount == 2)
        #expect(frigid?.distinctVenueCount == 1)
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="organisations the gate refuses that are not a venue brand, ranked by the rows they cover"
    // #1729's shortlist. Measured over the live store: 117 refused organisations covering 189 rows, and
    // ranked by ROWS they run 27, 11, 10, 7, 6, 4, 3 and then a cliff where all 110 others carry one or
    // two rows each. Three is the cutoff, at that gap, because below it a correction saves nothing and
    // protects nothing.
    //
    // Ranked by rows rather than by distinct shows on purpose: distinct shows finds a rented room and is
    // blind to the mirror shape, a producer in its own house running ONE long series over many dates,
    // which is what The New York Neo-Futurists are (11 rows, one title, one room) and what #1679 was
    // about. Both shapes have to surface, so the count that ranks them is the one that measures what a
    // correction is worth.
    @Test func theShortlistRanksByRowsSoBothMistakesSurface() {
        var shows: [OrganisationListing.Show] = []
        // A rented room: many different companies, one venue.
        for i in 1...9 { shows.append(show("FRIGID New York", at: "Under St Marks", "Fringe Show \(i)")) }
        // The mirror: one long series, one room, many dates. Ranking by distinct shows never finds it.
        for _ in 1...5 { shows.append(show("The New York Neo-Futurists", at: "Asylum NYC", "The Infinite Wrench")) }
        // Below the cutoff: correcting it would save nothing.
        shows.append(show("A Two Row Group", at: "Merkin Hall", "One Night"))
        shows.append(show("A Two Row Group", at: "Merkin Hall", "Another Night"))
        // Already the building, so never a suggestion.
        shows.append(show("The Green Room 42", at: "The Green Room 42", "A Cabaret"))

        let shortlist = OrganisationListing.shortlist(shows: shows)
        #expect(shortlist.map(\.name) == ["FRIGID New York", "The New York Neo-Futurists"])
        #expect(shortlist.first?.rowCount == 9)
    }

    // An organisation Dan has already ruled on is not offered back to him as a suggestion.
    @Test func anOrganisationAlreadyCorrectedLeavesTheShortlist() {
        var shows: [OrganisationListing.Show] = []
        for i in 1...9 { shows.append(show("FRIGID New York", at: "Under St Marks", "Fringe Show \(i)")) }

        #expect(OrganisationListing.shortlist(shows: shows).map(\.name) == ["FRIGID New York"])
        let after = OrganisationListing.shortlist(
            shows: shows, overrides: ProducerOverrides(demoted: ["frigid new york"]))
        #expect(after.isEmpty)
    }

    // A presenter the gate cannot key has no organisation in it, so it appears nowhere.
    @Test func aNamelessPresenterIsNotAnOrganisation() {
        let listing = OrganisationListing.build(shows: [
            show(nil, at: "Merkin Hall", "A Show"),
            show("   ", at: "Merkin Hall", "Another Show"),
        ])
        #expect(listing.isEmpty)
    }

    // #1731: the evidence Dan reads, as one sentence per organisation. It has to carry the SHAPE, because
    // the shape is the whole judgement: many different titles in one room reads as a rented room, one
    // title over many dates reads as a company in its own house, and the two want opposite corrections.
    @Test func theEvidenceSentenceCarriesTheShapeNotJustTheNumbers() {
        var shows: [OrganisationListing.Show] = []
        for i in 1...9 { shows.append(show("FRIGID New York", at: "Under St Marks", "Fringe Show \(i)")) }
        for _ in 1...5 { shows.append(show("The New York Neo-Futurists", at: "Asylum NYC", "The Infinite Wrench")) }
        let listing = OrganisationListing.build(shows: shows)
        func line(_ name: String) -> String? {
            listing.first { $0.name == name }.map(OrganisationListing.evidenceLine)
        }
        #expect(line("FRIGID New York") == "9 shows, 9 different titles, all in one room.")
        #expect(line("The New York Neo-Futurists") == "5 shows, all the same title, all in one room.")
    }

    // A producer that travels says so, because playing several rooms is the thing that distinguishes it.
    @Test func anOrganisationThatPlaysSeveralRoomsSaysHowMany() {
        let shows = [
            show("Young Concert Artists", at: "Merkin Hall", "A Debut"),
            show("Young Concert Artists", at: "The Cutting Room", "A Second Debut"),
        ]
        let entry = OrganisationListing.build(shows: shows).first { $0.name == "Young Concert Artists" }!
        #expect(OrganisationListing.evidenceLine(entry) == "2 shows, 2 different titles, across 2 rooms.")
    }



    // #1731: the card says the SPECIFIC reason, not one line for all of them. The three reasons invite
    // different responses, which is why they were three sentences in the first place: a name that IS a
    // room's cannot be overruled at all (#1763), a name that merely overlaps one can, and one Dan set
    // himself is his to revisit.
    //
    // Derived through ONE function both the card and the sheet call, so the two cannot state different
    // reasons for the same name (#1702).
    @Test func theBuildingReasonHasOneDefinitionForEverySurface() {
        #expect(OrganisationListing.buildingReason(isRoomName: true, standing: .none)
                == .spelledExactlyLikeARoom)
        #expect(OrganisationListing.buildingReason(isRoomName: false, standing: .demoted)
                == .yourOwnCorrection)
        #expect(OrganisationListing.buildingReason(isRoomName: false, standing: .none)
                == .namedInsideARoom)
        // Equality is asked FIRST, matching the gate, which tests it before it reads any correction. A
        // name that is a room's stays uncorrectable even where Dan has also demoted it.
        #expect(OrganisationListing.buildingReason(isRoomName: true, standing: .demoted)
                == .spelledExactlyLikeARoom)
    }

    // What a CARD says, which names the organisation because the card has no other place to put it.
    @Test func theCardNamesTheOrganisationAndTheReason() {
        #expect(OrganisationListing.cardLine("Jalopy Theatre", .spelledExactlyLikeARoom)
                == "Jalopy Theatre is a room's name, so Overture reads it as the building, not the presenter.")
        #expect(OrganisationListing.cardLine("Carnegie Hall Presents", .namedInsideARoom)
                == "Carnegie Hall Presents overlaps a room's name, so Overture reads it as the building, not the presenter.")
        #expect(OrganisationListing.cardLine("FRIGID New York", .yourOwnCorrection)
                == "You told Overture to read FRIGID New York as the building, not the presenter.")
    }

}

// The same derivation against a COPY of Dan's real store. The unit tests above pin each rule on
// hand-built rows; this asks whether the shortlist, meeting 724 real shows and 156 real presenter
// strings, actually surfaces the two organisations it was designed around and stays short enough to read.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("What Overture decided about each organisation, live store (#1776)")
struct OrganisationListingLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="organisations the gate refuses that are not a venue brand, and the rows each covers"
    // Measured 2026-07-29: 156 keyed presenters, of which 22 are judged the building, 17 share one
    // answer and 117 are paid for separately over 189 rows. Ranked by rows the refused run 27, 11, 10, 7,
    // 6, 4, 3 and then a cliff of ones and twos, so the cutoff at three yields seven organisations.
    //
    // Asserted as SHAPE with headroom rather than as those counts, because the store grows every night.
    // The two named organisations are the point: FRIGID New York is the rented-room shape and The New
    // York Neo-Futurists is its mirror, a company in its own house running one series over many dates.
    // A ranking that finds only one of them is the defect this issue's first draft shipped with.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theShortlistFindsBothShapesAndStaysShortEnoughToRead() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1776-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let dest = scratch.appendingPathComponent("Overture.store")
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let ctx = ModelContext(try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: dest, cloudKitDatabase: .none)]))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")

            let shows = all.map {
                OrganisationListing.Show(presenter: $0.presenter, venue: $0.venue, title: $0.groupName)
            }
            let listing = OrganisationListing.build(shows: shows)
            #expect(listing.count > 50, "the derivation still reaches a real spread of organisations")
            // All three verdicts occur, so none of the arms has quietly stopped firing.
            #expect(listing.contains { $0.verdict == .theBuilding })
            #expect(listing.contains { $0.verdict == .sharesOneAnswer })
            #expect(listing.contains { $0.verdict == .paidForSeparately })
            // And the reason is always stated for a building and never invented for anything else.
            #expect(listing.allSatisfy { ($0.reason != nil) == ($0.verdict == .theBuilding) })

            let shortlist = OrganisationListing.shortlist(shows: shows)
            let names = shortlist.map(\.name)
            #expect(names.contains("FRIGID New York"), "the rented-room shape: \(names)")
            #expect(names.contains("The New York Neo-Futurists"), "the mirror shape: \(names)")
            // Short enough that Dan reads it rather than wades through it. Generous headroom over the
            // seven measured, so an ordinary night of scouting cannot fail this.
            #expect(shortlist.count <= 20, "shortlist grew past what a person will read: \(names)")
            // A suggestion is never made about something already judged the building.
            #expect(shortlist.allSatisfy { $0.verdict == .paidForSeparately })
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
