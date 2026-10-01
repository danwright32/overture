import Testing
import Foundation
import SwiftData

// #4329 (A12): the read phase of every scout entry point writes NOTHING to the store, judged by the state the
// code can reach rather than by a list of the sites somebody remembered (L247, L96).
//
// The write set is DERIVED (`StoreWriteScan`, shared with B1, #4370): each entry point's body up to where it
// takes the store (`landings.begin(`), every app function that region reaches by name, across files, and
// every store write in any of them, with the model vocabulary read from the Schema the app persists. On
// 6d3453d8 (and on fdba0379, just before this change) that derivation found the issue's whole list and
// nothing it lacked: ingest's `source.notes` twice, `fail()` and `recordConfirmedEmpty`; every write in
// `SourceCheck.decide`; `check`'s `recordFailedRead` and pending hash and months; the Squarespace promotion;
// the inline branch's three; and `readNative`'s `recordFailedRead`.
//
// What is left after this change is in `classified`, each with the reason it is not a store write. A site
// the scan finds that is not there fails, and so does an entry that no longer matches anything, so the table
// cannot quietly outlive the code it excuses.
//
// The runtime half, in the other direction, is `ScoutReadPhaseWritesNothingTests`: `context.hasChanges` at
// every read-phase await, with every branch that writes driven.
@MainActor
@Suite("A scout's read phase writes nothing to the store, by a derived scan (#4329)")
struct ScoutReadPhaseWriteScanTests {

    // The entry points whose read phase is scanned: every scout landing that takes the store
    // (`LandingSingleFlight.EntryPoint`), by the function that holds its read phase. The lead paste lands
    // through `ScoutExtractIngest.ingest`, so it is covered by the second.
    static let entryPoints: [(owner: String, name: String)] = [
        ("ScoutService", "runScout"),
        ("ScoutExtractIngest", "ingest"),
    ]
    static let boundary = "landings.begin("

    // Every site the scan finds in a read phase that is not a store write, keyed by `Site.key`, with why.
    static let classified: [String: String] = [
        "ScoutService.runScout saves":
            "the default of runScout's `saveClosing` seam, declared in its signature and run only by save one "
            + "and save two, both after the read phase",
        "ScoutExtractIngest.ingest saves":
            "the default of the ingest's `saveClosing` seam, declared in its signature and run only by the "
            + "closing save after the landing loop",
        "ExtractedEventGuard.placed assigns venue":
            "`promoted.venue` on an ExtractedEvent, a value the read builds, not a model row",
        "SameDateVenueMerge.stamped assigns seriesId":
            "`out.seriesId` on an ExtractedEvent, a value the read builds, not a model row",
        "ScoutClassify.run assigns sourceIds":
            "`p.sourceIds` on an AssembledProspect, the classify pass's own value, not a model row",
    ]

    private static func storedByEntity() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for entity in AppSchema.schema.entities {
            out[entity.name] = Set(entity.attributes.map(\.name)).union(entity.relationships.map(\.name))
        }
        return out
    }

    private static func appIndex() -> StoreWriteScan.Index {
        let root = RepoRoot.app.standardizedFileURL.path
        return StoreWriteScan.Index(files: AppSourceWalk.appFiles().map { file in
            (name: String(file.url.standardizedFileURL.path.dropFirst(root.count + 1)), text: file.text)
        })
    }

    @Test func theReadPhaseOfEveryScoutEntryPointWritesNothing() throws {
        let index = Self.appIndex()
        let vocabulary = StoreWriteScan.vocabulary(stored: Self.storedByEntity(), index: index)

        // POSITIVE CONTROLS (L98): the vocabulary found the writers this rule is about, and each region
        // reached across files into the functions that used to write. A walk that found none of them would
        // report a clean read phase about nothing.
        for mutator in ["recordFailedRead", "recordSuccessfulRead", "applyCaptured"] {
            #expect(vocabulary.mutators.contains(mutator), Comment(rawValue:
                "the derived vocabulary has no mutator \(mutator), so a call to it would not be seen"))
        }
        for property in ["health", "lastFailure", "kind", "pendingPageMonths", "notes", "lastCheckedAt"] {
            #expect(vocabulary.properties.contains(property), Comment(rawValue:
                "the derived vocabulary has no property \(property), so a write to it would not be seen"))
        }

        var found: [StoreWriteScan.Site] = []
        var reached: Set<String> = []
        for entry in Self.entryPoints {
            let region = try StoreWriteScan.writesReachable(fromRegionOf: entry.name, owner: entry.owner,
                                                            endingBefore: Self.boundary, index: index,
                                                            vocabulary: vocabulary)
            #expect(!region.lines.isEmpty, "a read phase was scanned over no lines")
            found += region.sites
            reached.formUnion(region.reached.map(\.qualifiedName))
        }
        for function in ["SourceCheck.decide", "ScoutService.check", "ScoutService.readNative",
                         "ScoutService.shouldPromoteToSquarespace", "ScoutExtractIngest.fail",
                         "ScoutExtractIngest.recordConfirmedEmpty"] {
            #expect(reached.contains(function), Comment(rawValue:
                "the read phase no longer reaches \(function), so the walk is not following the calls it must"))
        }

        let unclassified = found.filter { Self.classified[$0.key] == nil }
        #expect(unclassified.isEmpty, Comment(rawValue:
            "the read phase of a scout entry point writes the store: "
            + unclassified.map(\.description).joined(separator: "; ")
            + ". Capture the write in a SourceWrites value and apply it in the landing block "
            + "(WatchedSource.applyCaptured), or, if it is not a store write, classify it here with why (#4329)."))
        let stale = Set(Self.classified.keys).subtracting(found.map(\.key))
        #expect(stale.isEmpty, Comment(rawValue:
            "classified sites the scan no longer finds: " + stale.sorted().joined(separator: "; ")
            + ". Delete the entry, so the table cannot outlive the code it excuses."))
    }

    // Every branch that writes is a `SourceWrites.Site`, and every case is constructed somewhere in the app:
    // a case nothing builds is a branch the runtime guard's coverage would demand and no fake could reach.
    @Test func everyCaptureSiteIsBuiltByTheApp() {
        let pattern = try! NSRegularExpression(pattern: #"SourceWrites\(\s*\.([A-Za-z]+)\s*,"#)
        var built: Set<String> = []
        for file in AppSourceWalk.appFiles() {
            // Joined, so a construction broken across lines (`SourceWrites(` then `.queuedForReading, ...`)
            // is read as the one call it is.
            let s = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { built.insert(String(s[r])) }
            }
        }
        let declared = Set(SourceWrites.Site.allCases.map(\.rawValue))
        #expect(built == declared, Comment(rawValue:
            "declared but never built: \(declared.subtracting(built).sorted()); built but undeclared: "
            + "\(built.subtracting(declared).sorted())"))
    }

    // The scan's own rule (what it derives, the calls it follows, the writes it finds, its refusals) is driven
    // in `StoreWriteScanTests`, apart from this question asked of the app.
}
