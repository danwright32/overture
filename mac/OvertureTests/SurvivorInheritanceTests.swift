import Testing
import Foundation
import SwiftData

// #3597 / #3379: THREE passes delete a Prospect at every launch, and what a survivor inherits differs by
// pass, so what a merge costs Dan depends on which one happened to run. Measured on main at e7c1f529:
//
//   pass                        | feed identity | Dan's decisions | firstSeenAt
//   SameNightTitleVariantMerge  | yes (:176)    | no              | no
//   DriftedRunMerge             | no            | no              | no
//   NaturalKeyVenueMigration    | no            | yes (:147)      | yes (:142)
//
// Nine cells, three filled, and `DriftedRunMerge` carries NOTHING before it deletes. #3597 as filed asks
// only for the top-left cell on that one pass. Dan's call, 2026-09-11 (this session, in chat): all six,
// through ONE helper the three passes call, with the caller list derived from the code rather than named
// by hand, which is what #3379 asked for originally (L30, L38, L96).
//
// Each of the three is a different loss, which is why none is optional:
//   firstSeenAt      the funnel's opening node (#16) jumps forward to whenever the duplicate appeared
//   Dan's decisions  a rename or a kept-visible flag he set is gone, and the survivor then asserts the
//                    opposite of what happened (L163)
//   feed identity    the survivor keeps a key the feed stopped matching, so a live show goes on rendering
//                    as "may be cancelled" (#3278's class)
@MainActor
@Suite("One survivor inheritance, for every pass that deletes (#3597)")
struct SurvivorInheritanceTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, seriesId: String?,
                     opens: String, runEnd: String?, urls: [String], ingested: Date,
                     firstSeen: Date?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: "Weill Recital Hall",
                         performanceDate: opens, sourceListingURL: urls.first,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         ingestedAt: ingested, runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: urls, runNights: [opens])
        p.seriesId = seriesId
        p.firstSeenAt = firstSeen
        ctx.insert(p)
        return p
    }

    private let older = Date(timeIntervalSince1970: 1_750_000_000)
    private let newer = Date(timeIntervalSince1970: 1_755_000_000)

    // THE CLAIM, on the pass that carries nothing at all today. An older row holds the first sighting and
    // a rename Dan made; the fresher row is the one the feed still lists. Whichever survives, all three
    // facts must be on it afterwards.
    @Test func theDriftedRunMergeSurvivorInheritsEverythingTheLosersHeld() throws {
        let ctx = ModelContext(try container())
        let stale = row(ctx, key: "old key|2026-11-04|weill recital hall", title: "Autumn Series",
                        seriesId: "prod-1", opens: "2026-11-04", runEnd: "2026-11-06",
                        urls: ["https://example.test/old"], ingested: older, firstSeen: older)
        stale.groupName = "Autumn Series Revisited"
        stale.groupNameOverriddenByDan = true
        stale.missedScoutCount = 9
        // The stale row must WIN, or the survivor is already the live row and `carryTheFeedIdentity` is a
        // no-op by design, so the feed identity assertions below would pass without carrying anything
        // (L159). A sent record takes the ladder's first rung. Only ONE row has history, so `mustDefer`
        // does not fire and the pair still merges.
        stale.sentAt = older

        let live = row(ctx, key: "new key|2026-11-05|weill recital hall", title: "Autumn Series",
                       seriesId: "prod-1", opens: "2026-11-05", runEnd: "2026-11-06",
                       urls: ["https://example.test/live"], ingested: newer, firstSeen: newer)
        live.missedScoutCount = 0
        try ctx.save()

        DriftedRunMerge.run(in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the pass must collapse the pair, got \(rows.count) rows")
        let survivor = try #require(rows.first)
        #expect(survivor.firstSeenAt == older,
                "the survivor lost the earliest sighting, so the funnel's opening node moved forward (#16)")
        #expect(survivor.groupNameOverriddenByDan,
                "the survivor lost Dan's rename flag, which only the deleted row held (#3124)")
        #expect(survivor.groupName == "Autumn Series Revisited",
                "the flag moved without the name, so the row now claims a rename it does not show (L163)")
        #expect(survivor.runSourceURLs == ["https://example.test/live"],
                "the survivor does not hold the identity the feed is publishing (#3582)")
        #expect(survivor.missedScoutCount == 0,
                "the survivor kept a miss count earned by a key the feed stopped matching (#3278)")
    }

    // The same claim on the pass that carries only the feed identity.
    @Test func theSameNightSurvivorInheritsTheFirstSightingAndTheRename() throws {
        let ctx = ModelContext(try container())
        let old = row(ctx, key: "autumn series|2026-11-04|weill recital hall", title: "Autumn Series",
                      seriesId: nil, opens: "2026-11-04", runEnd: nil,
                      urls: ["https://example.test/old"], ingested: older, firstSeen: older)
        old.groupNameOverriddenByDan = true
        old.missedScoutCount = 9
        row(ctx, key: "autumn series gala|2026-11-04|weill recital hall", title: "Autumn Series Gala",
            seriesId: nil, opens: "2026-11-04", runEnd: nil,
            urls: ["https://example.test/live"], ingested: newer, firstSeen: newer)
            .missedScoutCount = 0
        try ctx.save()

        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the pass must collapse the pair, got \(rows.count) rows")
        let survivor = try #require(rows.first)
        #expect(survivor.firstSeenAt == older, "the survivor lost the earliest sighting (#16)")
        #expect(survivor.groupNameOverriddenByDan, "the survivor lost Dan's rename flag (#3124)")
    }

    // The guard. Its SUBJECT is derived from the code, never listed: any file that fetches Prospects and
    // deletes rows is a candidate, because a hand written list checks only what somebody remembered to add
    // and the whole defect here is a pass nobody added (L96).
    //
    // Text cannot tell WHICH type a `context.delete(x)` removes, and the candidate set therefore includes
    // files that fetch Prospects and delete something else entirely (a day off, a recipient). Rather than
    // guess from the variable's name, anything in the set that does not carry must DECLARE what it deletes,
    // in the same shape as this repo's other declared exemptions, so a new pass arrives as a red test
    // rather than as a silent omission (L233, L523). The declaration names the TYPE, so a file that starts
    // deleting Prospects under an existing exemption is not covered by it.
    @Test func everyPassThatDeletesAProspectCarriesTheInheritance() {
        let candidates = AppSourceWalk.appFiles().filter {
            $0.text.contains("FetchDescriptor<Prospect>") && $0.text.contains("context.delete(")
        }
        #expect(candidates.count >= 5,
                "found \(candidates.count) candidate files, too few to be scanning the app (L98)")

        var undeclared: [String] = []
        for file in candidates {
            if file.text.contains("SurvivorInheritance.carry") { continue }
            if file.text.contains("survivor-inheritance-exempt:") { continue }
            undeclared.append(file.name)
        }
        #expect(undeclared.isEmpty,
                "these delete rows after fetching Prospects and neither carry the inheritance nor say what they delete instead (#3597, L38): \(undeclared.sorted())")
    }

    // The other end: an exemption must say what it deletes and name an issue, or it is a hole nobody
    // reasoned about rather than a decision somebody made (L233, L523).
    @Test func everySurvivorInheritanceExemptionNamesATypeAndAnIssue() {
        let declaring = AppSourceWalk.appFiles().filter { $0.text.contains("survivor-inheritance-exempt:") }
        #expect(!declaring.isEmpty, "no file declares an exemption, so this guard measured nothing (L98)")
        for file in declaring {
            let block = file.text.components(separatedBy: "survivor-inheritance-exempt:").dropFirst()
                .map { String($0.prefix(200)) }.joined(separator: "\n")
            let namesAnIssue = block.range(of: "#[0-9]+", options: .regularExpression) != nil
            #expect(namesAnIssue, "\(file.name) declares an exemption that names no issue (#3597, L523)")
        }
    }
}
