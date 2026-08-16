import Testing
import Foundation
import SwiftData

// #2594: the #2530 guard is scoped to one file, and nobody had measured whether that leaves a gap.
//
// `RefusedSourceIsImmutableTests` proves no route in `WatchlistEditing` can edit a row whose
// `inactiveReason` is `.orgRefusal`, the record of an organisation asking not to be contacted. Writing it
// found six of the seven routes doing exactly that. But anything that assigns to a `WatchedSource` field
// WITHOUT going through `WatchlistEditing` bypasses `isRefusalRecord` entirely, and no test would notice.
//
// Measured 2026-08-16: the gap is NOT empty. Ten files outside `WatchedSource.swift` write one of its
// stored properties, and one of them, `OrgDoNotContact`, writes the two fields the refusal itself is made
// of. It is correct today. Nothing was stopping a third writer appearing and being wrong.
@MainActor
@Suite("Only known writers touch a refusal (#2594)")
struct RefusalWritersAreKnownTests {

    // The two fields the refusal record IS. Everything else on the row is page state a scout may
    // legitimately update; these two are the decision.
    private static let refusalFields = ["isActive", "inactiveReason", "inactiveReasonRaw"]

    // The files allowed to write them, each with the reason it is allowed. A registry, deliberately, and
    // the test below is what makes it honest: it derives the REAL writers from the source, so a file
    // added later cannot be exempt by being forgotten (L96). This list only has to be reviewed when the
    // derived set disagrees with it.
    private static let permittedWriters: [String: String] = [
        "WatchlistEditing.swift":
            "the guarded surface itself. #2530 proves every route in it refuses to edit a refusal record.",
        "OrgDoNotContact.swift":
            "the two routes that CREATE and RELEASE the refusal. `mark` is what writes `.orgRefusal` in "
            + "the first place, and `unmark` is Dan taking a mis-click back. Neither can be routed through "
            + "WatchlistEditing, because that surface's whole rule is refusing to touch these rows.",
    ]

    private static func appFiles() -> [AppSourceWalk.File] {
        AppSourceWalk.appFiles()
    }

    // The derivation. Anything of the shape `<something>.isActive = ` or `.inactiveReason = ` in app
    // source, comments stripped, outside the model's own file.
    private static func writersOfTheRefusalFields() -> [String: [String]] {
        var found: [String: [String]] = [:]
        // Only files that NAME the type. `Experiment` has an `isActive` of its own, and matching on the
        // field alone reported it as a refusal writer, which is the over-match that would get this guard
        // switched off in a day (L93). A file holding both types is still flagged, which is the safe
        // direction: it gets read once and listed with its reason.
        for file in appFiles() where file.name != "WatchedSource.swift" && file.text.contains("WatchedSource") {
            for (line, code) in SwiftSource.scannableLines(in: file.text, skipping: []) {
                for field in refusalFields where code.contains(".\(field) =") && !code.contains("==") {
                    found[file.name, default: []].append("\(line): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return found
    }

    @Test("no file outside the two known writers assigns a refusal field")
    func onlyKnownWritersTouchIt() {
        let writers = Self.writersOfTheRefusalFields()
        #expect(!writers.isEmpty, "the scan found no writers at all, which is a broken derivation")

        let unexpected = writers.keys.filter { Self.permittedWriters[$0] == nil }.sorted()
        #expect(unexpected.isEmpty, """
            These files write a WatchedSource's refusal fields and are not among the known writers:
            \(unexpected.map { "\($0): \(writers[$0]?.joined(separator: "; ") ?? "")" }.joined(separator: "\n"))

            A write here can turn a refusal into something else. `WatchlistEditing.stopWatching` used to \
            overwrite `.orgRefusal` with `.removedByDan`, which is the state the Sources sheet offers a \
            Watch again button on (#2530). Route it through WatchlistEditing, or add it here with the \
            reason it cannot be.
            """)
    }

    // The other direction, which is what stops this list rotting: a permitted writer that no longer writes
    // anything is an exemption covering a file nobody is watching, and it reads exactly like a live one.
    @Test("every permitted writer still writes one")
    func noPermittedWriterIsStale() {
        let writers = Self.writersOfTheRefusalFields()
        for (name, reason) in Self.permittedWriters {
            #expect(writers[name] != nil,
                    "\(name) no longer writes a refusal field, so drop it from the list (\(reason))")
        }
    }

    // The control. A derivation that matched nothing would report a clean app forever, and a rename is all
    // it takes (L70).
    @Test("the scan recognises a real write")
    func theScanStillWorks() {
        let live = """
            func stop(_ source: WatchedSource) {
                source.isActive = false
                source.inactiveReason = .removedByDan
            }
            """
        let hits = SwiftSource.scannableLines(in: live, skipping: []).filter { _, code in
            Self.refusalFields.contains { code.contains(".\($0) =") && !code.contains("==") }
        }
        #expect(hits.count == 2)

        // And it does not fire on a READ, which is what most of the app does with these fields.
        let reading = "guard source.inactiveReason == .orgRefusal else { return }"
        let readHits = SwiftSource.scannableLines(in: reading, skipping: []).filter { _, code in
            Self.refusalFields.contains { code.contains(".\($0) =") && !code.contains("==") }
        }
        #expect(readHits.isEmpty)
    }

    // MARK: the behaviour behind the one non-obvious permission

    // `OrgDoNotContact.unmark` is allowed to clear a refusal, so what it must never do is clear anything
    // else. A source Dan removed as dead is a different decision, and releasing a mis-clicked refusal is
    // not an instruction to resurrect a website he gave up on.
    @Test("releasing a refusal leaves a source stopped for any other reason alone")
    func unmarkOnlyReleasesTheRefusal() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([WatchedSource.self, Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))

        let refused = WatchedSource(sourceId: "a", orgName: "Aurora Strings",
                                    listingsURL: "https://a.example", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        ctx.insert(refused)

        let removed = WatchedSource(sourceId: "b", orgName: "Aurora Strings",
                                    listingsURL: "https://b.example", kind: .html)
        removed.isActive = false
        removed.inactiveReason = .removedByDan
        ctx.insert(removed)

        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2026-11-02", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)

        OrgDoNotContact.unmark(orgOf: p, in: [p], sources: [refused, removed])

        #expect(refused.isActive, "the refusal it was asked to release came back")
        #expect(refused.inactiveReason == nil)
        #expect(!removed.isActive, "a source Dan removed himself must stay removed")
        #expect(removed.inactiveReason == .removedByDan)
    }
}
