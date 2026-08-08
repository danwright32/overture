import Testing
import Foundation

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

    // #2124. A value the sentence LEADS with is still a word of that sentence. Counting only the
    // literal words after it puts a whole category below the two-word floor, and screen reader labels
    // skew heavily this way because they usually name the value first.
    //
    // The one that got away: ReplyIdentity.RowAudience.spokenLabel, added in #2121, never entered the
    // inventory at all, and the sentence count did not move to say so.
    @Test func aValueTheSentenceLeadsWithIsStillAWord() {
        #expect(CopyInventory.isCopy(.init(text: #"\(address), replied"#, isRaw: false)))
        #expect(CopyInventory.isCopy(.init(text: #"\(count) shows"#, isRaw: false)))
    }

    // A bare value is a number being displayed, not a sentence being built. The RULE behind such a number
    // belongs in a model (#863), and this inventory does not pretend to see it.
    @Test func aBareValueIsNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: #"\(item.fitScore)"#, isRaw: false)))
    }

    // The floor still has to hold, or the fix trades one silent gap for thousands of lines of noise.
    // Two values with nothing said between them is a format string, not a sentence, and a value glued
    // to a suffix is an identifier being built.
    @Test func valuesWithNoWordsBetweenThemAreNotCopy() {
        #expect(!CopyInventory.isCopy(.init(text: #"\(first)\(second)"#, isRaw: false)))
        #expect(!CopyInventory.isCopy(.init(text: #"\(prefix)-suffix"#, isRaw: false)))
        #expect(!CopyInventory.isCopy(.init(text: #"\(dir)/\(file) exists"#, isRaw: false)))
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

    // #1029: the #986 venue-precision line ("N of M shows say where they are...") was removed from Dan's
    // view because he did not understand why it mattered. The inventory IS the canonical list of what
    // Overture can say to Dan, so its absence here is the behavioral fact that the sentence is gone: if
    // SourcePlacement.note (or any placement sentence) is ever re-added, this goes red. The scout summary
    // now leads instead with the shows waiting for review, which must be present.
    @Test func theVenuePrecisionLineIsGoneAndTheWaitingLineIsPresent() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.sentences.contains { $0.contains("shows say where they are") })
        #expect(!inventory.sentences.contains { $0.contains("out-of-town date from a New York one") })
        #expect(inventory.sources(of: "\\(n) new shows waiting for you") == ["Domain/SourceYield.swift"])
        #expect(inventory.sources(of: "1 new show waiting for you") == ["Domain/SourceYield.swift"])
    }

    // #2124: the sentence that got away, asserted against the REAL app rather than the classifier alone.
    // The classifier test above would still pass if the lexer or the writer dropped it somewhere further
    // down, and "it never reached the file" is the exact failure being fixed, so the end of the pipeline
    // is where this has to be checked.
    @Test func aSpokenLabelLeadingWithItsValueReachesTheInventory() throws {
        let inventory = try CopyInventory.build()
        #expect(inventory.sources(of: "\\(address), replied") == ["Domain/ReplyIdentity.swift"])
    }

    // The other half of the same rule: an auth header is not a sentence, and it is kept out by being
    // marked where it lives rather than by a heuristic here. Pinned because the marking is three
    // separate comments in three files, and losing one would put a token-bearing header back into the
    // list Dan cold-reads.
    @Test func theGmailAuthorizationHeaderIsNotInTheList() throws {
        let inventory = try CopyInventory.build()
        #expect(!inventory.sentences.contains { $0.contains("Bearer ") })
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

        switch CopyInventory.checkCheckedIn(existing: existing, generated: generated,
                                            regenerate: CopyInventory.regenerationRequested()) {
        case .upToDate:
            return
        case .regenerated(let contents, let message):
            try contents.write(to: url, atomically: true, encoding: .utf8)
            Issue.record(Comment(rawValue: message))
        case .stale(let message):
            Issue.record(Comment(rawValue: message))
        }
    }

    // MARK: - #1994: a run that was not asked to change anything changes nothing
    //
    // Regenerating in place is genuinely useful when the change is a real copy change. The hazard is
    // what it does during a run that was never meant to edit the repo. Hit twice on 2026-08-02 while
    // working #1967: the app was temporarily broken with a `fatalError("...")` to prove the unhosted
    // suite survives a launch fault, that string counted as app copy, and the inventory was rewritten
    // to include it. The file then sat modified in the working tree looking exactly like an ordinary
    // edit, and a `git add -A` would have shipped a claim about what the app says to Dan that no human
    // wrote and no reviewer would question.
    //
    // The decision is pure so it can be tested without a real stale file and without writing anything.

    @Test func anUnchangedInventoryIsLeftAlone() {
        #expect(CopyInventory.checkCheckedIn(existing: "same", generated: "same", regenerate: false)
                == .upToDate)
        #expect(CopyInventory.checkCheckedIn(existing: "same", generated: "same", regenerate: true)
                == .upToDate)
    }

    // THE regression. A stale file without an explicit request produces no contents to write at all,
    // so there is nothing the caller could accidentally put on disk.
    @Test func aStaleInventoryIsReportedWithoutBeingRewritten() throws {
        let outcome = CopyInventory.checkCheckedIn(existing: "old", generated: "new", regenerate: false)
        guard case .stale(let message) = outcome else {
            Issue.record("expected .stale, got \(outcome)")
            return
        }
        // And it hands over the way to fix it. A refusal that does not say how to proceed just moves
        // the problem (L80).
        #expect(message.contains("REGENERATE_COPY_INVENTORY=1"))
    }

    @Test func anExplicitRequestRegeneratesAndSaysSo() throws {
        let outcome = CopyInventory.checkCheckedIn(existing: "old", generated: "new", regenerate: true)
        guard case .regenerated(let contents, let message) = outcome else {
            Issue.record("expected .regenerated, got \(outcome)")
            return
        }
        #expect(contents == "new")
        #expect(message.contains("git diff"))
    }

    // The message has to say WHAT changed, or a failing run tells someone the file is stale and leaves
    // them to work out whether that is their copy change or an accident of the run.
    @Test func theStaleReportNamesTheSentencesThatMoved() {
        let existing = """
        line one
        "A sentence that is going away"
        shared
        """
        let generated = """
        line one
        "A sentence that is arriving"
        shared
        """
        let outcome = CopyInventory.checkCheckedIn(existing: existing, generated: generated,
                                                   regenerate: false)
        guard case .stale(let message) = outcome else {
            Issue.record("expected .stale, got \(outcome)")
            return
        }
        #expect(message.contains("A sentence that is arriving"))
        #expect(message.contains("A sentence that is going away"))
    }

    // A long diff is truncated rather than dumped whole: the inventory is over a thousand lines, and a
    // rename near the top shifts every line after it, so an untruncated report would bury the finding.
    @Test func aVeryLongDifferenceIsTruncatedAndSaysItWas() {
        let existing = (1...500).map { "old line \($0)" }.joined(separator: "\n")
        let generated = (1...500).map { "new line \($0)" }.joined(separator: "\n")
        guard case .stale(let message) = CopyInventory.checkCheckedIn(existing: existing,
                                                                      generated: generated,
                                                                      regenerate: false) else {
            Issue.record("expected .stale")
            return
        }
        #expect(message.contains("more"))
        #expect(message.count < 4_000, "the report is \(message.count) characters; it should be bounded")
    }

    // The opt-in is read from the environment, and only an affirmative value counts. An unset variable
    // must never read as "yes", or the guard is back where it started.
    @Test func onlyAnAffirmativeEnvironmentValueRequestsRegeneration() {
        #expect(CopyInventory.regenerationRequested(environment: ["REGENERATE_COPY_INVENTORY": "1"]))
        #expect(CopyInventory.regenerationRequested(environment: [:]) == false)
        #expect(CopyInventory.regenerationRequested(environment: ["REGENERATE_COPY_INVENTORY": "0"]) == false)
        #expect(CopyInventory.regenerationRequested(environment: ["REGENERATE_COPY_INVENTORY": ""]) == false)
    }

    // The spelling that actually reaches the test process, and therefore the one that matters.
    // xcodebuild does not hand its own environment to the test runner: it forwards only variables
    // prefixed `TEST_RUNNER_`, with the prefix stripped. Measured against a real run on 2026-08-08,
    // the bare name reached nothing and the request was silently ignored, leaving the file stale.
    // Without this the escape hatch would exist and not work, which is worse than not having one.
    @Test func theForwardedSpellingIsTheOneThatReachesATestRun() {
        #expect(CopyInventory.regenerationRequested(
            environment: ["TEST_RUNNER_REGENERATE_COPY_INVENTORY": "1"]))
        #expect(CopyInventory.regenerationRequested(
            environment: ["TEST_RUNNER_REGENERATE_COPY_INVENTORY": "0"]) == false)
    }

    // And the failure message quotes a command that works, rather than one that reads correctly and
    // silently does nothing.
    @Test func theStaleMessageQuotesTheCommandThatActuallyReachesTheTest() {
        guard case .stale(let message) = CopyInventory.checkCheckedIn(existing: "old",
                                                                      generated: "new",
                                                                      regenerate: false) else {
            Issue.record("expected .stale")
            return
        }
        #expect(message.contains("TEST_RUNNER_REGENERATE_COPY_INVENTORY=1"))
    }

    // MARK: - Relative source paths survive a symlinked root (#1491)
    //
    // FileManager's enumerator hands back each file in canonical (/private/var/...) form while the root
    // derived from #filePath stays in /var/... form. The old unanchored replacingOccurrences strip then
    // removed the root chunk from the MIDDLE of the file path, fusing the leading /private onto the first
    // component ("/privateDomain/EmptyState.swift"). It never showed in a normal checkout under /Users (no
    // symlink in the path), only in a $TMPDIR worktree, which is exactly where verify-and-merge-branch.sh
    // runs the suite, so it failed CopyInventoryTests on every Mac branch there. This pins the
    // relativization against a real symlinked root, so the regression fails in any checkout.
    @Test func relativizesASourcePathAddressedThroughASymlinkedRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("copyinv-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let sub = real.appendingPathComponent("Sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("Fixture.swift")
        try "Text(\"x\")".write(to: file, atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        // The root is the symlink; the file is addressed through the real directory, the mismatch the
        // enumerator produces. The relative name must still come out clean.
        #expect(CopyInventory.relativePath(of: file, under: link) == "Sub/Fixture.swift")
    }

    @Test func relativizesAPlainNestedSourcePath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("copyinv-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Domain")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("EmptyState.swift")
        try "".write(to: file, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        #expect(CopyInventory.relativePath(of: file, under: root) == "Domain/EmptyState.swift")
    }
}
