import Testing
import Foundation
import SwiftData

private final class CountingSender: MailSender, @unchecked Sendable {
    var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: "t\(sent.count)", messageID: "<m\(sent.count)>")
    }
}

private struct FailingSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}

// Refuses one named address and delivers the rest, which is what a single bad or blocked address looks
// like in the middle of a batch Dan ticked.
private final class RefusingSender: MailSender, @unchecked Sendable {
    let refusing: String
    var sent: [OutgoingMail] = []
    var attempted: [OutgoingMail] = []
    init(refusing: String) { self.refusing = refusing }
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        attempted.append(mail)
        guard !mail.to.contains(refusing) else { throw MailSenderError.notConfigured }
        sent.append(mail)
        return SentReceipt(threadId: "t\(sent.count)", messageID: "<m\(sent.count)>")
    }
}

// #2017: Dan picks which of a show's contacts the pitch reaches, at the moment he sends it.
//
// Dan, 2026-08-03: "Let me pick, and send to several", after finding the confirmation named the recipient
// without letting him change it. And on what ticking several under "email separately" should do,
// 2026-08-04: "It should send all three now but also give me the option to put them all on the same email."
//
// So the sheet answers two questions, not one: WHICH contacts (this list), and HOW they receive it (the
// event's existing together-or-separately choice, reachable from the same screen).
@MainActor
@Suite("Choosing which contacts a pitch reaches")
struct SendPickerTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, together: Bool = true) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Lumen", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Lumen", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date(timeIntervalSince1970: 1))
        p.draftSubject = "Photographing Lumen"
        p.draftBody = "Hello,\n\nI document choral work."
        p.sendsTogetherOverride = together
        ctx.insert(p)
        let act = Recipient(id: "ann@org.example", email: "ann@org.example", name: "Ann", provenance: .act)
        let presenter = Recipient(id: "ben@org.example", email: "ben@org.example", name: "Ben",
                                  provenance: .presenter)
        let manual = Recipient(id: "cara@org.example", email: "cara@org.example", name: "Cara",
                               provenance: .manual)
        p.setRecipients([act, presenter, manual])
        try? ctx.save()
        return p
    }

    private func ids(_ p: Prospect, _ emails: [String]) -> [Recipient] {
        emails.compactMap { e in p.recipients.first { $0.email == e } }
    }

    // MARK: - What the sheet offers

    @Test func everySendableContactIsOffered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        let confirmation = try #require(SendConfirmation(prospect: p))

        #expect(confirmation.candidates.map(\.email)
                == ["ann@org.example", "ben@org.example", "cara@org.example"])
        #expect(confirmation.candidates.allSatisfy { !$0.isHeld })
    }

    // The default has to be what pressing Send does today, or the picker quietly changes the ordinary path
    // rather than only offering a way off it.
    @Test func theDefaultTicksExactlyWhatSendWouldHaveDoneAnyway() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        let confirmation = try #require(SendConfirmation(prospect: p))

        #expect(confirmation.selected == SendGroup.pendingGroup(of: p).map(\.id))
    }

    @Test func onASeparatelyShowTheDefaultIsTheSingleContactSendWouldHaveTaken() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, together: false)

        let confirmation = try #require(SendConfirmation(prospect: p))

        #expect(confirmation.selected == ["ann@org.example"])       // the act, by send order
        #expect(confirmation.candidates.count == 3)                 // but all three are offered
    }

    // A contact a review guard is holding is SHOWN, so the list does not quietly omit somebody on the show,
    // and cannot be ticked, because the guard is the whole point (#2015).
    @Test func aHeldContactIsShownButCannotBeChosen() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let ben = try #require(p.recipients.first { $0.email == "ben@org.example" })
        ben.looksLikeVenue = true                                    // held by the venue-guess check

        let confirmation = try #require(SendConfirmation(prospect: p))
        let held = try #require(confirmation.candidates.first { $0.email == "ben@org.example" })

        #expect(held.isHeld)
        #expect(confirmation.selected.contains("ben@org.example") == false)
    }

    // MARK: - What it says it will do

    @Test func theSheetNamesOnlyTheChosenContacts() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        let confirmation = try #require(SendConfirmation(prospect: p,
                                                         selecting: ["ann@org.example", "cara@org.example"]))

        #expect(confirmation.recipient == "ann@org.example, cara@org.example")
    }

    // The promise Dan reads immediately before the one irreversible action has to be true of the current
    // selection, including how many emails it is about to be (L21, copy is a contract).
    @Test func thePromiseMatchesWhatTheButtonIsAboutToDo() {
        #expect(SendConfirmCopy.reassurance(chosen: 1, together: true)
                == "This sends one email right now, to this recipient only. Nothing else goes out.")
        #expect(SendConfirmCopy.reassurance(chosen: 1, together: false)
                == "This sends one email right now, to this recipient only. Nothing else goes out.")
        #expect(SendConfirmCopy.reassurance(chosen: 2, together: true)
                == "This sends one email right now, to both of these people. Nothing else goes out.")
        #expect(SendConfirmCopy.reassurance(chosen: 3, together: true)
                == "This sends one email right now, to all 3 of these people. Nothing else goes out.")
        #expect(SendConfirmCopy.reassurance(chosen: 2, together: false)
                == "This sends 2 separate emails right now, one to each of these people. Nothing else goes out.")
        #expect(SendConfirmCopy.reassurance(chosen: 3, together: false)
                == "This sends 3 separate emails right now, one to each of these people. Nothing else goes out.")
    }

    // MARK: - What Send actually does

    @Test func twoChosenOnATogetherShowGoOutAsOneEmailNamingBoth() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let sender = CountingSender()

        #expect(await SendService.sendNext(p, to: ids(p, ["ann@org.example", "cara@org.example"]),
                                           now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.to == ["ann@org.example", "cara@org.example"])
    }

    // Dan's own answer: all of them go now, as separate emails.
    @Test func threeChosenOnASeparatelyShowGoOutAsThreeEmailsNow() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, together: false)
        let sender = CountingSender()
        let chosen = ids(p, ["ann@org.example", "ben@org.example", "cara@org.example"])

        #expect(await SendService.sendNext(p, to: chosen, now: Date(timeIntervalSince1970: 10),
                                           sender: sender) == true)

        #expect(sender.sent.count == 3)
        #expect(sender.sent.flatMap(\.to).sorted()
                == ["ann@org.example", "ben@org.example", "cara@org.example"])
        // Each one recorded its own send, so none of them can be sent a second time.
        #expect(chosen.allSatisfy { $0.sendState == .sent })
    }

    // One address failing must not swallow the rest of what he ticked. A batch that stopped at the first
    // refusal would leave him believing all three went, with no sign of which did, and the two that were
    // never attempted are indistinguishable from two that were rejected (L47).
    @Test func oneAddressFailingDoesNotStopTheOthersGoing() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, together: false)
        let sender = RefusingSender(refusing: "ann@org.example")     // the FIRST in send order
        let chosen = ids(p, ["ann@org.example", "ben@org.example", "cara@org.example"])

        let anySent = await SendService.sendNext(p, to: chosen, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender)

        #expect(anySent)                                              // some of it got out, so say so
        #expect(sender.attempted.count == 3)                          // none was skipped because of the failure
        #expect(sender.sent.flatMap(\.to).sorted() == ["ben@org.example", "cara@org.example"])

        // The one that failed is left retryable and carries its error, rather than reading as sent.
        let ann = try #require(p.recipients.first { $0.email == "ann@org.example" })
        #expect(ann.sendState != .sent)
        #expect(ann.sendError != nil)
    }

    // Every one failing is not a partial success. The caller uses this to decide whether to prompt Dan to
    // reconnect Gmail, so a false true would swallow a dead credential.
    @Test func allOfThemFailingReportsFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, together: false)
        let sender = FailingSender()

        let anySent = await SendService.sendNext(p, to: ids(p, ["ann@org.example", "ben@org.example"]),
                                                 now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(anySent == false)
    }

    @Test func aContactLeftUntickedIsNotEmailedAndStaysSendable() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let sender = CountingSender()

        _ = await SendService.sendNext(p, to: ids(p, ["ann@org.example"]),
                                       now: Date(timeIntervalSince1970: 10), sender: sender)

        let ben = try #require(p.recipients.first { $0.email == "ben@org.example" })
        #expect(sender.sent.flatMap(\.to).contains("ben@org.example") == false)
        #expect(ben.isSendablePending)      // still there to send later, not consumed
    }

    // Passing nothing keeps the behavior every other caller relies on, so the picker is an addition rather
    // than a change to the path that already works.
    @Test func choosingNothingExplicitlyFallsBackToWhatSendAlwaysDid() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let sender = CountingSender()

        #expect(await SendService.sendNext(p, now: Date(timeIntervalSince1970: 10), sender: sender) == true)

        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.to.sorted()
                == ["ann@org.example", "ben@org.example", "cara@org.example"])
    }

    // The filter BOTH the sheet's promise and the send go through, asserted directly. The end-to-end test
    // below passes even with this filter removed, because the delivery path refuses a held contact on its
    // own, so without this one nothing would notice if the selection stopped honouring the guards and the
    // sheet started promising an email that was never going to leave.
    @Test func theChosenSetItselfExcludesAHeldContact() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let ben = try #require(p.recipients.first { $0.email == "ben@org.example" })
        ben.looksLikeVenue = true

        let chosen = SendGroup.sendableFor(p, ids: ["ann@org.example", "ben@org.example"])

        #expect(chosen.map(\.email) == ["ann@org.example"])
    }

    // A guard cannot be talked past by ticking. The list refuses to offer a held contact, and the send
    // refuses it again, because a guard on a screen is not a guard (#2052).
    @Test func aHeldContactIsRefusedBySendEvenIfItIsAskedFor() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let ben = try #require(p.recipients.first { $0.email == "ben@org.example" })
        ben.looksLikeVenue = true
        let sender = CountingSender()

        _ = await SendService.sendNext(p, to: ids(p, ["ann@org.example", "ben@org.example"]),
                                       now: Date(timeIntervalSince1970: 10), sender: sender)

        #expect(sender.sent.flatMap(\.to).contains("ben@org.example") == false)
    }
}
