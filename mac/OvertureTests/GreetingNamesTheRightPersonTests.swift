import Testing
import Foundation
import SwiftData

// #2579: a draft opening "Hi Emma," on a show whose only contact is Tom used to send without complaint.
//
// Before #2545 the greeting was composed from the contact record (`Salutation.greeting(for:)`), so it
// could not name the wrong person: the name came from the same row the email was addressed to. The
// drafter writes it now, and nothing compared the two. That is the one safety property the move gave up.
//
// `greetingMisaddressed` is a different question (a named greeting reaching SEVERAL people), and it
// cannot see this: a single-contact show has an audience of one.
//
// Every test below is about the same trade: the check must catch the wrong name and must NOT hold a good
// send. The second half is the larger one, so it has more tests.
@MainActor
@Suite("The greeting names the right contact (#2579)")
struct GreetingNamesTheRightPersonTests {

    // MARK: who the greeting names

    @Test("it reads the name out of an ordinary greeting")
    func itReadsTheName() {
        #expect(DraftGreeting.greetedName("Hi Emma,\n\nsome text") == "Emma")
        #expect(DraftGreeting.greetedName("Dear Thomas,\n\nsome text") == "Thomas")
        #expect(DraftGreeting.greetedName("Good morning Emma,\n\nsome text") == "Emma")
    }

