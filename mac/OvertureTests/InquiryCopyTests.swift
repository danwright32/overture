import Testing
import Foundation
@testable import Overture

@Suite("Inquiry copy")
struct InquiryCopyTests {
    @Test func replyTitleNamesTheInquirer() {
        #expect(InquiryCopy.replyTitle(to: "Ada Lovelace") == "Reply to Ada Lovelace")
    }

    @Test func subtitleJoinsWhicheverPartsAreKnown() {
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: "Weill Recital Hall") == "Gala at Weill Recital Hall")
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: nil) == "Gala")
        #expect(InquiryCopy.rowSubtitle(event: "Gala", venue: "  ") == "Gala")
        #expect(InquiryCopy.rowSubtitle(event: "", venue: "Weill") == "at Weill")
        #expect(InquiryCopy.rowSubtitle(event: "  ", venue: nil) == "")
    }

    @Test func stateReflectsLifecycle() {
        #expect(InquiryCopy.rowState(sentAt: nil, replied: false) == "Awaiting your first reply")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: false) == "Sent, waiting to hear back")
        #expect(InquiryCopy.rowState(sentAt: Date(), replied: true) == "They replied")
    }
}
