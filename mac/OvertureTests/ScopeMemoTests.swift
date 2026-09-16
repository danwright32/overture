import Testing
import Foundation
import SwiftData

// #3879: the memo that makes a body evaluation which changed nothing cost nothing.
//
// THE THREE CONTROLS ARE THE POINT, and they are asserted rather than assumed. A memo that always
// returns its cached answer passes "a second call builds nothing" perfectly and is a bug that shows
// stale rows (L159, L40). So every case that MUST rebuild is here beside the case that must not, and
// the suite fails if the harness could not have seen a rebuild at all.
@MainActor
@Suite("The Archive's scope is derived from its inputs, not per body evaluation (#3879)")
struct ScopeMemoTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self])
    }

    private func seed(_ ctx: ModelContext, rows: Int) -> [Prospect] {
        var made: [Prospect] = []
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Weill Recital Hall",
                             performanceDate: "2027-05-0\(1 + (n % 9))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            ctx.insert(p)
            made.append(p)
        }
        try? ctx.save()
        return made
    }

    /// A fixed instant, so nothing here is measuring the clock (L130, L290).
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func fingerprint<Element: AnyObject>(_ items: [Element]) -> Int {
        var f = ScopeFingerprint()
        f.add(items)
        return f.finalized()
    }

    @Test func aSecondEvaluationThatChangedNothingBuildsNothing() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<Int>()

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: ["a"], now: when) { rows.count }
        }

        _ = evaluate(at: t0)
        #expect(memo.builds == 1, "the first evaluation must build, or nothing below measures anything")
        _ = evaluate(at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, "a second evaluation that changed no input must build nothing")
    }

    @Test func aFieldEditedInPlaceRebuilds() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<String>()

        // The derivation READS a field, which is what puts that field under observation. A memo whose
        // build closure reads nothing would never be marked stale, and the assertion below would be
        // about the fixture rather than about the memo.
        func evaluate(at when: Date) -> String {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: [], now: when) { rows.map(\.groupName).joined(separator: "|") }
        }

        let first = evaluate(at: t0)
        #expect(memo.builds == 1)
        rows[3].groupName = "Renamed Ensemble"
        let second = evaluate(at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 2, "a field edited in place changes no pointer, so only observation can see it")
        #expect(second != first, "and the answer must be the new one, not the cached one")
        #expect(second.contains("Renamed Ensemble"))
    }

    @Test func anInsertedRowRebuilds() throws {
        let ctx = ModelContext(try container())
        var rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<Int>()

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: [], now: when) { rows.count }
        }

        #expect(evaluate(at: t0) == 12)
        rows.append(contentsOf: seed(ctx, rows: 1))
        #expect(evaluate(at: t0.addingTimeInterval(0.1)) == 13,
                "an insert changes the fingerprint, so the answer must be the new count")
        #expect(memo.builds == 2)
    }

    @Test func aRowSwappedForAnotherRebuildsEvenThoughTheCountIsTheSame() throws {
        let ctx = ModelContext(try container())
        var rows = seed(ctx, rows: 12)
        let spare = seed(ctx, rows: 1)[0]
        let memo = ScopeMemo<String>()

        func evaluate(at when: Date) -> String {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: [], now: when) { rows.map(\.naturalKey).joined(separator: "|") }
        }

        let before = evaluate(at: t0)
        rows[5] = spare
        let after = evaluate(at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 2, "a count is blind to a row swapped for another, which is why the key is not a count")
        #expect(after != before)
    }

    @Test func aChangeOfCardKeysRebuilds() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<Set<String>>()

        func evaluate(keys: Set<String>, at when: Date) -> Set<String> {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: keys, now: when) { keys }
        }

        _ = evaluate(keys: ["a", "b"], at: t0)
        _ = evaluate(keys: ["a", "b"], at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, "the same keys are the same frame's request")
        #expect(evaluate(keys: ["c"], at: t0.addingTimeInterval(0.2)) == ["c"],
                "a scroll asks for different cards, so the answer must be built for those")
        #expect(memo.builds == 2)
    }

    @Test func aDerivationThatReadsNoClockIsNeverStaleFromTheClockAlone() throws {
        // #3742: the other half of the window, and it is asserted rather than assumed. A memo over a
        // derivation with no clock in it must NOT rebuild on age, because there is nothing for a window
        // to protect: it would be one rebuild of the whole table per window, bought for nothing.
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<Int>()

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows), cardKeys: [], now: when,
                       staleAfter: .never) { rows.count }
        }

        _ = evaluate(at: t0)
        _ = evaluate(at: t0.addingTimeInterval(ScopeMemo<Int>.staleAfterSeconds * 1_000))
        #expect(memo.builds == 1, """
            a memo told its derivation reads no clock rebuilt on age anyway, so `.never` is not the \
            choice it says it is
            """)
    }

    @Test func anAnswerOlderThanTheWindowRebuilds() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 12)
        let memo = ScopeMemo<Int>()

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows),
                       cardKeys: [], now: when) { rows.count }
        }

        _ = evaluate(at: t0)
        _ = evaluate(at: t0.addingTimeInterval(ScopeMemo<Int>.staleAfterSeconds - 0.01))
        #expect(memo.builds == 1, "inside the window the cached answer stands")
        _ = evaluate(at: t0.addingTimeInterval(ScopeMemo<Int>.staleAfterSeconds + 0.01))
        #expect(memo.builds == 2, """
            past the window it rebuilds, because the derivation reads the clock and this memo does not \
            claim to know everything in it the clock reaches
            """)
    }

    @Test func theFingerprintIsCheapEnoughToBeWorthTaking() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx, rows: 1_233)

        // Not a threshold on the machine: an absolute millisecond figure here would be measuring
        // whatever else is running (L224). The claim is a RATIO against work of the same shape in the
        // same run, which is what makes it a statement about this code.
        func seconds(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }
        _ = Self.fingerprint(rows)
        let fingerprint = (0..<5).map { _ in seconds { _ = Self.fingerprint(rows) } }.sorted()[2]
        // The cheapest whole-store thing the real derivation does: read one field from every row.
        _ = rows.map(\.groupName)
        let oneFieldRead = (0..<5).map { _ in seconds { _ = rows.map(\.groupName) } }.sorted()[2]

        #expect(fingerprint < oneFieldRead * 3, """
            hashing \(rows.count) identities took \(fingerprint)s against \(oneFieldRead)s to read one \
            field from each. The memo is only worth having while its key is far cheaper than the \
            derivation it decides about, and reading one field is the smallest whole-store step that \
            derivation takes.
            """)
    }
}
