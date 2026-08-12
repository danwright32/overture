import Testing
import Foundation
import SwiftData

// #2508. The classifier's three signal lists (`agencySignal`, `producerSignal`, `strongProfile`) were
// matched as bare alternations with no word boundaries, so they fired INSIDE longer words.
//
// Measured on the live store's own presenter and title strings:
//   `Operation Mincemeat: Mission Recast` matched "opera", and so read as an organisation
//   `Sam Gelband` matched "band"
//   `Let's Get Schooled!` matched "school", which carried it into strongProfile too
//
// It was not a one-line fix, and the issue said so. Anchoring ALONE wrongly stops matching
// `NY Phil Ensembles at Merkin Hall`, because "ensemble" no longer matches the plural, so the anchor
// needs a plural sweep beside it. Measured here, it also wrongly stopped matching three more real
// organisations, which is what the camel-case rule below is for.
//
// Every string in this file is one the live store holds today.
@Suite("Classifier signals match words, not fragments (#2508)")
struct ClassifierWordBoundariesTests {

    // MARK: - the false matches the issue was filed on

    @Test func aWordFragmentNoLongerNamesAnOrganisation() {
        // "opera" inside "Operation", "band" inside "Gelband", "school" inside "Schooled".
        #expect(!EventClassifier.namesAnOrganisation("Operation Mincemeat: Mission Recast"))
        #expect(!EventClassifier.namesAnOrganisation("Sam Gelband"))
        #expect(!EventClassifier.namesAnOrganisation("Let's Get Schooled!"))
    }

    @Test func aWordFragmentNoLongerMakesAStrongProfile() {
        #expect(!EventClassifier.hasStrongProfileSignal("Operation Mincemeat: Mission Recast"))
        #expect(!EventClassifier.hasStrongProfileSignal("Let's Get Schooled!"))
    }

    // "tour" inside "tournament" and "detour" is the same defect on the agency list. No live row has
    // this shape today, which is exactly why it is worth pinning: the list is anchored now, and nothing
    // in the store would notice if that were undone.
    @Test func aWordFragmentNoLongerReadsAsAnAgency() {
        #expect(!EventClassifier.hasAgencySignal("The Tournament of Champions"))
        #expect(!EventClassifier.hasAgencySignal("Detour Ensemble"))
    }

    // MARK: - what must keep matching

    // The plural half the issue named. Anchoring without it would have lost this row, which is a real
    // organisation, and the loss would have looked like the fix working.
    @Test func aPluralStillNamesAnOrganisation() {
        #expect(EventClassifier.namesAnOrganisation("NY Phil Ensembles at Merkin Hall"))
        #expect(EventClassifier.namesAnOrganisation("The Knights Chamber Orchestras"))
        #expect(EventClassifier.namesAnOrganisation("Trinity Church Choirs"))
    }

    // Found by measuring rather than by reading the regex: a word glued to a prefix in camel case is
    // still that word. PUBLIQuartet is a string quartet and iSchool is a school, and a plain word
    // boundary refuses both. Gelband and Schooled are the shapes that must stay refused, and the
    // difference between them is exactly the lowercase-to-uppercase transition.
    @Test func aWordGluedToAPrefixInCamelCaseStillCounts() {
        #expect(EventClassifier.namesAnOrganisation("PUBLIQuartet"))
        #expect(EventClassifier.namesAnOrganisation("iSchool of Music & Art"))
        #expect(EventClassifier.hasStrongProfileSignal("iSchool of Music & Art"))
        // and the two that must NOT come back with it
        #expect(!EventClassifier.namesAnOrganisation("Sam Gelband"))
        #expect(!EventClassifier.namesAnOrganisation("Let's Get Schooled!"))
    }

    // Same rule on the agency list: "Debuts on Debuts" is a debut showcase, and the singular term with
    // an anchor would have stopped reading it as one.
    @Test func anAgencyPluralStillReadsAsAnAgency() {
        #expect(EventClassifier.hasAgencySignal("Debuts on Debuts Niche Media Productions"))
        #expect(EventClassifier.hasAgencySignal("Rising Stars Showcase"))
        #expect(EventClassifier.hasAgencySignal("Distinguished Concerts International"))
    }

    // The ordinary case, which is most of the store: an organisation named in plain words is unaffected.
    @Test func anOrdinaryOrganisationIsUnaffected() {
        for name in ["Brooklyn Youth Chorus", "The Metropolitan Opera", "Juilliard School",
                     "New York Philharmonic", "Trinity Church", "Mark Morris Dance Group"] {
            #expect(EventClassifier.namesAnOrganisation(name), "\(name) stopped reading as an organisation")
        }
    }
}

// The measurement the issue asked for before shipping, kept rather than run once. #2508's own direction
// was to "re-measure before and after against the live store's presenter AND title strings, so the change
// is judged on the rows it actually moves rather than on the regex reading better".
//
// Measured 2026-08-12 over all 817 distinct presenter/title pairs in the live store, by running the
// shipping predicates themselves rather than a query written beside them (L107):
//
//   producerSignal  148 -> 145   lost: Operation Mincemeat: Mission Recast, Sam Gelband, Let's Get Schooled!
//   strongProfile   110 -> 108   lost: Operation Mincemeat: Mission Recast, Let's Get Schooled!
//   agencySignal     44 ->  44   nothing moved
//
// Five losses, all of them fragments matching inside a longer word, and nothing else changed. An earlier
// shape of the same fix lost three MORE rows (PUBLIQuartet, iSchool of Music & Art, Debuts on Debuts
// Niche Media Productions), each a real organisation, which is what the camel-case rule and the plural
// sweep are there for. That is the reason this suite tests both directions.
//
// Reads a copy of the live store and writes nothing anywhere.
@Suite("Classifier signals, measured on the real store (#2508)")
struct ClassifierSignalsLiveStoreTests {
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath:
            StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    // LIVE-STORE-CLAIM verified=2026-08-12 measure="distinct presenter and title strings whose classifier signals fire on a word fragment"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noSignalFiresOnAFragmentOfALongerWord() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("signals-\(UUID().uuidString)",
                                                                   isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            guard let url = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
            let rows = try context.fetch(FetchDescriptor<Prospect>())
            #expect(rows.count > 100, "the live store still holds a real queue to measure")

            // The three strings the issue named, asserted as the RULE rather than as a count: whatever
            // else is in the store, a signal may not fire on a fragment. Each is checked only if it is
            // still there, and the number actually checked is asserted, so a store that has moved on
            // cannot let this pass while checking nothing (L98).
            let fragments = ["Operation Mincemeat: Mission Recast", "Sam Gelband", "Let's Get Schooled!"]
            let parties = Set(rows.map { $0.presenter?.isEmpty == false ? $0.presenter! : $0.groupName })
            var checked = 0
            for fragment in fragments where parties.contains(where: { $0.contains(fragment) }) {
                #expect(!EventClassifier.namesAnOrganisation(fragment),
                        "\(fragment) still reads as an organisation")
                checked += 1
            }
            #expect(checked > 0, "none of the strings #2508 was filed on are in the store, so this checked nothing")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
