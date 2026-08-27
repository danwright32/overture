import Foundation
import Testing

// #3155: a sentence written as two literals joined with `+` reached the cold read as two fragments.
//
// `docs/copy-inventory.md` records the LITERAL, so a sentence assembled in the source landed there as its
// pieces and the sentence Dan actually reads appeared nowhere. The cold read is the only thing that
// catches the #840/#843 class, and it cannot catch what it cannot see.
//
// Hit twice in one session, 2026-08-23. `GmailReconnectCopy` (#2967) composed both reconnect sentences
// from a shared `cause` fragment and landed as `"\(cause), so nothing was sent..."`;
// `AppNotices.responsesNotUnderstood` (#2888) did the same. Both were rewritten as single literals once
// the diff was read, which is the right fix and is exactly the thing nobody will remember next time.
//
// TWO HALVES, and only one of them is resolvable. A `+` of two literals is decidable from the source and
// is now joined. A value interpolated into a literal is not, and no static reading can supply the words,
// so those are NAMED in the document's own section rather than sitting in the list looking whole. Naming
// them is the point: the cold read asks whether a sentence tells Dan anything the line beside it did not,
// and that question cannot be answered about a line with a hole in it.
@Suite("A sentence built from two literals is one sentence (#3155)")
struct ComposedSentencesInTheInventoryTests {

    private func literals(_ source: String) -> [SwiftSource.Literal] {
        SwiftSource.literals(in: source, skipping: [])
    }

    private func composedTexts(_ source: String) -> [String] {
        CopyInventory.composed(literals(source)).map(\.text)
    }

    // MARK: - What counts as joined

    @Test func twoLiteralsJoinedOnOneLineAreOneSentence() {
        #expect(composedTexts(#"let line = "Nothing was sent, " + "so nobody has heard from you.""#)
                == ["Nothing was sent, so nobody has heard from you."])
    }

    // The shape the real defect was written in: the `+` starts the next line.
    @Test func aConcatenationBrokenAcrossLinesIsStillOneSentence() {
        #expect(composedTexts("""
        static let line = "Gmail refused the send, "
            + "so nothing went out."
        """) == ["Gmail refused the send, so nothing went out."])
    }

    // A comment between the halves is transparent, because a comment never reaches the code scan at all.
    @Test func aCommentBetweenTheHalvesDoesNotBreakTheJoin() {
        #expect(composedTexts("""
        let line = "Gmail refused the send, "   // #2967
            + "so nothing went out."
        """) == ["Gmail refused the send, so nothing went out."])
    }

    @Test func threeLiteralsJoinInOrder() {
        #expect(composedTexts(#"let l = "one " + "two " + "three""#) == ["one two three"])
    }

    // MARK: - What must NOT be joined, which is the half that would corrupt the list

    @Test func twoArgumentsAreTwoSentences() {
        #expect(composedTexts(#"f("The first thing.", "The second thing.")"#)
                == ["The first thing.", "The second thing."])
    }

    @Test func aValueBetweenThemBreaksTheJoin() {
        #expect(composedTexts(#"let l = "before " + name + " after""#) == ["before ", " after"])
    }

    @Test func twoSeparateCallsAreNotOneSentence() {
        #expect(composedTexts(#"let l = Text("Keep") + Text("Dismiss")"#) == ["Keep", "Dismiss"])
    }

    // Arithmetic beside a literal must not arm the join for whatever literal comes next.
    @Test func arithmeticDoesNotArmTheJoin() {
        #expect(composedTexts("""
        let n = width + height
        let a = "The first thing."
        let b = "The second thing."
        """) == ["The first thing.", "The second thing."])
    }

    // MARK: - Joined BEFORE isCopy, which is the ordering the fix depends on

    // `isCopy` refuses a one-word literal, because at this altitude one word cannot be told from an SF
    // Symbol or a defaults key. Two one-word halves of a real sentence are exactly that shape, so asking
    // first would drop the sentence and leave nothing to join.
    @Test func aSentenceWhoseHalvesAreEachOneWordSurvives() {
        let parts = literals(#"let l = "Nothing " + "sent""#)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { !CopyInventory.isCopy($0) })
        let joined = CopyInventory.composed(parts)
        #expect(joined.count == 1)
        #expect(CopyInventory.isCopy(joined[0]))
    }

    // A raw literal anywhere in a group makes the whole group a regex rather than a sentence, so the
    // group is refused as one thing rather than half of it slipping in.
    @Test func aRawHalfMakesTheWholeGroupARegex() {
        let joined = CopyInventory.composed(literals(##"let l = #"\d+"# + " shows found""##))
        #expect(joined.count == 1)
        #expect(joined[0].isRaw)
        #expect(!CopyInventory.isCopy(joined[0]))
    }

    // MARK: - The half that cannot be resolved is named rather than omitted

    @Test func aSentenceCarryingAValueIsListedOnItsOwn() {
        var inventory = CopyInventory.Inventory()
        inventory.occurrences["\\(cause), so nothing was sent."] = ["GmailReconnectCopy.swift"]
        inventory.occurrences["Nothing was sent, so nobody has heard from you."] = ["A.swift"]

        #expect(inventory.carryingAValue == ["\\(cause), so nothing was sent."])

        // Counted in the header rather than listed a second time: 510 of the app's 1434 sentences carry
        // a value, measured 2026-08-27, so a list of them would be a third of the document repeated, and
        // the hole is already visible in each line. What was missing was any statement of how much of
        // this document is templates rather than words.
        let rendered = inventory.render()
        #expect(rendered.contains("1 of the 2 below hold a"))
    }

    @Test func anInventoryWithNoHolesSaysZeroRatherThanNothing() {
        var inventory = CopyInventory.Inventory()
        inventory.occurrences["Nothing was sent, so nobody has heard from you."] = ["A.swift"]
        #expect(inventory.carryingAValue.isEmpty)
        #expect(inventory.render().contains("0 of the 1 below hold a"))
    }

    // MARK: - The live claim

    // The app really does write sentences this way, so this is a fix rather than a rule about a shape
    // nobody uses. Measured 2026-08-27: 36 files under mac/Overture carry a line beginning with `+ "`.
    @Test func theAppReallyComposesSentencesThisWay() {
        let joined = AppSourceWalk.appFiles().flatMap {
            SwiftSource.literals(in: $0.text, skipping: []).filter(\.joinedToPrevious)
        }
        #expect(joined.count > 40, "found only \(joined.count) joined literals; the scan is broken")
    }
}
