import Testing
import Foundation

// #2578: a search pattern is not a sentence, and the inventory should know that itself.
//
// `docs/copy-inventory.md` exists so a wording change shows up in a PR as the words Dan will read, and
// its whole value is that somebody reads it carefully. #2545 added `DraftGreeting`'s opener alternation
// ("hi|hello|hey|dear|good morning|...") and it was listed as a sentence Overture can say, caught only by
// a person reading the regenerated diff and then silenced with `copy-inventory:ignore-start`.
//
// The marker is the wrong direction of defence: it is opt-in, so anything nobody remembers to mark stays
// in, and every entry that is not a sentence trains the reader to skim the one artifact whose whole job
// is a careful read (L21).
@Suite("An alternation is not a sentence (#2578)")
struct CopyInventoryAlternationTests {

    private func literal(_ text: String) -> SwiftSource.Literal {
        SwiftSource.Literal(text: text, isRaw: false, line: 1)
    }

    // The real one, from DraftGreeting, which is what this rule is measured against.
    @Test("the opener alternation is not copy")
    func theOpenerAlternationIsNotCopy() {
        #expect(!CopyInventory.isCopy(literal("hi|hello|hey|dear|good morning|good afternoon|good evening")))
    }

    @Test("other alternation shapes are not copy either")
    func otherAlternationsAreNotCopy() {
        #expect(!CopyInventory.isCopy(literal("cancelled|postponed|rescheduled")))
        #expect(!CopyInventory.isCopy(literal("box office|ticket office|will call")))
    }

    // MARK: the half that matters more (L104)

    // A filter that identifies data by its SHAPE has to be tested against what it must PRESERVE, not only
    // against what it must catch, because the shape is rarely unique to its target and an over-match reads
    // exactly like the feature working.
    //
    // These are real entries from the inventory, chosen for the properties that could trip a careless
    // alternation rule: punctuation, short clauses, interpolations, and a sentence made of few words.
    @Test("real copy still counts as copy")
    func realCopyIsUntouched() {
        let mustSurvive = [
            "The show on \\(dateLabel) is dismissed as \\(reason.label)",
            "No email found",
            "Weak contact only",
            "\\(org) already has a separate card for \\(date), so this night was left alone",
            "Event passed, send a closing note",
            "1 run was left alone: it already has a separate card for a later night",
            "Sent through their form. You told Overture they replied.",
            "\\(address), replied",
            // The two that make this list able to catch an OVER-broad rule at all. Everything above is
            // pipe-free, so a rule that excluded every pipe-bearing string would keep all of them and this
            // test would pass while the filter quietly ate real copy. Measured: it does. Loosening the
            // rule to two parts of any length left every other case here green.
            "Press | media",
            "Overture writes the key as groupName|date|venue, and the run copies it back verbatim",
        ]
        for sentence in mustSurvive {
            #expect(CopyInventory.isCopy(literal(sentence)), "wrongly excluded: \(sentence)")
        }
    }

    // The measured version of the same claim, over the WHOLE checked-in list rather than a handful
    // somebody picked. Measured 2026-08-15: 0 of 1358 entries contain a pipe at all, so this rule cannot
    // cost a sentence that exists today. If a future entry legitimately carries pipes, this is what says
    // so, in the run that introduces it rather than months later.
    @Test("no sentence in the checked-in inventory is excluded by this rule")
    func theCheckedInInventoryIsUnaffected() throws {
        let text = try String(contentsOf: CopyInventory.inventoryURL, encoding: .utf8)
        let sentences = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("\"") && $0.hasSuffix("\"") }
            .map { String($0.dropFirst().dropLast()) }
        #expect(sentences.count > 1000, "the inventory could not be read, so this proved nothing")

        let lost = sentences.filter { !CopyInventory.isCopy(literal($0)) }
        #expect(lost.isEmpty, "this rule would drop real copy:\n\(lost.joined(separator: "\n"))")
    }

    // MARK: and the marker it replaces

    // The proof that the generator now does the job the marker was doing: DraftGreeting no longer carries
    // an ignore region, and its alternation still stays out. A rule that needed the marker kept beside it
    // would not have fixed anything.
    @Test("DraftGreeting needs no ignore region any more")
    func draftGreetingNeedsNoMarker() throws {
        let source = try String(contentsOf: RepoRoot.app.appendingPathComponent("Domain/DraftGreeting.swift"),
                                encoding: .utf8)
        #expect(!source.contains(SwiftSource.ignoreStart),
                "the marker is back, so either the rule regressed or something else in this file needs it")
        let found = SwiftSource.literals(in: source).filter { CopyInventory.isCopy($0) }
        #expect(found.isEmpty, "DraftGreeting contributed: \(found.map(\.text))")
    }
}
