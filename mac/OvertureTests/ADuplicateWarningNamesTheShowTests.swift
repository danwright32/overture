import Testing
import Foundation
import SwiftData

// #4042: the duplicate contact warning BLOCKS a send and, until now, said only that the address was
// "already pitched for a show at this venue". Dan was told a collision existed and left to find it
// himself, on a screen that does not show the other card.
//
// WHY THE SENTENCE GOT VAGUER RATHER THAN BETTER. It used to say "a NEARBY show", which was true while
// `DuplicateContactGuard` had only its three day arm. #3636 gave the guard a same-show arm reaching to
// `RunGrouping.sameShowGapDays` (56), whose commonest case is a multi-weekend run four weeks out, so
// the word stopped being true and was dropped rather than replaced (L11). The result was honest and
// less useful than what it replaced, which is the wrong direction for a warning that blocks a send.
//
// WHAT MAKES IT NAMEABLE. The guard now returns WHICH row it matched rather than whether it matched,
// the key rides the recipient from prep to review, and the pass resolves it against the same corpus
// table the arrival tags use. A row merged away in between resolves to nothing and the old sentence
// stands, which is the L200 shape: a record pointing at another record re-checks it when it is read.
@MainActor
@Suite("The duplicate contact warning names the show (#4042)")
struct ADuplicateWarningNamesTheShowTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private static let venue = "The Green Room 42"

    @discardableResult
    private func row(_ ctx: ModelContext, _ title: String, night: String,
                     email: String?) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: Self.venue),
                         groupName: title, discipline: "theater", venue: Self.venue,
                         performanceDate: night, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        if let email {
            p.setRecipients([Recipient(id: email, email: email, name: "Ana Ruiz", role: "producer",
                                       provenance: .presenter)])
        }
        try? ctx.save()
        return p
    }

    // THE CLAIM. The guard answers with the row it matched, not merely that it matched one.
    @Test func theGuardSaysWhichRowItMatched() throws {
        let ctx = try context()
        let pitched = row(ctx, "The ATF Cabaret", night: "2026-10-03", email: "ana@example.org")
        let arriving = row(ctx, "The ATF Cabaret", night: "2026-10-04", email: nil)

        let match = DuplicateContactGuard.duplicate(email: "ana@example.org", venue: Self.venue,
                                                    performanceDate: arriving.performanceDate,
                                                    groupName: arriving.groupName,
                                                    excludingProspectKey: arriving.naturalKey,
                                                    in: ctx)
        #expect(match?.prospectKey == pitched.naturalKey,
                "the guard said only THAT it matched, which is what left the sentence unable to name anything")
    }

    // And it still refuses what it always refused: a different venue is a legitimate second pitch.
    @Test func adifferentVenueIsStillNotADuplicate() throws {
        let ctx = try context()
        row(ctx, "The ATF Cabaret", night: "2026-10-03", email: "ana@example.org")
        let elsewhere = Prospect(naturalKey: "elsewhere", groupName: "The ATF Cabaret",
                                 discipline: "theater", venue: "54 Below",
                                 performanceDate: "2026-10-04", sourceListingURL: nil,
                                 priorRelationship: "none", production: "self", profile: "strong",
                                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                 matchedClientName: nil, possibleMatchSource: nil,
                                 possibleMatchName: nil, status: .new)
        ctx.insert(elsewhere)
        try ctx.save()

        #expect(DuplicateContactGuard.duplicate(email: "ana@example.org", venue: "54 Below",
                                                performanceDate: "2026-10-04",
                                                groupName: "The ATF Cabaret",
                                                excludingProspectKey: "elsewhere", in: ctx) == nil)
    }

    // THE SENTENCE, in all three of its states, because the difference between them is the whole point
    // (L11): it names the show and the night when both resolve, the show alone when the night does not,
    // and falls back to the wording it had before this change when the row is gone.
    @Test func theSentenceNamesWhatItResolvedAndNoMore() {
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz", show: "The ATF Cabaret",
                                                  night: "2026-10-03")
                == "Ana Ruiz may already be pitched for The ATF Cabaret on Oct 3; blocked from sending.")
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz", show: "The ATF Cabaret", night: nil)
                == "Ana Ruiz may already be pitched for The ATF Cabaret; blocked from sending.")
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz", show: nil, night: nil)
                == "Ana Ruiz may already be pitched for a show at this venue; blocked from sending.")
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz", show: "", night: "2026-10-03")
                == "Ana Ruiz may already be pitched for a show at this venue; blocked from sending.",
                "an empty title must not draw a sentence naming nothing")
    }

    // THE JOURNEY, which is the half a unit test of the guard cannot show: the key has to survive from
    // the recipient to the card the review screen reads.
    @Test func theCardCarriesTheResolvedShowAndNight() throws {
        let ctx = try context()
        let pitched = row(ctx, "The ATF Cabaret", night: "2026-10-03", email: "ana@example.org")
        let arriving = row(ctx, "Legends: A New Musical", night: "2026-10-04", email: "ana@example.org")
        let recipient = try #require(arriving.recipients.first)
        recipient.looksLikeDuplicateContact = true
        recipient.looksLikeDuplicateContactKey = pitched.naturalKey
        try ctx.save()

        let cards = QueueModel.items(from: [arriving, pitched],
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        let card = try #require(cards.first { $0.id == arriving.naturalKey })
        let contact = try #require(card.contacts.first)
        #expect(contact.duplicateOfTitle == "The ATF Cabaret")
        #expect(contact.duplicateOfNight == "2026-10-03")
    }

    // THE FIRST LINK, which neither of the two above can reach: the IMPORTER has to record the key when
    // it writes the flag. A mutation making it write nil SURVIVED the suite as first written, because
    // every test here set the key by hand (L718: a value a test supplies proves the reader, never the
    // writer).
    @Test func theimporterRecordsWhichRowTheDuplicateIs() throws {
        let ctx = try context()
        let pitched = row(ctx, "The ATF Cabaret", night: "2026-10-03", email: "ana@example.org")
        // The pitched row's contact must be SENT for the guard to count it as already pitched.
        try #require(pitched.recipients.first).sendState = .sent
        let arriving = row(ctx, "Legends: A New Musical", night: "2026-10-03", email: nil)
        try ctx.save()

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: arriving.naturalKey,
                       contacts: [PrepContact(name: "Ana Ruiz", role: "producer",
                                              email: "ana@example.org",
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "presenter",
                                              sourceUrl: "https://example.org/about")],
                       draft: PrepDraft(subject: "S", body: "B", variant: "A")),
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let written = try #require(try ctx.fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == arriving.naturalKey }?.recipients.first)
        #expect(written.looksLikeDuplicateContact,
                "the guard did not fire at all, so this says nothing about the key beside it")
        #expect(written.looksLikeDuplicateContactKey == pitched.naturalKey,
                "the importer recorded the flag without the row it matched, so the sentence can never name it")

        // AND AGAIN, because the importer has TWO writers: the one above, for a contact it is meeting
        // for the first time, and a second one on the path that updates a recipient already stored. A
        // re-prep runs the second, and a mutation of it survived a suite that only ever ingested once.
        _ = PrepImporter.ingest(results, into: ctx)
        let reingested = try #require(try ctx.fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == arriving.naturalKey }?.recipients.first)
        #expect(reingested.looksLikeDuplicateContactKey == pitched.naturalKey,
                "a second prep cleared the key on a recipient it already held")
    }

    // And a key naming a row that is no longer stored resolves to NOTHING, so the sentence falls back
    // rather than naming a card Dan cannot open (L200).
    @Test func aKeyWhoseRowIsGoneResolvesToNothing() throws {
        let ctx = try context()
        let arriving = row(ctx, "Legends: A New Musical", night: "2026-10-04", email: "ana@example.org")
        let recipient = try #require(arriving.recipients.first)
        recipient.looksLikeDuplicateContact = true
        recipient.looksLikeDuplicateContactKey = "a row that was merged away|2026-10-03|the green room 42"
        try ctx.save()

        let cards = QueueModel.items(from: [arriving],
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        let contact = try #require(cards.first?.contacts.first)
        #expect(contact.duplicateOfTitle == nil)
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz", show: contact.duplicateOfTitle,
                                                  night: contact.duplicateOfNight)
                == "Ana Ruiz may already be pitched for a show at this venue; blocked from sending.")
    }
}
