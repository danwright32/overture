import Testing
import Foundation
@testable import Overture

// #915: one list of every sentence Overture can say to Dan.
//
// #885 moved the app's wording out of 26 SwiftUI views and into pure types, and its guard keeps it
// there. That made something newly possible: you can now enumerate the copy, because it is no longer
// assembled inline in a body somewhere. #843 (copy that says the same thing twice) and #844 (read every
// new sentence cold before it ships) are both unworkable without that list, for the same reason: you
// cannot compare wordings you cannot see side by side.
//
// These tests cover the two halves. The LEXER, which has to read Swift accurately enough that a nested
// literal inside an interpolation or an AppleScript heredoc doesn't corrupt the scan. The CLASSIFIER,
// which decides what counts as a sentence, and whose whole job is to be boringly predictable, since an
// inventory nobody trusts is an inventory nobody reads.
@Suite("Copy inventory (#915)")
struct CopyInventoryTests {

    // MARK: - The lexer

    @Test func readsAPlainLiteral() {
        #expect(SwiftSource.literals(in: #"Text("Nothing scouted yet")"#).map(\.text)
                == ["Nothing scouted yet"])
    }

    @Test func ignoresCopyQuotedInAComment() {
        // This codebase quotes its own copy in comments constantly, to explain itself. Every one of
        // those would otherwise land in the inventory as a sentence the app can say, and cannot.
        let source = """
        // it used to say "Nothing scouted yet" here
        Text("Nothing matches this filter")
        """
        #expect(SwiftSource.literals(in: source).map(\.text) == ["Nothing matches this filter"])
    }

    @Test func doesNotMistakeASlashInsideAStringForAComment() {
        #expect(SwiftSource.literals(in: #"let u = "https://danwrightphotography.com/work""#).map(\.text)
                == ["https://danwrightphotography.com/work"])
    }

    @Test func readsAnEscapedQuote() {
        #expect(SwiftSource.literals(in: #"Text("say \"go\" now")"#).map(\.text) == [#"say \"go\" now"#])
    }

    // The one that actually bit a first pass at this: an interpolation can CONTAIN a string literal
    // (`\(venue ?? "Venue TBD")`), and a scanner that just toggles on every quote ends the outer literal
    // early, then reads the code between the quotes as if it were prose. It silently yields two mangled
    // half-sentences in place of one real one, in exactly the files with the most copy in them.
    @Test func readsALiteralWhoseInterpolationHoldsItsOwnLiteral() {
        let source = #"Text("Playing \(venue ?? "Venue TBD") tonight")"#
        #expect(SwiftSource.literals(in: source).map(\.text)
                == [#"Playing \(venue ?? "Venue TBD") tonight"#])
    }

    @Test func readsAMultiLineLiteral() {
        let source = "let s = \"\"\"\ntell application \"OmniFocus\"\n    make a task\n\"\"\"\n"
        #expect(SwiftSource.literals(in: source).map(\.text)
                == ["tell application \"OmniFocus\"\n    make a task"])
    }

    // A raw string in this codebase is a regex, every time (DraftCheck's lint patterns, EventClassifier's
    // discipline matchers). Recording that it was raw is what lets the classifier drop patterns on a rule
    // about what the string IS, rather than by sniffing for backslashes and pipes and hoping.
    @Test func marksARawStringAsRaw() {
        let lits = SwiftSource.literals(in: ##"text.range(of: #"\b(band|jazz band|brass)\b"#)"##)
        #expect(lits.count == 1)
        #expect(lits.first?.isRaw == true)
    }

    // Same exemption the #885 guard makes, for the same reason: DEBUG copy is compiled out of the app Dan
    // runs, so it can never mislead him. DebugSeed and DebugStaging are nothing but fake prospect names.
    @Test func skipsDebugOnlyCopy() {
        let source = """
        Text("Real copy")
        #if DEBUG
        Text("Test Choir (debug)")
        #endif
        """
        #expect(SwiftSource.literals(in: source).map(\.text) == ["Real copy"])
    }

    // A #Preview is scaffolding for Xcode's canvas, on the same footing as DEBUG: its fixture names
    // ("Aurora Strings", "Carnegie Hall") are invented data, and Dan never sees a word of it. Left in,
    // they don't just pad the list, they file FALSE DUPLICATES: a preview's fake org name collides with
    // the real one in another view, and the duplicates section is the one part of this that has to stay
    // worth reading.
    @Test func skipsPreviewScaffolding() {
        let source = """
        Text("Real copy")
        #Preview("Draft review (sent)") {
            DraftReviewView(item: .init(groupName: "Aurora Strings"))
        }
        """
        #expect(SwiftSource.literals(in: source).map(\.text) == ["Real copy"])
    }

    // MARK: - Marked exclusions
    //
    // Not everything Overture writes is a sentence Overture says to DAN. It also writes an email to a
    // stranger, RFC822 headers to Gmail, and AppleScript to OmniFocus. Those are marked at the source
    // rather than allowlisted inside this test, so the reason sits where the copy is, and so the
    // inventory can print the exclusions rather than hiding them.

    @Test func skipsAMarkedRegionAndKeepsItsReason() {
        let source = """
        Text("App copy")
        // copy-inventory:ignore-start  outbound email: a recipient reads this, not Dan
        let body = "I'll leave it here either way."
        // copy-inventory:ignore-end
        Text("More app copy")
        """
        #expect(SwiftSource.literals(in: source).map(\.text) == ["App copy", "More app copy"])
        #expect(SwiftSource.ignoredReasons(in: source)
                == ["outbound email: a recipient reads this, not Dan"])
    }

    // An unbalanced marker means somebody opened a region and never closed it, silently swallowing the
    // rest of a file's copy. That is the failure this inventory exists to prevent, so it is loud.
    @Test func anUnclosedIgnoreRegionIsAnError() {
        let source = """
        // copy-inventory:ignore-start  outbound email
        let body = "gone"
        """
        #expect(SwiftSource.unclosedIgnoreRegion(in: source))
    }

    // MARK: - The classifier

    @Test func aSentenceIsCopy() {
        #expect(CopyInventory.isCopy(.init(text: "Nothing scouted yet", isRaw: false)))
    }

    @Test func wordsAroundAValueAreCopy() {
        #expect(CopyInventory.isCopy(.init(text: #"\(count) contacts held for a check"#, isRaw: false)))
    }

    // A bare value is a number being displayed, not a sentence being built. The RULE behind such a number
    // belongs in a model (#863), and this inventory does not pretend to see it.
    @Test func aBareValueIsNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: #"\(item.fitScore)"#, isRaw: false)))
    }

    // The cost of the "two words" rule, stated out loud rather than discovered later: a one-word label
    // (Text("Sources")) is out, because at this altitude a single word is indistinguishable from an SF
    // Symbol, a defaults key, an enum rawValue or an identifier, and letting those in would bury the
    // sentences under thousands of tokens nobody reads.
    @Test func aSingleWordIsNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: "Sources", isRaw: false)))
        #expect(!CopyInventory.isCopy(.init(text: "checkmark.seal.fill", isRaw: false)))
    }

    @Test func aRegexIsNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: #"\b(band|wind ensemble|brass)\b"#, isRaw: true)))
    }

    @Test func markupIsNotCopy() {
        #expect(!CopyInventory.isCopy(
            .init(text: "<html><body>Overture is connected to Gmail.</body></html>", isRaw: false)))
    }

    @Test func aUrlOrUserAgentIsNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: "https://danwrightphotography.com/the work", isRaw: false)))
        #expect(!CopyInventory.isCopy(
            .init(text: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", isRaw: false)))
    }

    // MARK: - The inventory, built from the real app

    @Test func scansTheRealApp() throws {
        let inventory = try CopyInventory.build()
        // A wrong root path must not pass silently, the way #887's guard did for months.
        #expect(inventory.filesScanned > 50)
        #expect(inventory.sentences.count > 200)
    }

    @Test func containsCopyFromTheCopyTypes() throws {
        let inventory = try CopyInventory.build()
        #expect(inventory.sources(of: "Nothing scouted yet") == ["Domain/EmptyState.swift"])
        #expect(inventory.sources(of: "Run the scout to comb the venue calendars. Ranked candidates land here for review.")
                == ["Domain/EmptyState.swift"])
    }

    // The first thing the list was FOR (#843). The Queue and the Archive both said "Nothing scouted yet"
    // when empty, which is wrong on the Archive: nothing was scouted is not why it is empty. #843 fixed
    // it, so that sentence is no longer a duplicate. The detector itself still works: it goes on
    // surfacing the other repeated sentences, which is what keeps the next collision visible.
    @Test func theFixedDuplicateIsGoneButTheDetectorStillWorks() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.duplicates.contains { $0.sentence == "Nothing scouted yet" })
        #expect(!inventory.duplicates.isEmpty)
    }

    // Dan's call on scope: this lists what OVERTURE says to DAN. The follow-up bodies are what Dan says
    // to a stranger, and they are guarded by the draft lint (#789) instead.
    @Test func outboundEmailIsNotInTheInventory() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.sentences.contains { $0.contains("I'll leave it here either way") })
        #expect(!inventory.sentences.contains { $0.contains("Best,\\nDan Wright") })
        // But the alert Dan reads BEFORE that email goes out is his, and stays.
        #expect(inventory.sentences.contains {
            $0.contains("This sends one follow-up right now, to this recipient only")
        })
    }

    // The draft lint searches a draft for "thrilled to" and "let me know when". Those are NEEDLES, the
    // words the linter hunts FOR, and it would never say one to Dan. What it says to him is the reason
    // ("Performative enthusiasm or an exclamation point"), and that is what belongs in the list.
    //
    // Sixty-odd needles against nine reasons: left in, one file's search terms would have been a tenth
    // of everything Overture appears to say.
    @Test func theDraftLintsSearchTermsAreNotCopy() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.sentences.contains("thrilled to"))
        #expect(!inventory.sentences.contains("let me know when"))
        #expect(inventory.sentences.contains("Performative enthusiasm or an exclamation point"))
    }

    // The failure path, and the one worth being loud about. An ignore region opened and never closed
    // hides every sentence after it, silently, in a list whose whole value is that it is complete. It
    // would look exactly like a file that had nothing to say.
    @Test func refusesAFileThatOpensAnIgnoreRegionAndNeverClosesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copy-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        // copy-inventory:ignore-start  outbound email
        let body = "This sentence would be swallowed, and so would every one after it."
        """.write(to: directory.appendingPathComponent("Unclosed.swift"),
                  atomically: true, encoding: .utf8)

        #expect(throws: CopyInventory.Failure.self) {
            try CopyInventory.build(root: directory)
        }
    }

    @Test func everyExcludedRegionSaysWhy() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.exclusions.isEmpty)
        for exclusion in inventory.exclusions {
            #expect(!exclusion.reason.isEmpty)
        }
    }

    // MARK: - The checked-in file
    //
    // The point of checking the inventory in: a PR that changes what the app says shows it in the diff,
    // in the reviewer's own words rather than as a line of Swift. That only works if the file cannot go
    // stale, so a mismatch rewrites it and fails. Run the suite again and it is green, with the change
    // sitting in `git diff` where it can be read.
    @Test func theCheckedInInventoryIsUpToDate() throws {
        let inventory = try CopyInventory.build()
        let generated = inventory.render()
        let url = CopyInventory.inventoryURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard existing != generated else { return }

        try generated.write(to: url, atomically: true, encoding: .utf8)
        Issue.record("""
            docs/copy-inventory.md was out of date, so it has been regenerated in place.

            Overture's copy changed. Read the diff (`git diff docs/copy-inventory.md`): it is every
            sentence this branch adds, removes, or rewords, in the words Dan will actually read. If it
            says what you meant it to say, commit it.
            """)
    }
}
