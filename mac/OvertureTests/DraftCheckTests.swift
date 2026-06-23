import Testing
@testable import Overture

// #11: a deterministic self-check over a drafted email, surfaced before it reaches Dan's
// approval, so review is judgment not cleanup. Catches AI-tells / performative enthusiasm,
// em dashes, and the two stance failures from a real drafting session: presuming the
// booking, or hedging like a cold pitch at a warm/repeat client.
@Suite("Draft self-check")
struct DraftCheckTests {
    @Test func passesTheVersionDanActuallySent() {
        let good = """
        Hi Emma,

        I'm looking forward to being there again this year. If you'd like me to photograph \
        this year's event as well, just say the word.

        Best,
        Dan
        """
        #expect(DraftCheck.findings(in: good).isEmpty)
    }

    @Test func flagsPerformativeEnthusiasmAndExclamations() {
        #expect(DraftCheck.findings(in: "I'd love to photograph this.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "I'm thrilled and can't wait.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "Looking forward to it!").contains { $0 == .performativeEnthusiasm })
    }

    @Test func flagsEmDashes() {
        #expect(DraftCheck.findings(in: "I shoot performances — and I'm local.").contains { $0 == .emDash })
    }

    @Test func flagsPresumingTheBooking() {
        #expect(DraftCheck.findings(in: "Happy to lock in the photography plans for the concert.").contains { $0 == .presumesBooking })
        #expect(DraftCheck.findings(in: "I'll plan to cover the performance.").contains { $0 == .presumesBooking })
    }

    @Test func flagsColdHedgeAtAWarmClient() {
        #expect(DraftCheck.findings(in: "If you haven't arranged a photographer yet, I'm available.").contains { $0 == .coldHedge })
    }
}
