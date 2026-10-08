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

    private static func fingerprint<Element: ScopeObserved>(_ items: [Element]) -> Int {
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
                       cardKeys: ["a"], now: when, savesIn: nil) { rows.count }
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
                       cardKeys: [], now: when, savesIn: nil) { rows.map(\.groupName).joined(separator: "|") }
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
                       cardKeys: [], now: when, savesIn: nil) { rows.count }
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
                       cardKeys: [], now: when, savesIn: nil) { rows.map(\.naturalKey).joined(separator: "|") }
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
                       cardKeys: keys, now: when, savesIn: nil) { keys }
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
                       staleAfter: .never, savesIn: nil) { rows.count }
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
                       cardKeys: [], now: when, savesIn: nil) { rows.count }
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

    // #4106: a save into the store the derivation reads, through ANY context, rebuilds. Measured on the
    // queue: a write saved through a second context moved no identity and fired no observed field, so the
    // memo served the answer from before the save and the screen went stale (L40).
    //
    // The save count is a counter of this test's OWN, on a notification center of its own, because the
    // shared one hears every concurrently running suite's saves (L439's shape). The notification is the
    // one SwiftData posts, carrying a real context; `StoreSaveCountTests` holds the other half, that a
    // real save posts it.
    @Test func aSaveIntoTheStoreRebuildsEvenWhenNothingObservedMoved() throws {
        let c = try container()
        let ctx = ModelContext(c)
        let rows = seed(ctx, rows: 12)
        let center = NotificationCenter()
        let memo = ScopeMemo<Int>(saves: StoreSaveCount(center: center))

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows), cardKeys: [], now: when,
                       savesIn: c) { rows.count }
        }

        _ = evaluate(at: t0)
        _ = evaluate(at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, Comment(rawValue: "with no save between them the second evaluation "
                + "must be a hit, or the rebuild below proves nothing"))
        center.post(name: ModelContext.didSave, object: ModelContext(c))
        _ = evaluate(at: t0.addingTimeInterval(0.2))
        #expect(memo.builds == 2, Comment(rawValue:
            "a save into the store left the memo at \(memo.builds) builds, so it would serve the answer "
            + "from before a write saved through another context (#4106)"))
    }

    // And ONLY that store. A save into another container is somebody else's change.
    @Test func aSaveIntoAnotherStoreRebuildsNothing() throws {
        let c = try container()
        let ctx = ModelContext(c)
        let rows = seed(ctx, rows: 12)
        let center = NotificationCenter()
        let memo = ScopeMemo<Int>(saves: StoreSaveCount(center: center))

        func evaluate(at when: Date) -> Int {
            memo.value(fingerprint: Self.fingerprint(rows), cardKeys: [], now: when,
                       savesIn: c) { rows.count }
        }

        _ = evaluate(at: t0)
        center.post(name: ModelContext.didSave, object: ModelContext(try container()))
        _ = evaluate(at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, "a save into a different store rebuilt this one's answer")
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

    // #4570: one evaluation of a surface keyed the way ArchiveView and QueueView key theirs, with the card
    // half decided by the memo from the keys the last frame drew.
    private func evaluateScope(_ memo: ScopeMemo<QueueModel.Scope>, rows: [Prospect], in c: ModelContainer,
                               drawn: Set<String>, registry: QueueModel.CardKeyRegistry, at when: Date,
                               onRefetch: ScopeMemo<QueueModel.Scope>.Refetch = .rebuild) -> QueueModel.Scope {
        var fingerprint = ScopeFingerprint()
        fingerprint.add(rows)
        return memo.value(fingerprint: fingerprint, drawn: drawn, now: when, savesIn: c,
                          onRefetch: onRefetch) { keys in
            QueueModel.scope(from: rows, now: when, cardKeys: keys, cardKeyRegistry: registry)
        }
    }

    // #4570: a surface's first build is asked for no card, so the first frame builds every card it draws
    // on demand. The next evaluation adopts those cards rather than deriving the whole store again.
    //
    // #4591: and so does every LATER frame that draws a row the held answer never built, a scroll or a row
    // a removal revealed. This test asserted the opposite until then (`...AndAScrollStillDerives`), as
    // #4570's own scope choice ("this changes the mount and nothing else"), not as a decision of Dan's; the
    // reason it gave, that a scroll would be served cards nobody tracked, does not hold for an adopted card,
    // which is built again inside the answer's tracking (`aFieldOnlyAnAdoptedCardReadsStillMakesTheAnswerStale`).
    // #4591 measured that rule costing a whole second derivation every time a dismiss revealed rows.
    @Test func theFirstFramesCardsAreAdoptedAndSoAreAScrolls() throws {
        let c = try container()
        let rows = seed(ModelContext(c), rows: 12)
        let memo = ScopeMemo<QueueModel.Scope>(saves: StoreSaveCount(center: NotificationCenter()))
        let registry = QueueModel.CardKeyRegistry()

        let first = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry, at: t0)
        #expect(memo.builds == 1, "the mount must build, or nothing below measures anything")
        let drawnRows = Array(first.rows.prefix(3))
        for row in drawnRows { _ = first.cards.card(for: row) }
        #expect(first.cards.expectedFirstFrameMisses == drawnRows.count,
                "the first frame's cards were not built on demand, so this fixture is not the mount")

        let second = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry,
                                   at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, Comment(rawValue:
            "the evaluation after the first frame built the store \(memo.builds) times, so every open derives "
            + "it twice: the cards the first frame built on demand were not adopted (#4570)"))
        #expect(second.cards.requestedKeys == Set(drawnRows.map(\.id)),
                "the adopted cards were not counted as requested, so the next frame would derive again")

        // A SCROLL: one row the held answer never built, drawn beside the three it did.
        // The served answer holds the SAME store as the first, so its miss count carries the first frame's.
        let missesBefore = second.cards.expectedFirstFrameMisses
        let scrolled = Array(first.rows.prefix(4))
        for row in scrolled { _ = second.cards.card(for: row) }
        #expect(second.cards.expectedFirstFrameMisses - missesBefore == 1,
                "the fourth row was not built on demand, so this frame is not a scroll")
        let third = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry,
                                  at: t0.addingTimeInterval(0.2))
        #expect(memo.builds == 1, Comment(rawValue:
            "a frame drawing one row the held answer never built left the memo at \(memo.builds) builds, so "
            + "a scroll, or a row a removal revealed, derives the whole store again for one card (#4591)"))
        #expect(third.cards.requestedKeys == Set(scrolled.map(\.id)),
                "the scrolled-to card was not counted as requested, so the next frame would derive again")
    }

    // #4591: shows arriving under a mounted surface. The save's refetch re-announces every row BEFORE the
    // next evaluation asks for the first frame's cards, so the held answer is already marked stale when
    // adoption is asked for. A refetch that changed nothing is served (#4252), so the cards are adopted
    // in the same re-arm, and the memo builds once.
    //
    // Beside it, the two cases that must still derive, because a memo that adopts into any marked answer
    // passes the first half perfectly (L159): an edit nobody saved, and a surface that chose `.rebuild`.
    @Test func aRefetchBeforeTheFirstFramesCardsAreAskedForStillAdoptsThem() throws {
        // One store per case, so an edit one case leaves unsaved cannot reach the next.
        struct Mounted {
            let container: ModelContainer
            let rows: [Prospect]
            let memo: ScopeMemo<QueueModel.Scope>
            let registry: QueueModel.CardKeyRegistry
            let drawn: [QueueScopeRow]
            let policy: ScopeMemo<QueueModel.Scope>.Refetch
        }
        func mountDrawAndRefetch(_ policy: ScopeMemo<QueueModel.Scope>.Refetch) throws -> Mounted {
            let c = try container()
            // The MAIN context, because it is the one the memo asks whether anything is unsaved.
            let rows = seed(c.mainContext, rows: 12)
            let memo = ScopeMemo<QueueModel.Scope>(saves: StoreSaveCount(center: NotificationCenter()))
            let registry = QueueModel.CardKeyRegistry()
            let first = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry,
                                      at: t0, onRefetch: policy)
            let drawn = Array(first.rows.prefix(3))
            for row in drawn { _ = first.cards.card(for: row) }
            // What SwiftData's refetch after a save does (#4253): `willSet` on every row, nothing changed.
            for row in rows { row.withMutation(keyPath: \.groupName) {} }
            return Mounted(container: c, rows: rows, memo: memo, registry: registry, drawn: drawn, policy: policy)
        }
        func evaluate(_ m: Mounted, at offset: Double) -> QueueModel.Scope {
            evaluateScope(m.memo, rows: m.rows, in: m.container, drawn: m.registry.takeKeys(),
                          registry: m.registry, at: t0.addingTimeInterval(offset), onRefetch: m.policy)
        }

        let m = try mountDrawAndRefetch(.serveWhenNothingChanged)
        let second = evaluate(m, at: 0.1)
        #expect(m.memo.servedUnchanged == 1, Comment(rawValue:
            "the refetch was served \(m.memo.servedUnchanged) times, so it never marked the answer and the "
            + "build count below would hold for the wrong reason"))
        #expect(m.memo.builds == 1, Comment(rawValue:
            "a refetch landing before the first frame's cards were asked for left the memo at "
            + "\(m.memo.builds) builds, so shows arriving under a mounted queue derive it twice (#4591)"))
        #expect(second.cards.requestedKeys == Set(m.drawn.map(\.id)),
                "the first frame's cards were not counted as requested after the refetch")

        // STILL WATCHED after the re-arm: a field only the card reads, edited in place.
        let show = try #require(m.rows.first { $0.naturalKey == m.drawn[0].id })
        show.fitReason = "a reason edited in place"
        _ = evaluate(m, at: 0.2)
        #expect(m.memo.builds == 2, Comment(rawValue:
            "an edit to a card's field after the refetch was served left the memo at \(m.memo.builds) "
            + "builds, so the re-arm that adopted the cards stopped watching them (#4591, L40)"))

        // THE CONTROLS. An unsaved edit is a real change, not a refetch.
        let unsaved = try mountDrawAndRefetch(.serveWhenNothingChanged)
        unsaved.rows[7].groupName = "Renamed, not saved"
        _ = evaluate(unsaved, at: 0.1)
        #expect(unsaved.memo.builds == 2, Comment(rawValue:
            "an unsaved edit left the memo at \(unsaved.memo.builds) builds, so adoption served an answer "
            + "from before a change the main context still holds (L40)"))

        // And a surface that chose to rebuild on a refetch does.
        let rebuilding = try mountDrawAndRefetch(.rebuild)
        _ = evaluate(rebuilding, at: 0.1)
        #expect(rebuilding.memo.builds == 2, "a memo told to rebuild on a refetch adopted into it instead")
    }

    // #4570: an adopted card is WATCHED. Its show's `fitReason` is read by the card and by no part of the
    // row, so only the tracking adoption arms can see an edit to it; served from the memo after that edit,
    // the card would show the old reason (L40).
    @Test func aFieldOnlyAnAdoptedCardReadsStillMakesTheAnswerStale() throws {
        let c = try container()
        let rows = seed(ModelContext(c), rows: 12)
        let memo = ScopeMemo<QueueModel.Scope>(saves: StoreSaveCount(center: NotificationCenter()))
        let registry = QueueModel.CardKeyRegistry()

        let first = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry, at: t0)
        let drawn = try #require(first.rows.first)
        _ = first.cards.card(for: drawn)
        _ = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry,
                          at: t0.addingTimeInterval(0.1))
        #expect(memo.builds == 1, "the first frame's card was not adopted, so nothing below is about adoption")

        let show = try #require(rows.first { $0.naturalKey == drawn.id })
        show.fitReason = "a reason edited in place"
        _ = evaluateScope(memo, rows: rows, in: c, drawn: registry.takeKeys(), registry: registry,
                          at: t0.addingTimeInterval(0.2))
        #expect(memo.builds == 2, Comment(rawValue:
            "editing a field only the adopted card reads left the memo at \(memo.builds) builds, so the card "
            + "was adopted outside observation and would be served stale (#4570, L40)"))
    }
}
