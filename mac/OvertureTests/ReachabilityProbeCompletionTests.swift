import Testing
import Foundation
import SwiftData

// #1308 Layer 2 Phase 3 core: settling a finished run. Because a probe and a real Prep share the single
// runner and results file, the completion path uses the probe-run marker to tell them apart: marker present
// => it was a probe, so mark every probed show, ingest the results probe-safely (never a draft), and clear
// the marker; marker absent => a normal prep the caller ingests as before. A probe that produced NO results
// still marks its shows probed, so the badge resolves instead of sticking.
@MainActor
@Suite("Reachability probe completion (#1308)")
struct ReachabilityProbeCompletionTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    @Test func settlesAProbeMarksShowsIngestsContactsAndClearsMarker() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@aurora.org",
                                                             method: "named_decision_maker", confidence: "high",
                                                             formUrl: nil, provenance: "act")], draft: nil)
        ]))

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        #expect(report != nil)
        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        let pb = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == b })).first
        #expect(pa?.reachabilityProbedAt == now)
        #expect(pa?.recipients.first?.email == "jane@aurora.org")   // found contact stored
        // #1594: b is NOT in the results file, so the run never reached it. Stamping it would put "No
        // email found" on a show nobody looked at, and lock it out of a re-check for 90 days.
        #expect(pb?.reachabilityProbedAt == nil)
        #expect(pa?.status == .new)                                 // never drafted
        #expect(try ReachabilityProbeMarker.read(from: markerURL) == nil)   // marker cleared
    }

    // #1594 splits what used to be one test called aTotalMissStillMarksEveryShowProbed. It asserted that
    // an empty run marks its shows anyway, which conflated two situations that must not look alike: the
    // runner checked a show and found nobody (a real answer, worth keeping for 90 days), and the run died
    // before reaching it (no answer at all). Told apart by evidence in the results file, never by the
    // marker, because the marker only records what the run was ASKED to do.

    @Test func aShowTheRunnerCheckedAndFoundNothingIsMarkedProbed() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        // The runner reached this show and reported back with no contacts. That is a real negative.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil)
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(pa?.reachabilityProbedAt == now)
    }

    @Test func aRunThatDiedBeforeWritingResultsMarksNothing() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")   // never written: the run died
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        #expect(report != nil)   // still a probe, and the marker still clears
        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(pa?.reachabilityProbedAt == nil)
    }

    // #1594 1.1: the cancel and crash cases at real scale. A five show selection, the run stops after two.
    @Test func aCancelledRunLeavesTheShowsItNeverReachedUnprobed() throws {
        let ctx = ModelContext(try container())
        let keys = ["Aurora Strings", "Boreal Brass", "Cinder Quartet", "Delta Winds", "Ember Voices"]
            .map { newProspect(ctx, group: $0) }
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: Set(keys), startedAt: "s"), to: markerURL)
        // The cancel landed after two shows had been researched and written.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: keys[0], contacts: [PrepContact(name: "Jane", role: "Mgr",
                                                                   email: "jane@aurora.org",
                                                                   method: "named_decision_maker",
                                                                   confidence: "high", formUrl: nil,
                                                                   provenance: "act")], draft: nil),
            PrepResult(naturalKey: keys[1], contacts: [], draft: nil),
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let stamped = all.filter { $0.reachabilityProbedAt != nil }.map(\.naturalKey).sorted()
        #expect(stamped == [keys[0], keys[1]].sorted())
        let unreached = all.filter { keys[2...].contains($0.naturalKey) }
        #expect(unreached.count == 3)
        #expect(unreached.allSatisfy { $0.reachabilityProbedAt == nil })
    }

    // #1594 1.2: the re-settle path. PrepImporter.consumeIfNew SKIPS the ingest when the results file has
    // already been consumed, so on a relaunch after ingest but before the marker cleared, the stamping is
    // the only writer that runs at all. It therefore has to read the results file directly rather than
    // wait to be told what landed.
    @Test func aReSettleStampsOnlyTheKeysTheResultsFileHolds() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let b = newProspect(ctx, group: "Boreal Brass")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let defaults = freshDefaults()
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil)
        ]))
        // First settle consumes the file.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: defaults)
        // The marker is written again, as a relaunch mid-settle would leave it.
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"), to: markerURL)
        let later = now.addingTimeInterval(60)
        _ = PrepQueueService.settleReachabilityProbe(slot: .check, markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: later, defaults: defaults)

        let pa = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        let pb = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == b })).first
        #expect(pa?.reachabilityProbedAt != nil)
        #expect(pb?.reachabilityProbedAt == nil)
    }

    @Test func noMarkerMeansNotAProbe() throws {
        let ctx = ModelContext(try container())
        _ = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: d.appendingPathComponent("absent.json"),
            resultsURL: d.appendingPathComponent("results.json"),
            into: ctx, now: Date(), defaults: freshDefaults())
        #expect(report == nil)
    }

    // #1596 Phase 3, the hole the plan named. When Dan has hand-entered a recipient, the importer SKIPS
    // that row entirely so a re-run can never clobber his work. That skip means the guards never run and
    // the result is never upgraded, so the row would keep whatever the settle wrote first, which is
    // "no email found", about a show carrying a contact Dan typed in himself. His own contact is the
    // strongest possible evidence there is somebody to email.
    @Test func aHandEditedRowIsClassifiedFromItsOwnContactsNotTheProbe() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first!
        p.recipientsEditedByDan = true
        p.recipients.append(Recipient(id: "manual-1", email: "someone@example.org",
                                      name: "Someone Dan Knows", role: "Producer",
                                      provenance: .manual))
        try? ctx.save()

        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        // The probe reached the show and found nobody.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil)
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(after?.reachabilityResult == .emailFound)
        #expect(after?.recipients.first?.email == "someone@example.org")   // his contact untouched
    }

    @Test func aProbeThatFoundNothingRecordsNoEmailFound() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [], draft: nil)
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(after?.reachabilityResult == .noEmailFound)
    }

    @Test func aProbeThatFoundASendableContactRecordsEmailFound() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [PrepContact(name: "Jane", role: "Mgr",
                                                             email: "jane@aurora.org",
                                                             method: "named_decision_maker",
                                                             confidence: "high", formUrl: nil,
                                                             provenance: "act")], draft: nil)
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(after?.reachabilityResult == .emailFound)
    }

    // #1611: the fourth outcome, and the one the writer ORDER exists for. `markProbed` writes the
    // "no email found" floor BEFORE the ingest, so at that moment nothing has told a sendable address
    // from the room's own front desk. Only after `PrepImporter` has run the venue and press guards can
    // this row be classified, and the answer is `weakContactOnly`: there IS an address, it just is not
    // one Dan can pitch. Nothing else pins this end to end. The three tests above would all stay green
    // through a reordered settle, an early return, or a fourth writer that judged only "is anybody
    // sendable", any of which leaves this show reading "No email found" with a real address printed
    // underneath it, which is invisible on screen and only costs something when he dismisses a bookable
    // show over it.
    @Test func aProbeThatFoundOnlyTheRoomsOwnAddressRecordsWeakContactOnly() throws {
        let ctx = ModelContext(try container())
        let a = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        // The one address the check came home with belongs to the show's own room. Weill Recital Hall
        // resolves to Carnegie Hall, so VenueContactGuard holds this at ingest: real, and never sendable.
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: a, contacts: [PrepContact(name: "Box office", role: "Front desk",
                                                             email: "boxoffice@carnegiehall.org",
                                                             method: "general_inbox",
                                                             confidence: "high", formUrl: nil,
                                                             provenance: "act")], draft: nil)
        ]))

        _ = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == a })).first
        #expect(after?.reachabilityResult == .weakContactOnly)
        // The address is on the row, which is what makes the floor wrong rather than merely early.
        #expect(after?.recipients.first?.email == "boxoffice@carnegiehall.org")
    }

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "probe-\(UUID().uuidString)")!
        return d
    }
}
