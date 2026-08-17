import Testing
import Foundation

// #2813: `GenreGate` (#2687) blocks Keep and every Dismiss on a row reading "No genre read", and every
// genre in the vocabulary is a live performance, so an event that is not one matched none of them and
// the only way past the gate was to name a genre that is false. Dan met that on 2026-08-16 on
// "Carnegie Hall Citywide: On Screen: Verdi's Rigoletto", a film screening, and could neither keep it
// nor dismiss it: a control that refuses everything with no honest way to satisfy it (L109's shape,
// arriving as a vocabulary gap rather than a missing message).
@Suite("Not a live performance")
struct NotALivePerformanceGenreTests {

    // MARK: - The gate has an answer now

    @Test func theGateLetsARowMarkedNotALivePerformanceThrough() {
        #expect(GenreGate.blocks(discipline: "other"))
        #expect(GenreGate.blocks(discipline: ""))
        #expect(!GenreGate.blocks(discipline: Discipline.notALivePerformance.rawValue))
    }

    // It reaches the picker through `allCases`, which is what the genre editor renders, so nothing has
    // to remember to add it there.
    @Test func itIsOfferedInTheGenrePicker() {
        #expect(Discipline.allCases.contains(.notALivePerformance))
        #expect(Discipline.notALivePerformance.label == "Not a live performance")
    }

    // MARK: - What it costs the row

    // Below the high-fit cutoff, not buried: this genre is a judgement somebody made, and judgements are
    // occasionally wrong, so the row stays reachable in the longshots.
    @Test func itSinksTheRowOutOfHighFitWithoutBuryingIt() {
        #expect(Ranker.disciplinePoints(.notALivePerformance) < Ranker.disciplinePoints(.other))
        #expect(Ranker.disciplinePoints(.notALivePerformance) == -5)
    }

    // #1658: setting a genre must never be the thing that removes a card. It takes the LOOSE geographic
    // rule alongside `.other`, so a card cannot vanish under Dan's hand as he marks it.
    @Test func markingItCanNeverBeWhatRemovesTheCard() {
        #expect(!Discipline.notALivePerformance.staysInTheBoroughs)
    }

    // The sentence says the dominant fact rather than running the row through the production and profile
    // chain, which would produce "Self-produced not a live performance group, a strong-fit target".
    @Test func theFitReasonSaysWhyItIsNotAFitRatherThanArguingForIt() {
        let reason = EventClassifier.derived(discipline: .notALivePerformance, production: .selfProduced,
                                             profile: .strong, venue: "The Example Room").fitReason
        #expect(reason == "Not a live performance, so there is nothing here to shoot.")
        #expect(!reason.contains("strong-fit"))
    }

    // MARK: - What the scout reads

    private func classify(_ title: String, presenter: String? = nil) -> Discipline {
        EventClassifier.classify(ExtractedEvent(title: title, presenter: presenter, venue: "A Room")).discipline
    }

    // The row Dan was stuck on, with the presenter it actually carries on the live store.
    @Test func theRowThisWasFiledFromNowHasAGenre() {
        #expect(classify("Carnegie Hall Citywide: On Screen: Verdi's Rigoletto",
                         presenter: "Carnegie Hall Presents") == .notALivePerformance)
    }

    @Test func theScoutReadsTheWordsThatNameANonPerformance() {
        #expect(classify("A Documentary Evening") == .notALivePerformance)
        #expect(classify("An Artist Lecture") == .notALivePerformance)
        #expect(classify("Spring Exhibition") == .notALivePerformance)
        #expect(classify("A Book Launch") == .notALivePerformance)
    }

    // The ordering IS the safety argument: this pass runs after every other, including the weak
    // "musical" one, so it can only ever claim a title that would otherwise read `.other`.
    //
    // Both halves of each pair are the LIVE rows, with the presenters they actually carry, read off the
    // store on 2026-08-17 rather than invented: the lecture's genre comes from "Theatre for a New
    // Audience" and not from its title, which no fixture written from the title alone could have shown
    // (L48). The accepted cost of the same ordering is visible in the third case: a screening of an
    // opera film reads `.opera`, because "opera" is a real signal and outranks a later pass.
    @Test func aRealGenreAlwaysBeatsIt() {
        #expect(classify("Frieren: Beyond Journey's End Film Concert", presenter: "Live Nation") == .music)
        #expect(classify("Honor, An Artist Lecture by Suzanne Bocanegra Starring Lili Taylor",
                         presenter: "Theatre for a New Audience") == .theater)
        #expect(classify("On Screen: An Opera Film") == .opera)
        #expect(classify("A New Musical, With A Book Launch After") == .theater)
    }

    @Test func aTitleWithNoneOfThoseWordsIsStillUnread() {
        #expect(classify("An Evening At The Room") == .other)
    }

    // The presenter can never CREATE it, only the show's own title can. A building's name is a poor
    // witness to what is on inside it tonight (#1658), and an organisation with "Workshop" in its name
    // puts on real shows: reading that as "this is not a performance" would mark every one of them.
    @Test func anOrganisationWithOneOfThoseWordsInItsNameCannotCreateIt() {
        #expect(classify("An Evening At The Room", presenter: "The Example Workshop") == .other)
        #expect(classify("A Lecture Series", presenter: "The Example Workshop") == .notALivePerformance)
    }

    // The correction report asks `alreadyReads` so it never proposes a word the classifier already
    // matches. A non-performance word IS matched now, so it counts as read, and proposing it would be
    // telling Dan to add something that is already there.
    @Test func aNonPerformanceWordCountsAsAWordTheClassifierAlreadyReads() {
        #expect(EventClassifier.alreadyReads("screening"))
        #expect(EventClassifier.alreadyReads("exhibition"))
    }
}
