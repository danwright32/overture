import Testing
import Foundation

// #2080. Dan, reviewing the scout queue on 2026-08-04: "i don't need to know what the pitch will say
// in the scout queue. we should remove that."
//
// The line said "Pitch will say you've photographed a few shows here: Jan 24 2026, Jun 22 2018", and
// it sat on the shared row, so it was on the Archive cards too. Its stated purpose (#1887) was to give
// Dan one moment where a name-folding error and the truth could be told apart, since the pitch asserts
// a fact about him, in his name, derived from an eight-year-old calendar. He has since settled where
// that moment lives instead, and it is not a new surface: he reads every drafted message before
// sending, so a wrong venue history claim gets caught in the draft itself.
//
// Stated over the app's whole copy rather than over one view, because the defect is Overture saying
// this ANYWHERE, and a test naming the view it used to live in would pass the moment the sentence moved
// one file sideways. This also cannot go quietly vacuous: reintroducing the sentence, in any file and
// any wording that still leads with the phrase, turns it red.
//
// The pitch itself is untouched. The email still knows how well Dan knows a room, by a completely
// separate route (`PrepQueueService.buildQueue`, which builds its own `VenueShootHistory` and sends the
// BAND alone into the prep handoff, never a count). Nothing here reaches an email.
@Suite("The queue card does not say what the pitch will say (#2080)")
struct QueueCardSaysNothingAboutThePitchTests {

    @Test func nothingOverturesaysTellsDanWhatThePitchWillSay() throws {
        let inventory = try CopyInventory.build()

        let offenders = inventory.occurrences.keys
            .filter { $0.localizedCaseInsensitiveContains("Pitch will say") }
            .sorted()

        #expect(offenders.isEmpty,
                "a card is telling Dan what the pitch will say: \(offenders.joined(separator: " | "))")
    }
}
