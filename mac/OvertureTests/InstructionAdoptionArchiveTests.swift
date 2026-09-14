import Testing
import Foundation

// #2925. Whether real runs actually adopt `no_route_found`, asked of every run this Mac still holds.
//
// #2893 shipped the value a run uses to say it found a person and no way to reach them, plus a refusal
// (`route_named_but_not_supplied`) for a contact that names a route and supplies none. #2641 added the
// per-run counting. What nothing did was CHECK the counts against real runs, and until that is done the
// refusal cannot be trusted to mean what it says: if runs keep naming `form_or_dm` on somebody with no
// route, the refusal fires on ordinary shows instead of broken ones, the card tells Dan a check fell
// short when it did what it always did, and the line gets ignored and then removed (L93).
//
// So this reads the ARCHIVES, which hold what each run actually emitted, through the app's own
// `RunInstructionCompliance.measure` rather than a second predicate written beside it (L107, L263).
//
// WHAT IT DOES NOT ASSERT, and why. It does not fail on a run that named routes it never found. Those
// runs exist and are the whole reason the refusal was built, so a red there would be a standing red for
// a historical fact nobody can change, and a standing red makes every other failure unreadable (L538).
// What it asserts is that the reading HAPPENED: an archive directory that could not be read and a
// history with nothing in it leave the same empty result (L98).
//
// It prints a line per run and a total, which is the trend #2925 asked for, in the place the suite's
// other corpus lines already are. Aggregates only: a results file names real people, and this
// repository is public (L155, L222).
@Suite("Do real runs adopt no_route_found (#2925)")
struct InstructionAdoptionArchiveTests {

    private struct RunReading {
        let slot: RunSlot
        let stamp: String
        let measurement: RunInstructionCompliance.Measurement
    }

    // The RELEASE handoff directory, spelled out rather than taken from `StoreLocation.handoffDirectory`,
    // which under test resolves to the Debug build's own folder (#2097 keeps a test run out of the live
    // one, correctly). The archives this asks about are the ones Dan's real runs wrote, and they are read
    // and never written, exactly as `EmptyRouteClaimLiveStoreTests` reads the live store (L2).
    private static var handoff: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var archivesExist: Bool {
        RunSlot.allCases.contains { slot in
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: handoff)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.contains(where: PrepRunArchive.isArchivedRunFolder)
        }
    }

    private func readings() -> [RunReading] {
        let fm = FileManager.default
        return RunSlot.allCases.flatMap { slot -> [RunReading] in
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: Self.handoff)
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter(PrepRunArchive.isArchivedRunFolder)
                .sorted()
            return names.compactMap { stamp -> RunReading? in
                let results = dir.appendingPathComponent(stamp, isDirectory: true)
                    .appendingPathComponent(PrepRunArchive.resultsFilename(for: slot))
                // A folder holding no readable results left no record of what the run emitted, which says
                // nothing about adoption either way, so it is dropped rather than counted as a run that
                // adopted nothing (L98).
                guard let decoded = HandoffFile.read(at: results,
                                                     decode: { try PrepResultsDecoder.decode($0) }).value
                else { return nil }
                let contacts = decoded.results.flatMap { $0.contacts ?? [] }
                guard !contacts.isEmpty else { return nil }
                return RunReading(slot: slot, stamp: stamp,
                                  measurement: RunInstructionCompliance.measure(contacts: contacts))
            }
        }
    }

    @Test(.enabled(if: archivesExist, "no archived runs on this machine"))
    func theArchivesSayWhetherTheValueIsBeingUsed() {
        let runs = readings()
        // A read that came back empty is a failed read, not a history of runs that adopted nothing: the
        // enabling condition above already found archived folders, so zero readable ones is a broken
        // decode rather than a finding about the runs (L98, L11).
        #expect(!runs.isEmpty, Comment(rawValue:
            "archived run folders exist and not one of them yielded a readable results file, so nothing "
            + "below measured adoption; that is a decode failure, not a run that emitted no contacts"))
        guard !runs.isEmpty else { return }

        let contacts = runs.reduce(0) { $0 + $1.measurement.contacts }
        let adopted = runs.reduce(0) { $0 + $1.measurement.declaredNoRouteFound }
        let refused = runs.reduce(0) { $0 + $1.measurement.routeNamedButNotSupplied }
        let runsRefusingWithoutAdopting = runs.filter { $0.measurement.refusalFiringWithoutAdoption }

        for r in runs {
            print("instruction-adoption: \(r.slot.rawValue) \(r.stamp): "
                  + "\(r.measurement.contacts) contacts, "
                  + "\(r.measurement.declaredNoRouteFound) said no_route_found, "
                  + "\(r.measurement.routeNamedButNotSupplied) named a route and gave none")
        }
        print("instruction-adoption corpus: \(runs.count) archived runs, \(contacts) contacts, "
              + "\(adopted) declared no_route_found, \(refused) refused as route_named_but_not_supplied, "
              + "\(runsRefusingWithoutAdopting.count) runs refused while never once adopting the value")

        // The measurement was really taken over contacts, rather than over a list of runs that each held
        // none. Without this every count above could be zero for the emptiest possible reason and the
        // line would still read as a clean bill of health.
        #expect(contacts > 0, "the archived runs decoded and carried no contacts at all")
    }
}
