import Testing
import Foundation

// #3479: the archive's empty state must not derive the whole store to decide which of two sentences
// to draw.
//
// Measured on the running Aug 24 build against the live store, 2026-09-02: `ArchiveView.emptyState`
// weighed 1,535 main-thread samples and `ArchiveView.items` 1,530 of them. So a search matching NOTHING
// still built all 1,139 rows, through QueueModel.items, QueueItem.init, FormPitch.state(of:) and
// DraftCheck.blockingFindings, purely to answer "are there any rows at all".
//
// It is a SECOND derivation, not the one behind the filter: `content` already derived the corpus to
// learn `filtered.isEmpty`, and then the empty branch derived it again. On the refreshed fixture one
// rebuild is 533ms (QueueRebuildCostTests, 2026-09-02), so the empty path paid roughly double.
//
// WHY THE ANSWER IS FREE. `QueueModel.items(from:)` gives one card per show handed to it, so
// `items.count` is always `prospects.count` and `items.isEmpty` is always `prospects.isEmpty`. The question the empty state asks is answerable from the @Query array's own
// count, which reads no rows at all.
//
// A source guard rather than a timing one: what changed is only how much work happens to produce the
// same two sentences, so no behavioural test can go red to green here. A stopwatch would measure what
// else this Mac is running (L224).
@MainActor
@Suite("The archive's empty state derives nothing (#3479)")
struct ArchiveEmptyStateDerivesNothingGuardTests {
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }

    @Test func theEmptyStateDoesNotReachTheDerivation() {
        #expect(!archiveView.isEmpty, "ArchiveView.swift could not be read, so this measured nothing")
        guard let empty = SourceGuardHelper.propertyBody("private var emptyState: some View {",
                                                         in: archiveView) else {
            Issue.record("expected to find ArchiveView.emptyState")
            return
        }
        // Read as CODE, with comments stripped, which is the whole reason `SwiftSource.scannableLines`
        // exists. Matching the raw property body was this guard's first form and it stayed red after the
        // fix landed: the comment explaining the fix necessarily says `items` several times, so the
        // assertion was answered by prose ABOUT the thing rather than by the thing (L103, L135).
        let code = SwiftSource.scannableLines(in: empty).map(\.code).joined(separator: "\n")
        #expect(!code.contains("items"),
                Comment(rawValue: "ArchiveView.emptyState reaches the whole-store derivation to decide "
                        + "which sentence to draw. It is a one-to-one map over the @Query array, so the "
                        + "count answers it without building a single row."))
    }

    // The positive half, so the guard cannot be satisfied by an empty state that draws nothing at all.
    @Test func theEmptyStateStillChoosesBetweenBothSentences() {
        guard let empty = SourceGuardHelper.propertyBody("private var emptyState: some View {",
                                                         in: archiveView) else {
            Issue.record("expected to find ArchiveView.emptyState")
            return
        }
        #expect(empty.contains("EmptyState.archive(hasAnyItems:"),
                "the empty state still asks which of the two sentences to draw")
    }

    // The equivalence the fix rests on, asserted rather than assumed: the derivation is a one-to-one
    // map, so a row count taken before it equals the count after it. If that ever stops being true, the
    // empty state's cheap answer becomes the wrong answer, and this is what says so (L70).
    @Test func theDerivationIsOneToOneWithItsInput() {
        let source = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(!source.isEmpty)
        // Found by NAME through `bodyOfFunction`, never by a `propertyBody` marker on the signature.
        // `SourceGuardMarkerIntegrityTests` refused the first version for exactly that: `propertyBody`
        // counts braces from its marker, so a marker stopping mid-signature starts the scan inside the
        // parameter list and only balances at the end of the whole type. The "body" it returned was
        // every line of the file below that point, which of course contains the map, so the assertion
        // agreed with itself whatever the function did (L70). It was hollow and it passed.
        // #3654 MOVED THIS FROM THE SOURCE TO THE BEHAVIOUR, because the source stopped being able to
        // say it. The builder no longer ends in a map at all: it walks the shows once, building a cheap
        // row for each and a card only for the ones something is about to draw. Any needle over that loop
        // would assert a SPELLING, while what Archive relies on is the ANSWER (L63).
        //
        // So it is asked of the arm Archive actually calls. `QueueModel.items(from:)` requests every
        // card, so one comes out per show in, and `items.count` is still `prospects.count`. The day
        // somebody narrows that arm, this goes red with a number rather than with a missing string.
        let shows = (0..<7).map {
            Prospect(naturalKey: "k\($0)", groupName: "Show \($0)", discipline: "choral", venue: nil,
                     performanceDate: nil, sourceListingURL: nil, priorRelationship: "none",
                     production: "self", profile: "strong", coverage: "likely_uncovered",
                     fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                     possibleMatchSource: nil, possibleMatchName: nil)
        }
        #expect(QueueModel.items(from: shows).count == shows.count,
                Comment(rawValue: "QueueModel.items is no longer one-to-one with its input. "
                        + "ArchiveView.emptyState answers 'are there any rows' from the input's count on "
                        + "the strength of that, so it is now answering a different question."))
        #expect(QueueModel.items(from: [Prospect]()).isEmpty)
    }
}
