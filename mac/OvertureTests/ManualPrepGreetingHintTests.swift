import Testing
import Foundation

// #2574: the manual prep sheet says, while Dan is typing, that a body with no greeting will be held.
//
// Since #2545 the greeting lives in the body and a body that does not open with one is held at SEND
// (`Recipient.isBlockedByGreeting`). The sheet where he types the whole email himself said nothing about
// it, so he found out afterwards, on a different screen. That round trip is the thing the manual path
// exists to avoid.
@MainActor
@Suite("The manual prep sheet warns about a missing greeting (#2574)")
struct ManualPrepGreetingHintTests {

    private let body = "I photograph performing arts in New York and saw your November programme."

    @Test("a body with no greeting gets the hint")
    func aBodyWithNoGreetingIsFlagged() {
        #expect(ManualPrepEditing.greetingHint(body: body) != nil)
    }

    @Test("a body that opens with a greeting does not")
    func aGreetedBodyIsQuiet() {
        #expect(ManualPrepEditing.greetingHint(body: "Hi Emma,\n\n\(body)") == nil)
        // The shape Dan writes himself, which #2545 taught the rule to accept. If the hint disagreed with
        // the hold about this one, it would nag him about his own opening on every hand-written email.
        #expect(ManualPrepEditing.greetingHint(body: "Marcus, hello again,\n\n\(body)") == nil)
    }

    // An empty box is already refusing with "Write the email before saving it". Two sentences about one
    // field is the #843 defect, and the second one would be telling him to greet a body he has not
    // started.
    @Test("an empty body says nothing, because the refusal already speaks")
    func anEmptyBodyIsLeftToTheRefusal() {
        #expect(ManualPrepEditing.greetingHint(body: "") == nil)
        #expect(ManualPrepEditing.greetingHint(body: "   \n  ") == nil)
        #expect(ManualPrepEditing.reasonSaveIsDisabled(email: "a@b.org", subject: "S", body: "") != nil)
    }

    // MARK: the two halves that make it honest

    // A hint, never a refusal. A sheet stricter than the gate behind it blocks input the app would
    // accept, by a rule nothing states (L99), and the send hold carries the override Dan asked for.
    @Test("it never stops the draft being saved")
    func itDoesNotBlockSaving() {
        #expect(ManualPrepEditing.canSave(email: "emma@org.org", subject: "Photographs", body: body))
        #expect(ManualPrepEditing.reasonSaveIsDisabled(email: "emma@org.org", subject: "Photographs",
                                                       body: body) == nil)
        #expect(ManualPrepEditing.refusal(email: "emma@org.org", subject: "Photographs", body: body) == nil)
    }

    // A guard and its wiring are two claims (L3). The hint can be perfect and never reach the sheet.
    //
    // Scoped to the property that draws the body field, not searched over the file: `ManualPrepSheet`
    // names `emailBody` in several places, so a file-wide match would be answered by the TextEditor's own
    // binding and would stay green with the hint deleted (L135, #2726).
    @Test("the sheet actually draws it, under the field it is about")
    func theSheetDrawsIt() throws {
        let sheet = SourceGuardHelper.source("Overture/UI/ManualPrepSheet.swift")
        let field = try #require(SourceGuardHelper.propertyBody("private var subjectAndBody: some View {",
                                                                in: sheet),
                                 "expected to find the property that draws the subject and body fields")
        #expect(SourceGuardHelper.containsCode("ManualPrepEditing.greetingHint(body: emailBody)", in: field),
                "the hint must be drawn beside the body, or it is a sentence nobody sees")
    }

    // The sheet and the send gate must be one judgment, not two that agree today. Two definitions of what
    // a greeting is, is how a hint says he is fine and the send holds anyway (L16).
    @Test("the hint agrees with the rule that actually holds the send, on every shape")
    func theHintAndTheHoldAreOneJudgment() {
        let bodies = [
            "Hi Emma,\n\nsome text",
            "Hello,\n\nsome text",
            "Dear Emma,\n\nsome text",
            "Marcus, hello again,\n\nsome text",
            "Morning Emma,\n\nsome text",
            "Sarah and Tom,\n\nsome text",
            "I photograph performing arts in New York, and I saw your programme.",
            "No greeting at all here, just a sentence that runs on for a while about photographs.",
            "Attn: Emma Robinson, Marketing\n\nHi Emma,\n\nsome text",
        ]
        for candidate in bodies {
            let hinted = ManualPrepEditing.greetingHint(body: candidate) != nil
            let greeted = DraftGreeting.opensWithAGreeting(candidate)
            #expect(hinted == !greeted,
                    "the sheet and the send hold disagree about: \(candidate.prefix(40))")
        }
    }
}
