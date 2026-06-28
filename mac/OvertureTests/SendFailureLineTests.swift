import Testing
import Foundation
@testable import Overture

// #316: the one place that turns a persisted send failure (Prospect.sendError) into a short inline
// line, so the Follow-ups rows and DraftReviewView show an identical, honest indicator instead of a
// fading toast that's easy to miss.
@Suite("Send failure line (#316)")
struct SendFailureLineTests {
    @Test func noErrorProducesNoLine() {
        #expect(SendFailureLine.text(for: nil) == nil)
    }

    @Test func anEmptyErrorProducesNoLine() {
        // A blank/whitespace error is not a real failure to surface.
        #expect(SendFailureLine.text(for: "   ") == nil)
    }

    @Test func anErrorBecomesAConciseLine() {
        #expect(SendFailureLine.text(for: "Network timeout") == "Send failed: Network timeout")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(SendFailureLine.text(for: "  The server rejected the message  ")
            == "Send failed: The server rejected the message")
    }
}
