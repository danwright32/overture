import Testing
import Foundation

// #3345, the standing measurement. Was the check held to its own procedure, asked of every run whose
// behaviour is still on disk.
//
// The issue's proposal was a REFUSAL: never record "no way in" about a named person whose canonical
// domain the run never fetched. Dan's call, 2026-09-06, was to measure first, because the mechanism
// could not be reproduced. Event streams have only been kept per run since #3446; when this was written
// exactly ONE run had them, and on that run all nine named people had their own domain fetched. A guard
// built on a signal nobody has measured on live traffic is how a guard comes to fire on the ordinary
// case and be switched off within a day (L506, L93, L142). This is the observe phase, and it is what
// makes the enforce phase decidable on evidence rather than on a hypothesis.
//
// THE PAIRING IS THE HARD PART, and getting it wrong is not hypothetical: while building this, one
// run's RESULTS were read against ANOTHER run's streams and reported 83 of 83 named people as never
// looked up, a number that was pure artefact. A results file and a stream folder belong together only
// when they carry the same run stamp (#3446), and a run with no stream folder is UNMEASURED rather than
// a run that tried nobody (L98, L58).
//
// Aggregates only, and never a name: a results file names real people and this repository is public
// (L155, L222).
@Suite("Did the check try their own site (#3345)")
struct CanonicalDomainProcedureArchiveTests {

    private struct RunReading {
        let slot: RunSlot
        let stamp: String
        let hostsFetched: Int
        let named: Int
        let tried: Int
        let notTried: Int
        let unanswerable: Int
        // Shows this run answered with nothing usable AND on which at least one named person never had
        // their own site tried. This is the population the refusal #3345 proposes would act on, so it is
        // the number that decides whether that refusal would fire on the ordinary case.
        let emptyShowsWithAnUntriedPerson: Int
        let emptyShows: Int
    }

    // The RELEASE handoff directory, spelled out because `StoreLocation.handoffDirectory` resolves to
    // the Debug build's own folder under test (#2097, correctly). Read only, never written (L2).
    private static var handoff: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static func stampsWithStreams(_ slot: RunSlot) -> [String] {
        let dir = slot.eventArchivesDirectory(in: handoff)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter(PrepRunArchive.isArchivedRunFolder)
            .sorted()
    }

    private static var anyStreamsArchived: Bool {
        RunSlot.allCases.contains { !stampsWithStreams($0).isEmpty }
    }

    private func readings() -> [RunReading] {
        RunSlot.allCases.flatMap { slot -> [RunReading] in
            Self.stampsWithStreams(slot).compactMap { stamp -> RunReading? in
                let streamFolder = slot.eventArchivesDirectory(in: Self.handoff)
                    .appendingPathComponent(stamp, isDirectory: true)
                let streamFiles = ((try? FileManager.default.contentsOfDirectory(atPath: streamFolder.path)) ?? [])
                    .filter { $0.hasSuffix(RunSlot.chunkEventsSuffix) }
                    .map { streamFolder.appendingPathComponent($0) }
                let lines = streamFiles.flatMap {
                    ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                }
                guard !lines.isEmpty else { return nil }
                let hosts = CanonicalDomainProcedure.fetchedHosts(inStreamLines: lines)

                // The results for the SAME stamp, and only that one. A results file this cannot find is a
                // run whose behaviour is readable and whose answers are not, which is unmeasured rather
                // than a run that tried nobody.
                let results = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: Self.handoff)
                    .appendingPathComponent(stamp, isDirectory: true)
                    .appendingPathComponent(PrepRunArchive.resultsFilename(for: slot))
                guard let decoded = HandoffFile.read(at: results,
                                                     decode: { try PrepResultsDecoder.decode($0) }).value
                else { return nil }

                var named = 0, tried = 0, notTried = 0, unanswerable = 0
                var emptyShows = 0, emptyWithUntried = 0
                for r in decoded.results {
                    let contacts = r.contacts ?? []
                    var untriedHere = false
                    for c in contacts {
                        switch CanonicalDomainProcedure.judgement(name: c.name, fetchedHosts: hosts) {
                        case .tried: named += 1; tried += 1
                        case .notTried: named += 1; notTried += 1; untriedHere = true
                        case .noCanonicalDomainToTry: unanswerable += 1
                        }
                    }
                    let usable = contacts.contains {
                        !($0.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !($0.formUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if !contacts.isEmpty && !usable {
                        emptyShows += 1
                        if untriedHere { emptyWithUntried += 1 }
                    }
                }
                return RunReading(slot: slot, stamp: stamp, hostsFetched: hosts.count, named: named,
                                  tried: tried, notTried: notTried, unanswerable: unanswerable,
                                  emptyShowsWithAnUntriedPerson: emptyWithUntried, emptyShows: emptyShows)
            }
        }
    }

    @Test(.enabled(if: anyStreamsArchived, "no archived event streams on this machine"))
    func theArchivedStreamsSayWhetherStepBWasTaken() {
        let runs = readings()
        // Stream folders exist, so zero readable pairings is a broken read rather than a history of runs
        // that answered nobody (L98, L11).
        #expect(!runs.isEmpty, Comment(rawValue:
            "archived stream folders exist and not one of them could be paired with its own results "
            + "file, so nothing below measured the procedure"))
        guard !runs.isEmpty else { return }

        for r in runs {
            print("canonical-domain: \(r.slot.rawValue) \(r.stamp): \(r.hostsFetched) hosts fetched, "
                  + "\(r.named) named people (\(r.tried) had their own site tried, \(r.notTried) did not), "
                  + "\(r.unanswerable) with no canonical domain to try, "
                  + "\(r.emptyShowsWithAnUntriedPerson) of \(r.emptyShows) shows answered with no route "
                  + "carry an untried person")
        }
        let named = runs.reduce(0) { $0 + $1.named }
        let notTried = runs.reduce(0) { $0 + $1.notTried }
        let wouldRefuse = runs.reduce(0) { $0 + $1.emptyShowsWithAnUntriedPerson }
        let emptyShows = runs.reduce(0) { $0 + $1.emptyShows }
        print("canonical-domain corpus: \(runs.count) runs with streams, \(named) named people, "
              + "\(notTried) never had their own site tried, and the refusal #3345 proposes would have "
              + "acted on \(wouldRefuse) of \(emptyShows) shows answered with no route")

        // The reading really ran over people, rather than over a list of runs that named none. Without
        // this every count above could be zero for the emptiest possible reason and the line would still
        // read as the check following its procedure perfectly (L182, L98).
        #expect(named + runs.reduce(0) { $0 + $1.unanswerable } > 0,
                "the paired runs decoded and named nobody at all, so the procedure was not measured")
    }
}
