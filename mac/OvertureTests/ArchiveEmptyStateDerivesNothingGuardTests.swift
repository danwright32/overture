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
// WHY THE ANSWER IS FREE. `QueueModel.items(from:)` ends in `return prospects.map { ... }`, a
// one-to-one map, so `items.count` is always `prospects.count` and `items.isEmpty` is always
// `prospects.isEmpty`. The question the empty state asks is answerable from the @Query array's own
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
        guard let items = SourceGuardHelper.propertyBody("static func items(from prospects: [Prospect],",
                                                         in: source) else {
            Issue.record("expected to find QueueModel.items(from:)")
            return
        }
        #expect(items.contains("return prospects.map {"),
                Comment(rawValue: "QueueModel.items no longer ends in a one-to-one map over its input. "
                        + "ArchiveView.emptyState answers 'are there any rows' from the input's count on "
                        + "the strength of that, so it is now answering a different question."))
    }
}
