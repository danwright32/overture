import Foundation
import Testing
@testable import Overture

// #875. Every scout-extract result carries a `note`: the run's own account of what made a page hard,
// and since #856 the script's honest explanation for a source the run never reached, with the tail of
// the run log attached. `ScoutExtractResults.swift` even says it is "for Dan to read".
//
// Nothing read it. It was decoded and thrown away, so a failing source showed him the GENERIC sentence
// for its verdict ("The run ended before reading this page") while the specific reason, the only part
// that could tell him WHY, sat in a file he would have to open by hand.
//
// The note is one blob: a human sentence, then up to six lines of raw run log. Splitting them is a
// decision about what Dan reads, so it lives here and not in the view (#863/#885): a rule computed
// inside a SwiftUI body is a rule no test can reach, and this app has watched one drift twice already.
@Suite("A failing source explains itself in words Dan actually sees (#875)")
struct SourceNoteTests {

    // Verbatim shape from `mac/scripts/lib/results-guard.sh`.
    private let guardNote = "The run exited with status 1 and produced no results for this source. "
        + "It has NOT been read, and the next scout will try it again. "
        + "Last lines of the run log: + claude -p | Error: connection reset | exit 1"

    // The row shows the SENTENCE. That is the part he can act on.
    @Test func theRowShowsTheReasonInWordsNotTheLog() {
        #expect(SourceNote.summary(guardNote) == "The run exited with status 1 and produced no results "
                + "for this source. It has NOT been read, and the next scout will try it again.")
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
}
