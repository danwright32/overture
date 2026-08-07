import Testing
import Foundation

// #2168. A row showed `Reach out now` directly above an `Answer` button, two things saying the same
// thing, and nothing in the suite noticed. The cold read in AGENTS.md is the only thing that catches
// copy saying itself twice, and it depends entirely on a person doing it, which is why the class keeps
// recurring (#840, #841, the nine in #843, and #2166).
//
// This is a net under that read, not a replacement. It catches ONE shape, the one that has now recurred
// four times: a status line sitting immediately beside the control that acts on that status.
//
// The rule it enforces is the product rule, not a spelling rule: when a control appears only under some
// condition, a status line that says the same thing must yield to it under that same condition. Checking
// mere presence would be useless, because the fix keeps both in the view and makes one conditional.
//
// Deliberately a hand-maintained list of pairs. Nothing here tries to understand English; a pair is
// added when a person notices two things saying one thing, and the guard's job is only to stop that
// exact pair coming back.
@Suite("A status line must not restate the button beside it (#2168)")
struct DuplicateStatusLineGuardTests {

    // MARK: the detector itself, against sources written to be unambiguous

    @Test func aStatusLineRenderedBesideItsButtonIsFlagged() {
        let body = """
        VStack {
            Text(Clock.timingLabel(next: next))
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        let findings = DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer])
        #expect(findings.count == 1, "an unconditional status line beside its own button must be caught")
    }

    // The fix shape: the label survives, because it is the only thing saying WHEN on a row with no
    // reply waiting. It simply yields when the button is showing.
    @Test func aStatusLineThatYieldsToTheButtonIsClean() {
        let body = """
        VStack {
            if !Panel.isOffered(for: r) {
                Text(Clock.timingLabel(next: next))
            }
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).isEmpty)
    }

    // The failure path that keeps the guard from being a nuisance: on a container where the button is
    // not offered at all, the status line is the ONLY thing saying anything, and must not be flagged.
    @Test func aStatusLineAloneIsNeverFlagged() {
        let body = """
        VStack {
            Text(Clock.timingLabel(next: next))
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).isEmpty)
    }

    @Test func aButtonAloneIsNeverFlagged() {
        let body = """
        VStack {
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).isEmpty)
    }

    // Nesting, because the real view puts the label inside a VStack inside an HStack, and a guard that
    // loses track of depth would either miss the instance or flag the fix.
    @Test func aLabelNestedDeeperThanItsGateIsStillSeenAsCovered() {
        let body = """
        HStack {
            VStack {
                if !Panel.isOffered(for: r) {
                    Group {
                        Text(Clock.timingLabel(next: next))
                    }
                }
                if Panel.isOffered(for: r) {
                    Button(Copy.answer) { open() }
                }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).isEmpty)
    }

    // A view that reads its gate ONCE into a local, which is the ordinary way to avoid evaluating a
    // predicate twice in a body, must still read as covered. Without this the guard punishes the tidier
    // spelling of the very fix it is asking for, which is how a guard trains people to work around it.
    @Test func aGateReadIntoALocalStillCounts() {
        let body = """
        VStack {
            let offered = Panel.isOffered(for: r)
            if !offered {
                Text(Clock.timingLabel(next: next))
            }
            if offered {
                Button(Copy.answer) { open() }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).isEmpty)
    }

    // But only a local that actually came FROM the gate. A same-named local holding something else must
    // not launder an unconditional label into looking covered.
    @Test func aLocalThatDidNotComeFromTheGateDoesNotCount() {
        let body = """
        VStack {
            let offered = r.somethingElseEntirely
            if !offered {
                Text(Clock.timingLabel(next: next))
            }
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).count == 1)
    }

    // A condition that is about something else entirely does not count as yielding. Without this the
    // guard would pass on any label that happened to sit inside any `if` at all.
    @Test func anUnrelatedConditionDoesNotCountAsYielding() {
        let body = """
        VStack {
            if r.outreachChannel == .email {
                Text(Clock.timingLabel(next: next))
            }
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        #expect(DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).count == 1,
                "yielding means yielding to THIS button, not sitting under any condition at all")
    }

    // The finding has to name what is said twice, in the words Dan reads, or whoever hits it has to
    // reverse-engineer the complaint from two source tokens.
    @Test func theFindingSaysWhatIsBeingSaidTwice() {
        let body = """
        VStack {
            Text(Clock.timingLabel(next: next))
            if Panel.isOffered(for: r) {
                Button(Copy.answer) { open() }
            }
        }
        """
        let finding = DuplicateStatusLine.findings(in: body, pairs: [Self.reachOutNowVersusAnswer]).first
        #expect(finding?.contains("Reach out now") == true)
        #expect(finding?.contains("Answer") == true)
    }

    // MARK: the real view

    // #2166 is the live instance. This is the assertion the guard exists for, and it is the one that was
    // watched failing against the pre-#2166 source before the fix was written.
    @Test func theReachedOutRowSaysEachThingOnce() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!source.isEmpty)
        let body = try String(SourceGuard.functionBody(named: "reachedOutRow", in: source))
        let findings = DuplicateStatusLine.findings(in: body, pairs: DuplicateStatusLine.knownPairs)
        #expect(findings.isEmpty, "\(findings.joined(separator: "\n"))")
    }

    // And the pair list is not allowed to quietly empty itself, which would make the check above pass
    // for the wrong reason forever (L63).
    @Test func thePairListStillHasPairsInIt() {
        #expect(!DuplicateStatusLine.knownPairs.isEmpty,
                "the guard asserts nothing at all with an empty pair list (#2168)")
    }

    private static let reachOutNowVersusAnswer = DuplicateStatusPair(
        label: "Clock.timingLabel", button: "Copy.answer", gate: "Panel.isOffered",
        says: "Reach out now", alsoSays: "Answer")
}
