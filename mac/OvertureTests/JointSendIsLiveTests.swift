import Testing
import Foundation
import SwiftData

// #2033 part 2. The phases before this one built a joint send nothing could reach. This is the wiring
// that makes pressing Send on a show with two contacts actually send them one email.
//
// Dan's decision, 2026-08-03, when shown that defaulting to together reverses the act-then-presenter
// ladder (#366/#368): "Basically it's all or nothing. I want to have a selector that says email
// separately or together and just choose the one I want for each event. It should default to together."
//
// So the mode is ONE per-event choice over all of that event's contacts, defaulting to together, and the
// send path, the confirmation and the card all read that one choice.
@MainActor
@Suite("Joint sending is live (#2033 part 2)")
struct JointSendIsLiveTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func approvedShow(_ ctx: ModelContext, contacts: Int = 2) -> (Prospect, [Recipient]) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora", discipline: "music", venue: "V",
                         performanceDate: "2026-12-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "Photography for your December concert"
        p.draftBody = "I document dance."
        ctx.insert(p)
        let all = [("emma@org.example", "Emma Robinson"), ("noah@org.example", "Noah Ellis")]
            .prefix(contacts)
            .map { Recipient(id: $0.0, email: $0.0, name: $0.1, provenance: .presenter) }
        for r in all { ctx.insert(r) }
        p.setRecipients(Array(all))
        try? ctx.save()
        return (p, Array(all))
    }

    // MARK: - the mode

    @Test func ashowSendsItsContactsTogetherUnlessDanSaysOtherwise() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        #expect(p.sendsTogether, "together is the default he asked for")
    }

    @Test func danCanSetAShowToSendSeparately() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)
        p.sendsTogetherOverride = false

        #expect(p.sendsTogether == false)
    }

    // MARK: - what Send actually does

    @Test func pressingSendOnAShowSetToTogetherSendsOneEmailToBoth() async throws {
        let ctx = ModelContext(try container())
        let (p, contacts) = approvedShow(ctx)
        let sender = LiveCapturingSender()

        #expect(await SendService.sendNext(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.all.count == 1, "one press, one email")
        #expect(sender.last?.to == ["emma@org.example", "noah@org.example"])
        #expect(contacts.allSatisfy { $0.sendState == .sent })
        #expect(p.status == .contacted)
    }

    @Test func pressingSendOnAShowSetToSeparatelyEmailsOnePersonAtATime() async throws {
        let ctx = ModelContext(try container())
        let (p, contacts) = approvedShow(ctx)
        p.sendsTogetherOverride = false
        let sender = LiveCapturingSender()

        #expect(await SendService.sendNext(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.last?.to.count == 1)
        #expect(contacts.filter { $0.sendState == .sent }.count == 1)
        #expect(p.status == .approved, "somebody is still to be written to, so the show stays sendable")
    }

    // A show with ONE contact behaves identically under either mode, which is most shows.
    @Test func ashowWithOneContactSendsTheSameWayUnderEitherMode() async throws {
        for together in [true, false] {
            let ctx = ModelContext(try container())
            let (p, _) = approvedShow(ctx, contacts: 1)
            p.sendsTogetherOverride = together
            let sender = LiveCapturingSender()

            #expect(await SendService.sendNext(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)
            #expect(sender.last?.to == ["emma@org.example"])
        }
    }

    // MARK: - what Dan is shown before it goes

    // L64: what he approves must include WHO it goes to. A confirmation naming one person for an email
    // reaching two is the defect the whole milestone is framed around.
    @Test func theconfirmationNamesEveryAddressTheEmailReaches() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        let c = try #require(SendConfirmation(prospect: p, signature: .none))

        #expect(c.recipient.contains("emma@org.example"))
        #expect(c.recipient.contains("noah@org.example"))
    }

    @Test func theconfirmationShowsTheGreetingAGroupEmailCarries() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        let c = try #require(SendConfirmation(prospect: p, signature: .none))

        #expect(c.body.hasPrefix("Hi Emma and Noah,\n\n"))
    }

    // The reassurance is a promise about what pressing Send does. "To this recipient only" is a false
    // promise on an email reaching two people.
    @Test func theconfirmationDoesNotPromiseASingleRecipientWhenThereAreTwo() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        let c = try #require(SendConfirmation(prospect: p, signature: .none))

        #expect(!c.reassurance.contains("this recipient only"))
    }

    @Test func aoneContactShowStillPromisesThisRecipientOnly() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx, contacts: 1)

        let c = try #require(SendConfirmation(prospect: p, signature: .none))

        #expect(c.reassurance.contains("this recipient only"))
    }

    // MARK: - the card

    @Test func thecardMarksEveryContactTheNextEmailReaches() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        let item = QueueItem(p)

        #expect(Set(item.nextRecipientIds) == ["emma@org.example", "noah@org.example"])
    }

    // One email has one greeting, so the draft screen has one to show and edit. Two openings on a card
    // for an email carrying one of them is the #2010 defect in a new place: what he reads is not what
    // sends.
    @Test func thecardCarriesOneOpeningForAJointEmail() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)

        #expect(QueueItem(p).jointOpening == "Hi Emma and Noah,")
    }

    @Test func thecardCarriesNoJointOpeningWhenEachContactGetsTheirOwnEmail() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)
        p.sendsTogetherOverride = false

        #expect(QueueItem(p).jointOpening == nil, "each contact keeps their own opening in this mode")
    }

    @Test func thecardMarksOneContactWhenTheShowSendsSeparately() throws {
        let ctx = ModelContext(try container())
        let (p, _) = approvedShow(ctx)
        p.sendsTogetherOverride = false

        let item = QueueItem(p)

        #expect(item.nextRecipientIds == ["emma@org.example"])
    }
}

private final class LiveCapturingSender: MailSender, @unchecked Sendable {
    var all: [OutgoingMail] = []
    var last: OutgoingMail? { all.last }
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        all.append(mail)
        return SentReceipt(threadId: "t-1", messageID: "<m-1>")
    }
}
