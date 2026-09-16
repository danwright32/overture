import Testing
import Foundation

// #3677: the subject line, which no check of any kind had ever read.
//
// Dan, 2026-09-07, from the draft review card: "email subjects shouldn't end in punctuation". The card
// read "Photographing The ATF Cabaret at The Green Room 42." A subject is a LABEL rather than a
// sentence, and the stop is the one thing in the pitch a stranger sees before opening anything.
//
// The bigger half is why nothing caught it. Every DraftCheck finding reads the BODY, and neither call
// site ever passed a subject, so this was the only piece of outbound copy in the product with no reader
// at all. The formula it came from is `docs/prep-runbook.md`, which carried the stop INSIDE the quotes,
// so the drafter reproduced the example rather than the rule (L562).
//
// Confirmed on live data, 2026-09-07: the stored `ZORIGINALDRAFTSUBJECT` for the Cabaret Superstar row
// is "Photographing A SHARP's Cabaret Superstar at The Green Room 42."
@Suite("A draft's subject line has a reader (#3677)")
struct DraftSubjectCheckTests {

    // THE DEFECT, in the shape Dan met it.
    @Test("it flags a subject that ends in a full stop")
    func flagsATrailingFullStop() {
        #expect(DraftCheck.subjectFindings(in: "Photographing The ATF Cabaret at The Green Room 42.")
            .contains(.subjectEndsInPunctuation))
    }

    // The ordinary compliant subject, which is the half that decides whether this ships: a rule that
    // fires on the common case gets switched off within a day (L93).
    @Test("it passes a subject that ends in a word")
    func passesAPlainSubject() {
        #expect(DraftCheck.subjectFindings(in: "Photographing The ATF Cabaret at The Green Room 42")
            .isEmpty)
    }

    // The rule is about the LAST character, never punctuation anywhere. A subject legitimately carries an
    // apostrophe, an ampersand and a comma inside it, and all three are in real subjects this app writes.
    @Test("punctuation INSIDE a subject is not the finding")
    func internalPunctuationIsFine() {
        #expect(DraftCheck.subjectFindings(in: "Photographing Bargemusic's Bach & Beyond at the Boathouse")
            .isEmpty)
        #expect(DraftCheck.subjectFindings(in: "Photographing Trio Azura, Washington Debut at Weill Recital Hall")
            .isEmpty)
    }

    // A question mark and an exclamation point are the SAME finding, not a different one: a sentence mark
    // on a label. `performativeEnthusiasm` catches a stray "!" in the body and structurally cannot see
    // one here, because it is never given the subject.
    @Test("a question mark and an exclamation point are the same finding")
    func otherSentenceMarksCountToo() {
        #expect(DraftCheck.subjectFindings(in: "Photographing your November concert?")
            .contains(.subjectEndsInPunctuation))
        #expect(DraftCheck.subjectFindings(in: "Photographing your November concert!")
            .contains(.subjectEndsInPunctuation))
        for mark in [",", ";", ":"] {
            #expect(DraftCheck.subjectFindings(in: "Photographing your November concert\(mark)")
                .contains(.subjectEndsInPunctuation))
        }
    }

    // #1141's rule on this half: a mark that belongs to the SHOW'S OWN NAME was not put there by the
    // drafter. This is a real show in Dan's store, not a hypothetical.
    @Test("a mark that is part of the show's own title is not the drafter's")
    func aTitlesOwnMarkIsExempt() {
        #expect(DraftCheck.subjectFindings(in: "Photographing Nihao Broadway!", title: "Nihao Broadway!")
            .isEmpty)
        // ...and the stop after that same title still fires, so the exemption covers the title's mark
        // and not the whole subject.
        #expect(DraftCheck.subjectFindings(in: "Photographing Nihao Broadway! at The Green Room 42.",
                                           title: "Nihao Broadway!")
            .contains(.subjectEndsInPunctuation))
    }

    // With no title supplied nothing is exempted, which is the honest answer for a caller that never said
    // what the show is called. A caller that has not been told cannot claim a mark belongs to a name it
    // never saw (L98, L11).
    @Test("with no title given, nothing is exempt")
    func noTitleExemptsNothing() {
        #expect(DraftCheck.subjectFindings(in: "Photographing Nihao Broadway!")
            .contains(.subjectEndsInPunctuation))
    }

    // Trailing whitespace does not hide the mark, and an empty or blank subject is not a finding: there
    // is nothing there to end in anything.
    @Test("whitespace is trimmed, and an empty subject is not a finding")
    func whitespaceAndEmptiness() {
        #expect(DraftCheck.subjectFindings(in: "Photographing your concert.  \n")
            .contains(.subjectEndsInPunctuation))
        #expect(DraftCheck.subjectFindings(in: "").isEmpty)
        #expect(DraftCheck.subjectFindings(in: "   ").isEmpty)
    }

    // ADVISORY, deliberately. #789's bar for a blocker is a fact about the text that cannot
    // false-positive, and a trailing character does clear that bar, but the cost of a wrong block is
    // Dan's time on a send and the cost of a wrong warning is a glance (#3677's own recommendation).
    @Test("it warns rather than blocking the send")
    func itIsAdvisory() {
        #expect(!DraftIssue.subjectEndsInPunctuation.isBlocking)
    }

    // The BODY path is untouched: a subject rule must not start reading the body, and a body finding
    // must not start reading the subject. Two checks, two inputs.
    @Test("the subject rule says nothing about a body")
    func theBodyPathIsUntouched() {
        let body = "Hello,\n\nI'm Dan Wright, a photographer here in NYC."
        #expect(!DraftCheck.findings(in: body).contains(.subjectEndsInPunctuation))
    }
}
