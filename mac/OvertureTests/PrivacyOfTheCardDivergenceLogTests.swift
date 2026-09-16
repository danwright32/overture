import Testing
import Foundation
import SwiftData

// #3654 CORRECTION C7: whose data the card divergence log touches, enforced rather than promised.
//
// The record holds a session, a sequence, an instant, the NAMES of the fields that differed, a count and
// a stage. Never a contact's name, an address, a greeting, a draft body, and never the show's own key.
// Dan's call, 2026-09-08, choosing this over a record that names the show.
//
// THE SHOW'S KEY IS THE ONE PEOPLE WILL ARGUE ABOUT, so the reason is here rather than in a comment
// nobody reads: a natural key is built from the group name, and Dan's queue is full of shows billed as a
// single performer's own name. That is exactly the identity class #2839, #3110 and #3140 have each
// already paid to scrub out of this repository.
//
// A durable file on Dan's Mac is a route no repository scanner inspects.
// `scripts/check-test-identity-provenance.sh` and the domain guards read the REPOSITORY, and neither can
// see what the app writes at runtime (L222). So the defence cannot be a scan; it has to be that there is
// no field for the value to go in.
@Suite("The card divergence log cannot carry Dan's data (#3654)")
struct PrivacyOfTheCardDivergenceLogTests {

    private var model: String { SourceGuardHelper.source("Overture/Domain/CardDivergence.swift") }

    /// The record's stored properties, which are `let` rather than `var`.
    ///
    /// `SourceGuardHelper.storedPropertyNames` reads `var` only, because the type it was written for is a
    /// SwiftData model where every field is one. Extended HERE rather than there, because widening the
    /// shared helper would newly count every `let` constant inside every class it already reads, and a
    /// classification guard would then demand somebody classify them.
    private func storedNames(in body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { line in
            let indented = line.hasPrefix("    ") && !line.hasPrefix("     ")
            guard indented else { return nil }
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.contains("{"), code.hasPrefix("let ") || code.hasPrefix("var ") else { return nil }
            let name = code.dropFirst(4).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
    }

    // THE ONE THAT MATTERS. Every stored property of the record, derived rather than listed, checked
    // against a list of what a record is allowed to hold. A field added later that is not on that list is
    // the finding, which is the opposite way round from a forbidden-name list: a list of banned words is
    // blind to the field somebody names innocuously (L96).
    @Test("the record can hold nothing but the fields it was designed to hold")
    func theRecordHoldsOnlyWhatItWasDesignedTo() {
        let body = try! #require(SourceGuardHelper.between("struct CardDivergenceRecord", and: "\n}",
                                                           in: model))
        let allowed: Set<String> = ["session", "sequence", "at", "fields", "cardsBuilt", "stage"]
        let declared = Set(storedNames(in: body))
        // A floor FIRST. An extraction that read nothing and a record with no fields leave the same empty
        // set, and the emptiest possible failure must not read as the cleanest possible pass (L98).
        #expect(declared.count >= 5, Comment(rawValue:
            "read only \(declared.count) fields off the record, so this checked almost nothing"))
        #expect(declared == allowed, Comment(rawValue:
            "the divergence record's fields are \(declared.sorted()) against the \(allowed.sorted()) it "
            + "was designed to hold. Anything else is a durable file on Dan's Mac gaining a field no "
            + "repository scanner can see into (L222, #3654 C7)."))
    }

    // The comparison hands back NAMES, and this is asserted against real data rather than by reading the
    // source: two cards that differ in a contact-derived field must produce the field's name and nothing
    // resembling the contact.
    @Test("a real divergence reports a field name and not a value")
    func arealDivergenceCarriesNoValue() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k1", groupName: "Marguerite Eddowes in Recital", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2099-04-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "booking@example.invalid", email: "booking@example.invalid",
                          name: "Marguerite Eddowes", provenance: .act)
        r.sendState = .pending
        p.recipients.append(r)
        try ctx.save()

        let mine = QueueItem(p)
        var wrong = mine
        wrong.presenterLine = "anything at all"
        let fields = QueueModel.differingFieldNames(wrong, mine)

        #expect(fields == ["presenterLine"])
        let record = CardDivergenceRecord(session: "s", sequence: 1, at: Date(), fields: fields,
                                          cardsBuilt: 20, stage: "scout")
        let line = try #require(CardDivergenceLog.line(for: record))
        // The whole encoded line, which is what actually lands on disk. Asserted over the LINE rather
        // than over the struct, because the struct is what a reviewer reads and the line is what a
        // scanner would have to catch and cannot.
        for secret in ["Marguerite", "Eddowes", "booking@example.invalid", "Weill Recital Hall", "k1"] {
            #expect(!line.contains(secret), Comment(rawValue:
                "the encoded record carries `\(secret)`, which is a person, an address or a show, in a "
                + "durable file beside the store: \(line)"))
        }
    }

    // The reader's sentence carries no value either. It is drawn on screen, so it is the other route out.
    @Test("the sentence Dan reads names a field and nothing else")
    func theSentenceCarriesNoValue() {
        let sentence = CardDivergenceCopy.report(count: 1, fields: ["presenterLine", "venue"],
                                                 unreadableLines: 0)
        // NO FIELD NAME. The cold read is what changed this: a code identifier is the only concrete thing
        // in the sentence, so it is the half Dan would try hardest to read, and it means nothing to him
        // (L604, L611). It stays in the file, for whoever looks.
        #expect(!sentence.contains("presenterLine"))
        #expect(!sentence.contains("venue"))
        // And it does not promise a detail the record cannot produce. The record carries no show
        // identity, so a sentence naming a show would send Dan looking for something nothing can tell
        // him (L80).
        #expect(!sentence.lowercased().contains("show \""))
        #expect(sentence.contains("nothing here needs deciding"),
                "the sentence no longer says what it asks of Dan, which is nothing")
    }
}
