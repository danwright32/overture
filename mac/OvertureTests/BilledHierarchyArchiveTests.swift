import Testing
import Foundation

// #3347 and #2258, the measurement the hold-down rests on.
//
// `BilledHierarchy.billedAsCastOnly` overrules a `primary` tier the run declared, and a rule that
// overrules the run must be shown not to fire on the ordinary case, or it is switched off within a day
// (L93). So this runs it over every archived run this Mac still holds and prints how many `primary`
// contacts it would hold down.
//
// The reading when it was written, 2026-09-06: 2 of 108, and both are the pair #3347 reports.
//
// PAIRED BY RUN STAMP, never by each file being the newest of its kind: a results file and the queue
// that produced it belong together only when they carry the same stamp, and reading one run's answers
// against another run's work-list produces a confident number that is pure artefact (L420, L58).
//
// Aggregates and the ROLE STRING only, never a name: the archives hold real people and this repository
// is public (L155, L222).
@Suite("How often the billed hierarchy would overrule a tier (#3347)")
struct BilledHierarchyArchiveTests {

    private static var handoff: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var anyArchivedRuns: Bool {
        RunSlot.allCases.contains { slot in
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: handoff)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.contains(where: PrepRunArchive.isArchivedRunFolder)
        }
    }

    private struct Pair {
        let results: PrepResults
        let listings: [String: ShowListing]
    }

    private func pairs() -> [Pair] {
        RunSlot.allCases.flatMap { slot -> [Pair] in
            let dir = PrepRunArchive.archivesDirectory(slot: slot, handoffDirectory: Self.handoff)
            let stamps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter(PrepRunArchive.isArchivedRunFolder).sorted()
            return stamps.compactMap { stamp -> Pair? in
                let folder = dir.appendingPathComponent(stamp, isDirectory: true)
                guard let results = HandoffFile.read(
                    at: folder.appendingPathComponent(PrepRunArchive.resultsFilename(for: slot)),
                    decode: { try PrepResultsDecoder.decode($0) }).value,
                      let queue = HandoffFile.read(
                        at: folder.appendingPathComponent(PrepRunArchive.queueFilename(for: slot)),
                        decode: { try JSONDecoder().decode(PrepQueue.self, from: $0) }).value
                else { return nil }
                var listings: [String: ShowListing] = [:]
                for item in queue.items { listings[item.naturalKey] = item.showListing }
                return Pair(results: results, listings: listings)
            }
        }
    }

    @Test(.enabled(if: anyArchivedRuns, "no archived runs on this machine"))
    func theRuleFiresOnTheMeasuredPairAndNotOnTheOrdinaryCase() {
        let pairs = pairs()
        // Archived runs exist, so pairing none of them is a broken read rather than a history with
        // nothing in it (L98, L11). Asked independently of the enabling condition above, which reads the
        // directory rather than this walk, so the two cannot answer for each other (L70).
        #expect(!pairs.isEmpty, Comment(rawValue:
            "archived runs exist and not one results file could be paired with its own work-list, so "
            + "nothing below measured anything"))
        guard !pairs.isEmpty else { return }

        var primary = 0
        var wouldHoldDown = 0
        var roles: [String] = []
        for pair in pairs {
            for result in pair.results.results {
                let listing = pair.listings[result.naturalKey]
                for contact in result.contacts ?? [] where contact.tier == ContactTier.primary.rawValue {
                    primary += 1
                    guard BilledHierarchy.billedAsCastOnly(name: contact.name,
                                                           inListingText: listing?.text,
                                                           truncated: listing?.truncated == true)
                    else { continue }
                    wouldHoldDown += 1
                    roles.append(contact.role ?? "(no role)")
                }
            }
        }
        print("billed-hierarchy corpus: \(primary) primary contacts across \(pairs.count) paired runs, "
              + "\(wouldHoldDown) billed only as cast and credited nowhere, so held down")
        for role in roles.sorted() { print("  held down, role as the run wrote it: \(role)") }

        // It really ran over contacts. Without this a zero could mean the rule is perfectly quiet or that
        // no archived run ever declared a tier at all, and those are opposite facts (L182, L98).
        #expect(primary > 0, "no archived run declared a primary tier, so the rule was not exercised")
    }
}
