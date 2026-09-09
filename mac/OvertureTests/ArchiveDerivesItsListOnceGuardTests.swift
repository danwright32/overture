import Testing
import Foundation

// #3492: the archive must derive its filtered list ONCE per render, not once per reader.
//
// `filtered` was a computed property, and Swift does not memoise one between accesses. It was read
// twice in the same body pass, at `ArchiveView.swift:142` (`Text("\(filtered.count)")` in `header`)
// and `:165` (`if filtered.isEmpty` in `content`), so every render of the archive ran the whole
// 1,139 row derivation twice, empty search or not. #3479 removed a THIRD read on the empty path;
// these two remained and are on every path.
//
// One rebuild is 533ms on the refreshed fixture (`QueueRebuildCostTests`, 2026-09-02), of which the
// whole-store precomputations are about a tenth and the per row map the rest, so halving the number
// of derivations is worth roughly what making one of them lazy would be, for none of the risk.
//
// A second reason beyond cost: two independent derivations of one query can in principle disagree,
// so the count beside the "Archive" title and the list beneath it were computed separately. One
// derivation removes that shape.
//
// A SOURCE guard rather than a timing one, on `ArchiveEmptyStateDerivesNothingGuardTests`'s
// precedent: what changes is only how much work produces the same screen, so no behavioural test can
// go red to green here, and a stopwatch would measure what else this Mac is running (L224).
@MainActor
@Suite("The archive derives its list once per render (#3492)")
struct ArchiveDerivesItsListOnceGuardTests {
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }

    // Read as CODE with comments stripped. A guard matched against raw text is answered by prose
    // ABOUT the thing, and the comments above the fix necessarily name the derivation (L103, L135).
    private var code: String {
        SwiftSource.scannableLines(in: archiveView).map(\.code).joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // CALL sites, never the declaration. Counting every mention read the `func filteredItems()` line
    // as a second call and reported 2 for the correct code, which would have made the fix
    // unreachable: the guard demanded a number the right answer cannot produce.
    private func callSites(of name: String) -> Int {
        SwiftSource.scannableLines(in: archiveView)
            .map(\.code)
            .filter { $0.contains("\(name)(") && !$0.contains("func \(name)(") }
            .count
    }

    // #3655 Phase 5: BOTH derivations, not just the filter.
    //
    // The whole-store work moved: `makeScope()` is now the pass over every show in the store, and
    // `filteredItems(_:)` is the filter and sort over the rows it produced. Guarding only the second
    // would leave the expensive one free to be re-run per reader, which is exactly the defect #3492 was
    // filed for, one function along (L30, L387: the likeliest place to repeat a defect class is the
    // change that fixes it).
    @Test func theDerivationRunsExactlyOncePerRender() {
        #expect(!archiveView.isEmpty, "ArchiveView.swift could not be read, so this measured nothing")
        let calls = callSites(of: "filteredItems")
        #expect(calls == 1,
                Comment(rawValue: "ArchiveView calls filteredItems() \(calls) times. It is a filter and "
                        + "a sort over every row in the store, and it must run once per render pass, "
                        + "bound in `body` and handed to the readers that need it."))
    }

    @Test func theWholeStorePassRunsExactlyOncePerRender() {
        #expect(!archiveView.isEmpty, "ArchiveView.swift could not be read, so this measured nothing")
        let calls = callSites(of: "makeScope")
        #expect(calls == 1,
                Comment(rawValue: "ArchiveView calls makeScope() \(calls) times. It is the pass over "
                        + "every show in the store and it yields the card store the rows draw through, "
                        + "so a second call is a second whole-store derivation AND a second card store "
                        + "whose registry the first one's rows never reach (#3655)."))
    }

    @Test func bodyIsTheOneThatDerivesIt() {
        guard let body = SourceGuardHelper.propertyBody("var body: some View {", in: archiveView) else {
            Issue.record("expected to find ArchiveView.body")
            return
        }
        let bodyCode = SwiftSource.scannableLines(in: body).map(\.code).joined(separator: "\n")
        // Compared as a COUNT, never as `contains` over the whole body, so a failure prints the number
        // rather than the file. The first form of this suite printed all 279 lines four times over.
        let scope = occurrences(of: "let scope = makeScope()", in: bodyCode)
        #expect(scope == 1,
                Comment(rawValue: "ArchiveView.body binds the pass \(scope) times. The rows on screen and "
                        + "the cards drawn into them must be two halves of ONE derivation (#3655)."))
        let bound = occurrences(of: "let filtered = filteredItems(scope.rows)", in: bodyCode)
        #expect(bound == 1,
                Comment(rawValue: "ArchiveView.body binds the derived list \(bound) times. It must derive "
                        + "once and bind it, so the readers below receive a value rather than each "
                        + "running the derivation."))
    }

    // The positive half, so the guards above cannot be satisfied by a screen that derives once because
    // it stopped drawing one of the two readers. Asserted inside `body`, against the BOUND name, so a
    // reader handed `filteredItems()` directly fails here as well as on the call count.
    @Test func bothReadersAreHandedTheBoundValue() {
        guard let body = SourceGuardHelper.propertyBody("var body: some View {", in: archiveView) else {
            Issue.record("expected to find ArchiveView.body")
            return
        }
        let bodyCode = SwiftSource.scannableLines(in: body).map(\.code).joined(separator: "\n")
        let header = occurrences(of: "header(filtered: filtered)", in: bodyCode)
        let content = occurrences(of: "content(filtered: filtered, cards: scope.cards)", in: bodyCode)
        #expect(header == 1,
                Comment(rawValue: "the header is handed the bound list \(header) times; it must receive "
                        + "the value `body` derived, not run the derivation itself"))
        #expect(content == 1,
                Comment(rawValue: "the list is handed the bound list \(content) times; it must receive "
                        + "the value `body` derived, not run the derivation itself"))
    }

    // Both readers take it as a parameter, so neither can quietly go back to reaching for a property.
    @Test func bothReadersTakeItAsAParameter() {
        // #3655: `[QueueScopeRow]`, and the type is part of the needle deliberately. A reader taking
        // `[QueueItem]` again would be handed a bound value correctly and would be handed CARDS, which is
        // the whole-store card build this phase removed.
        let header = occurrences(of: "private func header(filtered: [QueueScopeRow])", in: code)
        let content = occurrences(of: "private func content(filtered: [QueueScopeRow],", in: code)
        #expect(header == 1, "the header must take the derived list as a parameter")
        #expect(content == 1, "the list must take the derived list as a parameter")
    }

    // The regression shape this guard exists for, and the one the call count alone cannot see: a
    // computed `var filtered` reintroduced over `filteredItems()` leaves the call count at one while
    // every reader of it derives the store again (L63).
    @Test func noComputedPropertyReDerivesTheList() {
        let computed = occurrences(of: "var filtered", in: code)
        #expect(computed == 0,
                Comment(rawValue: "ArchiveView holds \(computed) computed `filtered` properties. Swift "
                        + "does not memoise one between accesses, so each reader pays the whole "
                        + "derivation. Bind it once in `body` and pass the value down."))
    }
}
