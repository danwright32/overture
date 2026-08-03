import Foundation
import Testing

// #875. Every scout-extract result carries a `note`: the run's own account of what made a page hard,
// and since #856 the script's honest explanation for a source the run never reached, with the tail of
// the run log attached. `ScoutExtractResults.swift` even says it is "for Dan to read".
//
// Nothing read it. It was decoded and thrown away, so a failing source showed him the GENERIC sentence
// for its verdict ("That page has not been read") while the specific reason, the only part
// that could tell him WHY, sat in a file he would have to open by hand.
//
// The note is one blob: a human sentence, then up to six lines of raw run log. Splitting them is a
// decision about what Dan reads, so it lives here and not in the view (#863/#885): a rule computed
// inside a SwiftUI body is a rule no test can reach, and this app has watched one drift twice already.
@Suite("A failing source explains itself in words Dan actually sees (#875)")
struct SourceNoteTests {

    // Verbatim shape from `mac/scripts/lib/results-guard.sh`, pinned to the real script below.
    private let guardNote = "The run exited with status 1 and produced no results for this source. "
        + "Last lines of the run log: + claude -p | Error: connection reset | exit 1"

    // The row shows the SENTENCE. That is the part he can act on.
    @Test func theRowShowsTheReasonInWordsNotTheLog() {
        #expect(SourceNote.summary(guardNote)
                == "The run exited with status 1 and produced no results for this source.")
    }

    // The log tail is kept, but out of the way (Dan's call: sentence in the row, log on hover). Losing it
    // would undo #856, which attached it precisely so the reason travels WITH the failure instead of
    // living only in a file nobody opens.
    @Test func theLogTailIsKeptForHoverRatherThanThrownAway() {
        #expect(SourceNote.detail(guardNote) == "+ claude -p | Error: connection reset | exit 1")
    }

    // A note the model wrote itself has no log tail. It is all sentence, and none of it is hidden.
    @Test func aNoteWithNoLogIsAllSentenceAndNothingIsHidden() {
        let modelNote = "This calendar lists its shows as images, so only the three with text captions "
            + "could be read."
        #expect(SourceNote.summary(modelNote) == modelNote)
        #expect(SourceNote.detail(modelNote) == nil)
    }

    // Nothing to say means nothing shown. A row that always carries a line is a row Dan learns to skip,
    // and then the one that matters gets skipped too.
    @Test func aSourceWithNothingToSaySaysNothing() {
        #expect(SourceNote.summary(nil) == nil)
        #expect(SourceNote.summary("") == nil)
        #expect(SourceNote.summary("   ") == nil)
        #expect(SourceNote.detail(nil) == nil)
    }

    // A note that is ONLY a log tail (the sentence somehow empty) must not render a blank line with a
    // silent tooltip: if the only thing we have is the log, the log IS the message.
    @Test func aNoteThatIsOnlyALogStillSaysSomething() {
        let stray = "Last lines of the run log: + claude -p | exit 137"
        #expect(SourceNote.summary(stray) == "+ claude -p | exit 137")
        #expect(SourceNote.detail(stray) == nil)
    }

    // L52: this fixture claims to be the shape the runner writes, and a fixture that only matches my
    // memory of the script can go stale the moment the script is reworded, while every test here stays
    // green against a sentence nothing produces any more.
    @Test func theFixtureAboveIsTheSentenceTheRunnerActuallyWrites() {
        let script = SourceGuardHelper.source("scripts/lib/results-guard.sh")
        #expect(!script.isEmpty, "the runner script must be readable, or this check passes vacuously")
        #expect(script.contains("produced no results for this source"))
    }
}

// #1757: one failed read, and one account of it.
//
// Measured on the live app 2026-07-29. She NYC Arts and The Cell Theatre each showed these two lines
// stacked, one directly under the other:
//
//   "The run ended before reading this page, so it has not been read. The next scout will try it again."
//   "The run exited normally but produced no results for this source. It has NOT been read, and the
//    next scout will try it again."
//
// They CONTRADICTED each other: the first says the run ended before getting to the page, the second says
// it exited normally, and Dan has no way to tell which describes what happened. And they RESTATED each
// other: "it has not been read" and "the next scout will try it again" appear in both, word for word,
// which is the #840/#843 defect one line apart.
//
// SourceNote's own design says why this is wrong: the row carries the generic WHAT and the note carries
// the specific WHY. So each line now speaks about one subject only. The app's line is about the PAGE
// (it was not read, and what happens next). The runner's note is about the RUN (how it ended), which is
// the one thing the app cannot know and the only part that changes between failures.
@Suite("A failed read is accounted for once, and without contradiction (#1757)")
struct FailedReadIsAccountedForOnceTests {
    // The lines of the runner that BUILD the note, not the whole script. A comment there may quote the
    // app's sentence to explain why it must not be repeated (this whole rule is easier to follow with
    // the other line written out beside it), and a guard that could not tell the explanation from the
    // offence would force the explanation out.
    private var noteConstruction: String {
        let script = SourceGuardHelper.source("scripts/lib/results-guard.sh")
        guard let start = script.range(of: "const why = status ==="),
              let end = script.range(of: "const out = {", range: start.upperBound..<script.endIndex)
        else { return "" }
        return String(script[start.lowerBound..<end.lowerBound])
    }

    // The app's line may not narrate the run. It is written from a stored verdict, hours or days later,
    // and it has never had any way to know whether the run crashed or finished tidily; claiming either
    // is how it came to contradict the one line that does know.
    @Test func theGenericLineSaysWhatHappenedToThePageAndNothingAboutTheRun() {
        let message = SourceFailure.verdict(.notRead).message
        #expect(message == "That page has not been read. The next scout will try it again.")
        #expect(!message.localizedCaseInsensitiveContains("run"),
                "the app's line describes the page; only the run's own note may describe the run")
    }

    // And the runner's note may not restate the page's state. Those were the two sentences that appeared
    // word for word on both lines.
    @Test func theRunnersNoteDoesNotRestateWhatTheRowAlreadySays() {
        #expect(!noteConstruction.isEmpty,
                "the note-building lines must be findable, or this passes vacuously")
        #expect(noteConstruction.contains("produced no results for this source"),
                "the note still has to say the run came back with nothing for this source")
        #expect(!noteConstruction.contains("It has NOT been read"))
        #expect(!noteConstruction.contains("next scout"))
    }

    // The cross-language claim, and the one that actually pins the defect: no sentence may be written on
    // both sides. Stated as a rule over the app's line rather than as two hand-listed phrases, so a
    // reworded line cannot quietly reintroduce the overlap in different words.
    @Test func noSentenceIsWrittenOnBothSides() {
        #expect(!noteConstruction.isEmpty,
                "the note-building lines must be findable, or this passes vacuously")
        let sentences = SourceFailure.verdict(.notRead).message
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }
        #expect(!sentences.isEmpty)
        for sentence in sentences {
            // Case-insensitively: the two copies of "the next scout will try it again" differed only by
            // the capital on the first word, which an exact match would have let through.
            #expect(noteConstruction.range(of: sentence, options: .caseInsensitive) == nil,
                    "\"\(sentence)\" is written in both the app and the runner, so the row says it twice")
        }
    }
}