    // Nil is the answer whenever it cannot read one confidently, because the cost of a wrong answer is
    // holding a good send.
    @Test("it declines to name anybody when it cannot be sure")
    func itDeclinesWhenUnsure() {
        #expect(DraftGreeting.greetedName("Hi there,\n\nsome text") == nil, "a filler names nobody")
        #expect(DraftGreeting.greetedName("Hello,\n\nsome text") == nil, "and so does no name at all")
        #expect(DraftGreeting.greetedName("Hi Sarah and Tom,\n\nsome text") == nil, "two people")
        #expect(DraftGreeting.greetedName("Marcus, hello again,\n\nsome text") == nil,
                "the shape form, whose name is not where this looks")
        #expect(DraftGreeting.greetedName("") == nil)
        #expect(DraftGreeting.greetedName(nil) == nil)
    }

    // MARK: the mismatch it is for

    @Test("a greeting naming somebody else is caught")
    func theWrongNameIsCaught() {
        #expect(DraftGreeting.namesSomeoneElse(greeting: "Hi Emma,\n\ntext", contactName: "Tom Fletcher"))
        #expect(DraftGreeting.namesSomeoneElse(greeting: "Dear Marcus,\n\ntext", contactName: "Emma Robinson"))
    }

    // MARK: everything it must NOT hold (the half that matters more)

    @Test("the right name in any of its ordinary forms is fine")
    func theRightNameIsLeftAlone() {
        let fine: [(String, String)] = [
            ("Hi Emma,", "Emma Robinson"),
            ("Hi emma,", "Emma Robinson"),                 // case
            ("Hi Robinson,", "Emma Robinson"),             // surname, or a surname-first culture
            ("Hi Tom,", "Thomas Fletcher"),                // a prefix of the name on record
            ("Hi Thomas,", "Tom Fletcher"),                // and the other direction
            ("Hi Dan,", "Daniel Wright"),
            ("Hi E,", "Emma Robinson"),                    // an initial
            ("Hi Jose,", "José García"),                   // accents folded
            ("Hi José,", "Jose Garcia"),
            ("Hi Mary-Kate,", "Mary-Kate Olsen"),          // a hyphenated name
            ("Hi O'Brien,", "Sinead O'Brien"),             // an apostrophe
            // The familiar forms the prefix test cannot see. These are the ones that would otherwise
            // hold a perfectly good send, and Tom for Thomas is the commonest name in the list.
            ("Hi Tom,", "Thomas Fletcher"),
            ("Hi Bob,", "Robert Fletcher"),
            ("Hi Bill,", "William Fletcher"),
            ("Hi Peggy,", "Margaret Fletcher"),
            ("Hi Liz,", "Elizabeth Fletcher"),
            ("Hi Steve,", "Stephen Fletcher"),
        ]
        for (greeting, contact) in fine {
            #expect(!DraftGreeting.namesSomeoneElse(greeting: "\(greeting)\n\ntext", contactName: contact),
                    "held a good send: \(greeting) to \(contact)")
        }
    }

    @Test("it says nothing when either half is unknown")
    func itIsSilentWithoutBothHalves() {
        #expect(!DraftGreeting.namesSomeoneElse(greeting: "Hi Emma,\n\ntext", contactName: nil))
        #expect(!DraftGreeting.namesSomeoneElse(greeting: "Hi Emma,\n\ntext", contactName: ""))
        #expect(!DraftGreeting.namesSomeoneElse(greeting: "Hello,\n\ntext", contactName: "Tom Fletcher"))
        #expect(!DraftGreeting.namesSomeoneElse(greeting: nil, contactName: "Tom Fletcher"))
        #expect(!DraftGreeting.namesSomeoneElse(greeting: "Hi Sarah and Tom,\n\ntext",
                                                contactName: "Emma Robinson"),
                "a greeting it cannot attribute is never a mismatch")
    }

    // MARK: the hold, and the way out of it

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, body: String, contact: String) -> Recipient {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2026-11-02", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.draftBody = body
        let r = Recipient(id: "tom@aurora.org", email: "tom@aurora.org", name: contact,
                          provenance: .presenter, contactMethodRaw: ContactMethod.namedDecisionMaker.rawValue)
        p.recipients.append(r)
        ctx.insert(p)
        ctx.insert(r)
        return r
    }

    @Test("the send is held, and the hold is the greeting hold rather than a new one")
    func theSendIsHeld() throws {
        let ctx = ModelContext(try container())
        let r = show(ctx, body: "Hi Emma,\n\nI photograph performing arts.", contact: "Tom Fletcher")

        #expect(r.greetingNamesSomeoneElse)
        #expect(r.isBlockedByGreeting)
    }

    // A third hold with no way past it would be the one that made Dan stop trusting the other two. It
    // joins the same disjunction, so his existing override covers it.
    @Test("his existing greeting override releases it")
    func theOverrideCoversIt() throws {
        let ctx = ModelContext(try container())
        let body = "Hi Emma,\n\nI photograph performing arts."
        let r = show(ctx, body: body, contact: "Tom Fletcher")
        #expect(r.isBlockedByGreeting)

        r.greetingOverriddenBody = body

        #expect(r.greetingNamesSomeoneElse, "the finding stands: an override is not a correction")
        #expect(!r.isBlockedByGreeting, "but it no longer holds the send")
    }

    @Test("a correctly addressed draft is not held")
    func aGoodDraftIsNotHeld() throws {
        let ctx = ModelContext(try container())
        let r = show(ctx, body: "Hi Tom,\n\nI photograph performing arts.", contact: "Tom Fletcher")

        #expect(!r.greetingNamesSomeoneElse)
        #expect(!r.isBlockedByGreeting)
    }

    // MARK: what Dan reads

    // The whole content of this warning is WHICH TWO names disagree, so both are in it. "The greeting
    // names the wrong person" would leave him to work out who it thinks it is addressing, on the one
    // warning where that is the answer.
    @Test("the note names both the greeting and the contact")
    func theNoteNamesBoth() throws {
        let note = try #require(DraftReviewNotes.greeting(missing: false, misaddressed: false, audience: 1,
                                                          overridden: false, namesSomeoneElse: true,
                                                          contactName: "Tom Fletcher", greetedName: "Emma"))
        #expect(note.contains("Emma"))
        #expect(note.contains("Tom Fletcher"))
    }

    @Test("an overridden one still leaves the trail")
    func anOverriddenNoteStillSpeaks() {
        #expect(DraftReviewNotes.greeting(missing: false, misaddressed: false, audience: 1,
                                          overridden: true, namesSomeoneElse: true,
                                          contactName: "Tom Fletcher", greetedName: "Emma") != nil)
    }

    @Test("a clean draft says nothing")
    func aCleanDraftSaysNothing() {
        #expect(DraftReviewNotes.greeting(missing: false, misaddressed: false, audience: 1,
                                          overridden: false) == nil)
    }
}
