import Testing
import Foundation
import SwiftData

// #2131: a reply Dan typed himself must not claim to be an edit of something.
//
// applyReplyDraftEdit set replyDraftEditedByDan unconditionally, which was true when the only route to a
// reply body was the AI drafter and Dan editing over it. Now that he writes them himself from the reply
// panel, that flag fires on a reply that was never edited because there was nothing to edit: the card
// would say "Edited" about words that had no earlier version (L11).
//
// It also decides the lint, so a hand-written reply would silently skip the check on what has just become
// the default path for every reply.
@MainActor
@Suite("A hand-written reply says so")
struct HandWrittenReplyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(_ ctx: ModelContext) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        ctx.insert(r)
        return r
    }

    // The default path now: nothing was there, so nothing was edited.
    @Test func writingFromNothingIsWrittenNotEdited() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.applyReplyDraftEdit("Tuesday works. I'll bring the 85mm.")
        #expect(r.replyDraftWrittenByDan)
        #expect(!r.replyDraftEditedByDan)
        #expect(r.replyDraftBody == "Tuesday works. I'll bring the 85mm.")
    }

    // Changing an AI draft is genuinely an edit, and still records as one.
    @Test func changingAnAiDraftIsAnEdit() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "The AI's attempt."
        r.applyReplyDraftEdit("Tuesday works. I'll bring the 85mm.")
        #expect(r.replyDraftEditedByDan)
        #expect(!r.replyDraftWrittenByDan)
        // The AI's version is kept as the learning baseline, which is the whole point of the pair.
        #expect(r.originalReplyDraftBody == "The AI's attempt.")
    }

    // An empty existing draft is nothing to edit either, so it counts as writing.
    @Test func writingOverAnEmptyDraftIsStillWriting() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = ""
        r.applyReplyDraftEdit("Tuesday works.")
        #expect(r.replyDraftWrittenByDan)
        #expect(!r.replyDraftEditedByDan)
    }

    // Editing his OWN words a second time leaves it his: it never becomes an edit of an AI draft that
    // never existed.
    @Test func revisingHisOwnWordsStaysHisOwn() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.applyReplyDraftEdit("Tuesday works.")
        r.applyReplyDraftEdit("Tuesday works, and I'll bring the 85mm.")
        #expect(r.replyDraftWrittenByDan)
        #expect(!r.replyDraftEditedByDan)
        #expect(r.originalReplyDraftBody == nil, "there was never an AI version to learn from")
    }

    // #2143: sending the AI's draft back exactly as written is not an edit of it.
    //
    // Newly reachable, and newly wrong, now that the reply panel opens on the draft already waiting.
    // While the compose box was always empty, the only text that could reach this call was something Dan
    // had typed, so "he changed it" was safe to assume. It no longer is: pressing Send on words he left
    // alone would claim on the card that he edited them, and would switch off the lint on a draft nobody
    // has read (L11, a message may claim only what its check measured).
    @Test func sendingAnAiDraftBackUnchangedIsNotAnEdit() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "The AI's attempt."
        r.applyReplyDraftEdit("The AI's attempt.")
        #expect(!r.replyDraftEditedByDan)
        #expect(!r.replyDraftWrittenByDan)
        #expect(r.originalReplyDraftBody == nil, "nothing was edited, so there is no pair to learn from")
        #expect(r.replyDraftBody == "The AI's attempt.")
    }

    // The lint follows from that: words he never touched are still checked.
    @Test func anAiDraftSentBackUnchangedIsStillLinted() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "What venue is this at, and what date?"
        r.applyReplyDraftEdit("What venue is this at, and what date?")
        #expect(!RecipientSnapshot(r).replyDraftFindings(title: "G", knownsDate: true, knownsVenue: true).isEmpty)
    }

    // MARK: what the card says about it

    @Test func theCardNamesWhoWroteIt() throws {
        let ctx = ModelContext(try container())
        let mine = contact(ctx)
        mine.applyReplyDraftEdit("Mine.")
        #expect(RecipientSnapshot(mine).replyAuthorLabel == "Written by you")

        let edited = contact(ctx)
        edited.replyDraftBody = "The AI's attempt."
        edited.applyReplyDraftEdit("Changed.")
        #expect(RecipientSnapshot(edited).replyAuthorLabel == "Edited")

        let untouched = contact(ctx)
        untouched.replyDraftBody = "Straight from the drafter."
        #expect(RecipientSnapshot(untouched).replyAuthorLabel == nil)
    }

    // MARK: what the PANEL says about it (#2177)

    // The panel opens on the draft already waiting (#2143). When that draft came from the unattended
    // classify run, Dan opens a box he left empty and finds text in it with nothing saying who wrote it,
    // and words he takes for his own get read differently from words he knows a model wrote.
    @Test func anUntouchedAiDraftInTheBoxSaysWhoWroteIt() {
        #expect(ReplyPanel.draftAuthorNote(typed: "Straight from the drafter.",
                                           seeded: "Straight from the drafter.",
                                           writtenByDan: false, editedByDan: false) == "Written by AI")
    }

    // His own words gain no line. "Written by you" on words he just typed says nothing he does not know,
    // and the panel is already dense (#843).
    @Test func hisOwnWordsGainNoLine() {
        #expect(ReplyPanel.draftAuthorNote(typed: "Tuesday works.", seeded: "Tuesday works.",
                                           writtenByDan: true, editedByDan: false) == nil)
    }

    // Nor do words he has already changed: they are partly his, so the line would claim a model wrote
    // what he is looking at.
    @Test func aDraftHeHasEditedGainsNoLine() {
        #expect(ReplyPanel.draftAuthorNote(typed: "Changed.", seeded: "Changed.",
                                           writtenByDan: false, editedByDan: true) == nil)
    }

    // Typing over the draft withdraws the line as he types, because the box stops holding the model's
    // words the moment he changes them.
    @Test func typingOverTheDraftWithdrawsTheLine() {
        #expect(ReplyPanel.draftAuthorNote(typed: "Tuesday works, and I'll bring the 85mm.",
                                           seeded: "Straight from the drafter.",
                                           writtenByDan: false, editedByDan: false) == nil)
    }

    // An empty box gains no line either: there is no author to name.
    // #2845: the line WITHDRAWS as he types, asserted as far as this harness can reach, with the part
    // it cannot reach named rather than left as a passing test.
    //
    // #2845 filed this as "nothing asserts it disappears once Dan edits". By the time it was picked up
    // that was true of one case only: `aneditedDraftGainsNoLineOnScreen` above covers the STORED flag,
    // and `HandWrittenReplyTests.typingOverTheDraftWithdrawsTheLine` covers the rule for `typed != seeded`.
    // What is left is that rule REACHING THE SCREEN while he types, which is a separate claim from the
    // rule being right (L3) and is the sequence he is actually in: an AI draft in the box, no flag
    // written yet, and him typing over it.
    //
    // MEASURED 2026-09-04: ViewInspector's `setInput` does NOT take on this view. After calling it, the
    // editor's own `input()` still reads the original draft, so nothing typed reaches `body_` and the
    // panel is rendering the state it started in. A test written that way would have been asserting
    // about a case it never produced (L159), so it is not written that way.
    //
    // What CAN be asserted is that the sheet feeds the LIVE typed text into the rule rather than the
    // stored draft, which is the whole of the wiring: `body_` is what the editor binds to, and the unit
    // test above owns what the rule does with it. Drawing the typed state itself needs a harness that
    // can drive input, which is #3511.
    @Test func theSheetJudgesTheLineFromWhatIsInTheBoxNowRatherThanTheStoredDraft() throws {
        let source = SourceGuardHelper.source("Overture/UI/ReplySheet.swift")
        // A computed PROPERTY rather than a function, so it is read by its marker: `functionBody`
        // answers `.functionNotFound` for it, which is the check refusing rather than passing (L98).
        let body = try #require(SourceGuardHelper.propertyBody("var draftAuthorLine: some View {", in: source))
        #expect(body.contains("typed: body_"), """
            ReplySheet no longer judges the author line from the text in the box, so "Written by AI"             can sit above sentences Dan typed himself (#2177, #2845).
            """)
        #expect(body.contains("seeded: seeded"), """
            ReplySheet no longer compares against what the box was GIVEN, which is the only thing that             can tell his words from words it handed him and he left alone (#2845).
            """)
    }

    @Test func anEmptyBoxGainsNoLine() {
        #expect(ReplyPanel.draftAuthorNote(typed: "", seeded: "",
                                           writtenByDan: false, editedByDan: false) == nil)
    }

    // The three states are the Archive card's three, said in its vocabulary rather than a second one.
    // Two of them are already named there and stay unsaid here; only the third is new.
    @Test func thepanelDoesNotGrowASecondVocabularyForTheseStates() throws {
        let ctx = ModelContext(try container())
        let untouched = contact(ctx)
        untouched.replyDraftBody = "Straight from the drafter."
        #expect(RecipientSnapshot(untouched).replyAuthorLabel == nil,
                "the Archive card still says nothing about an untouched draft")
        #expect(ReplyPanelCopy.aiWroteThisDraft == "Written by AI")
    }

    // MARK: the lint

    // Dan's own words are not linted, which is the same rule his edits already got, and for the same
    // reason: the lint flags a draft for asking about a date or venue the show already knows, and he is
    // entitled to write whatever he means. Stated as a deliberate decision rather than inherited by
    // accident from a flag that happened to be set.
    @Test func hisOwnWordsAreNotLinted() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.applyReplyDraftEdit("What venue is this at, and what date?")
        #expect(RecipientSnapshot(r).replyDraftFindings(title: "G", knownsDate: true, knownsVenue: true).isEmpty)
    }

    // An untouched AI draft is still linted, so the check that exists to catch the drafter asking for
    // something the show already carries keeps working.
    @Test func anUntouchedAiDraftIsStillLinted() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "What venue is this at, and what date?"
        #expect(!RecipientSnapshot(r).replyDraftFindings(title: "G", knownsDate: true, knownsVenue: true).isEmpty)
    }
}
