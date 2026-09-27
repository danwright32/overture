import Testing
import Foundation
import SwiftData

// #4275, second pass: the two costs #4280's working set still paid on every event, measured optimised on a
// store clone (#4275, the optimised attribution comment).
//
//   - A database fetch by natural key for every event (`Prospect.stored(key:in:)`, from the exact key arm,
//     the opening re-check, the re-key availability check and the dropped night re-check): 9% of what was
//     left of a landing. The working set now answers it from a key index kept current exactly as its
//     membership is, and the database only when no landing is running.
//   - Every read of the working set re-compared the four raw fields of EVERY cached row against the row
//     (`Fold.describes`), including `runSourceURLs`, an archived blob that decodes on each read: about 13%.
//     A fold is now re-checked only when SwiftData says its row could have changed since the fold was taken
//     (the context's changed and inserted models, and the ones a save carried off, captured as it began).
//
// Both are guarded by COUNTING, never timing (L63): the keyed fetches that reached the store, and the fold
// checks made, neither of which may grow with the size of the store. And the trap the first pass guarded
// against is guarded again here, directly: a write made in place, announced by nobody, is seen by the next
// read, whether or not a save came between.
@MainActor
@Suite("A scout landing answers keyed lookups and fold checks from its working set (#4275)")
struct ScoutLandingKeyedReadsTests {
    private static let today = "2026-10-01"
    private static let room = "The Green Room 42"
    private static let newTitles = ["Aria Ensemble", "Bolero Trio", "Canon Choir", "Dirge Quartet",
                                    "Etude Players", "Fugue Collective"]

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, _ night: String, url: String) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                             venue: Self.room),
                         groupName: title, discipline: "theatre", venue: Self.room, performanceDate: night,
                         sourceListingURL: url, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func event(_ title: String, _ night: String, url: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: Self.room, venue: Self.room, performanceDate: night,
                       sourceUrl: url)
    }

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: n,
                                                        to: EasternDate.date(from: today)!)!
        return EasternDate.dayString(from: day)
    }

    // MARK: the working set on its own

    // A title rewritten in place, with nothing telling the working set, is folded afresh on the next read.
    // Twice: once with the write still unsaved, and once with a save between the write and the read, which
    // is the case the context's changed models alone cannot see (a save empties them).
    @Test(arguments: [false, true])
    func anInPlaceTitleWriteIsSeenByTheNextRead(savedBetween: Bool) throws {
        let ctx = try context()
        let row = stored(ctx, "Kappa Night", Self.night(10), url: "https://k.example/kappa")
        stored(ctx, "Lambda Night", Self.night(11), url: "https://l.example/lambda")
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        for p in try landing.rows() { _ = landing.fold(of: p) }
        #expect(landing.fold(of: row).groupName == "Kappa Night")

        row.groupName = "Kappa Night: Encore"
        row.runSourceURLs = ["https://k.example/kappa/encore"]
        if savedBetween { try ctx.save() }

        for p in try landing.rows() { _ = landing.fold(of: p) }
        let fold = landing.fold(of: row)
        #expect(fold.groupName == "Kappa Night: Encore"
                && fold.runFolds == ListingURL.foldedSet(["https://k.example/kappa/encore"]), Comment(rawValue:
            "a title written in place was not seen by the next read (saved between: \(savedBetween)): "
            + "the fold still says \(fold.groupName) \(fold.runSourceURLs)"))
    }

    // A key moved in place is found under its new key and no longer under its old one, saved or not. A
    // missed re-key is the dangerous direction: the new key reads as free, and a second card is written on it.
    @Test(arguments: [false, true])
    func anInPlaceReKeyIsSeenByTheKeyIndex(savedBetween: Bool) throws {
        let ctx = try context()
        let row = stored(ctx, "Kappa Night", Self.night(10), url: "https://k.example/kappa")
        try ctx.save()
        let oldKey = row.naturalKey
        let landing = ScoutLandingStore(context: ctx)
        #expect(try landing.stored(key: oldKey) === row)

        let newKey = Prospect.makeNaturalKey(groupName: "Kappa Night", performanceDate: Self.night(12),
                                             venue: Self.room)
        row.naturalKey = newKey
        if savedBetween { try ctx.save() }

        #expect(try landing.stored(key: newKey) === row, Comment(rawValue:
            "a key moved in place was not found under its new key (saved between: \(savedBetween))"))
        #expect(try landing.stored(key: oldKey) == nil, Comment(rawValue:
            "a key moved in place was still found under its old key (saved between: \(savedBetween))"))
    }

    // A row the landing inserted is found by its key, and a row deleted from the context is not, exactly as
    // a fresh fetch would answer.
    @Test func theKeyIndexTakesInsertsAndDropsDeletions() throws {
        let ctx = try context()
        let gone = stored(ctx, "Mu Night", Self.night(10), url: "https://m.example/mu")
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        _ = try landing.rows()

        let fresh = stored(ctx, "Nu Night", Self.night(11), url: "https://n.example/nu")
        landing.inserted(fresh)
        ctx.delete(gone)

        #expect(try landing.stored(key: fresh.naturalKey) === fresh)
        #expect(try landing.stored(key: gone.naturalKey) == nil, Comment(rawValue:
            "a deleted row was still answered from the key index"))
        #expect(try !landing.rows().contains { $0 === gone }, Comment(rawValue:
            "a row deleted after the rows were read was still among them"))
    }

    // MARK: a landing, counted

    // Stored rows the landing re-lists, plus rows it never touches, which only make the store bigger.
    private func seed(_ ctx: ModelContext, untouched: Int) {
        for k in 0..<4 { stored(ctx, "Relisted \(k)", Self.night(10 + k), url: "https://r.example/\(k)") }
        for k in 0..<untouched {
            stored(ctx, "Untouched \(k)", Self.night(40 + k), url: "https://u.example/\(k)")
        }
    }

    // Each source re-lists the four stored shows (the exact key arm, which is what a live re-land is almost
    // entirely) and brings two new ones.
    private func sources(_ n: Int) -> [(String, [ExtractedEvent])] {
        (0..<n).map { i in
            ("source-\(i)",
             (0..<4).map { event("Relisted \($0)", Self.night(10 + $0), url: "https://r.example/\($0)") }
             + (0..<2).map { j in
                 let n = i * 2 + j
                 return event("\(Self.newTitles[n % Self.newTitles.count]) \(n)", Self.night(20 + n),
                              url: "https://new.example/\(n)")
             })
        }
    }

    private struct Counted { var keyed = 0, validations = 0, updated = 0, inserted = 0 }

    private func land(untouched: Int, sources n: Int, policy: ScoutLandingStore.Policy) throws -> Counted {
        let ctx = try context()
        seed(ctx, untouched: untouched)
        try ctx.save()
        var counted = Counted()
        let landing = ScoutLandingStore(context: ctx, readKey: { key, ctx in
            counted.keyed += 1
            return try Prospect.stored(key: key, in: ctx)
        }, policy: policy)
        for (id, events) in sources(n) {
            let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                             today: Self.today, sourceIds: [id], landing: landing, into: ctx)
            counted.updated += outcome.updated
            counted.inserted += outcome.inserted
        }
        counted.validations = landing.foldValidations
        return counted
    }

    // No keyed lookup reaches the store while a landing runs, however many events it lands. The control is
    // the same landing read fresh per question, which is what the code did before, so a counter that never
    // moved cannot pass this (L159).
    @Test func aLandingAnswersEveryKeyedLookupFromTheWorkingSet() throws {
        let fresh = try land(untouched: 6, sources: 3, policy: .everyRead)
        let current = try land(untouched: 6, sources: 3, policy: .once)
        #expect(current.updated == fresh.updated && current.inserted == fresh.inserted
                && current.updated >= 12 && current.inserted == 6, Comment(rawValue:
            "the landing did not land what was expected: updated \(current.updated) against \(fresh.updated), "
            + "inserted \(current.inserted) against \(fresh.inserted)"))
        #expect(fresh.keyed >= 18, Comment(rawValue:
            "the fresh landing made only \(fresh.keyed) keyed fetches, so the counter is not counting"))
        #expect(current.keyed == 0, Comment(rawValue:
            "a landing sent \(current.keyed) keyed lookups to the store instead of its working set"))
    }

    // What makes the count above exhaustive: no keyed read of the show table is spelled in the two files a
    // landing runs through except through the working set. Derived from the files, so a new call site added
    // later is caught too (L96). `keyAvailability(_:in:)` and `dropNight(_:reason:now:in:)` are the two
    // conveniences that fetch by key for themselves.
    @Test func everyKeyedLookupOnTheLandingPathGoesThroughTheWorkingSet() {
        for path in ["Overture/Integration/ScoutService.swift", "Overture/Integration/ScoutExtractIngest.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) could not be read, so this measured nothing")
            let offenders = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { line in
                    let text = line.element
                    return text.contains("Prospect.stored(")
                        || (text.contains("in: context)")
                            && (text.contains("keyAvailability(") || text.contains("dropNight(")))
                }
                .map { "line \($0.offset + 1)" }
            #expect(offenders.isEmpty, Comment(rawValue:
                "\(path) fetches a show by key outside the working set at \(offenders.joined(separator: ", "))"))
        }
    }

    // How many folds a landing re-checks does not depend on how many rows the store holds: a row nothing
    // wrote is never re-checked. Before this, every read re-checked every row, so the count was the store
    // size times the reads.
    @Test func foldChecksDoNotGrowWithTheStore() throws {
        let small = try land(untouched: 6, sources: 3, policy: .once)
        let large = try land(untouched: 60, sources: 3, policy: .once)
        #expect(small.updated == large.updated && small.inserted == large.inserted && small.updated >= 12,
                Comment(rawValue: "the two landings did not land the same shows: \(small) and \(large)"))
        #expect(large.validations == small.validations, Comment(rawValue:
            "a store 54 rows larger made the landing re-check \(large.validations) folds against "
            + "\(small.validations), so the check still walks rows nothing wrote"))
    }
}
