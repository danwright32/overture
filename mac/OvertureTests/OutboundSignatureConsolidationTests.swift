import Testing

// #1144: the plain-text sign-off used to be pasted into FollowUp and ConversationReminder bodies (and
// cold drafts had none). It now lives in ONE place, appended at the send layer (GmailMessage, from
// OutboundSignature). These pin that no body producer carries its own sign-off any more, so a body can't
// double it and every surface gets the one styled signature.
@Suite("Outbound bodies carry no inline sign-off (#1144)")
struct OutboundSignatureConsolidationTests {
    private func hasSignoff(_ body: String) -> Bool {
        body.contains("Best,") || body.contains("Dan Wright Photography")
    }

    @Test func followUpNudgesEndAtTheirLastSentence() {
        for attempt in [1, FollowUpConfig().maxFollowUps] {
            let body = FollowUp.nudgeBody(contactName: "Sam", groupName: "The Choir",
                                          venue: "Merkin Hall", attempt: attempt)
            #expect(!hasSignoff(body), "follow-up attempt \(attempt) still carries an inline sign-off")
        }
    }

    // #2397: the per-state re-touch bodies went with the states that chose their wording, so the closing
    // note is the only conversation-track email left to check.
    @Test func theClosingNoteEndsAtItsLastSentence() {
        let closing = PostEventPrompt.closingNudgeBody(contactName: "Sam", performanceDate: "2026-11-16",
                                                       venue: "Merkin Hall")
        #expect(!hasSignoff(closing))
    }

    // The one source still holds the plain-text fallback, so the sign-off didn't vanish, it moved.
    @Test func theSignoffStillExistsInItsOneSharedSource() {
        #expect(OutboundSignature.plainFallback.plainText.contains("Dan Wright Photography"))
    }
}
