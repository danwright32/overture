import Testing
import Foundation
import SwiftData
@testable import Overture

// #1630: Dan pitches a form-only show by hand, through the act's own contact form, and tells Overture
// he did. That outreach is real but Gmail never touched it, so there is no thread to watch and no
// message id to prove it. These tests pin what the record does and, just as importantly, what it must
// never cause: a nudge Overture cannot send, a "reply tracking broken" alarm about a thing working as
// designed, or a show that quietly leaves every stage.
@MainActor
@Suite("Form outreach")
struct FormOutreachTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A form-only show exactly as it reaches Review today: drafted, with one act contact carrying a
    // form on its own site and no address anywhere. This is the #1626 shape.
    @discardableResult
    private func formOnlyDrafted(_ ctx: ModelContext, group: String = "Aurora Strings",
                                 formURL: String = "https://aurorastrings.example/contact") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-01", venue: "Jalopy")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Jalopy",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted, ingestedAt: Date(timeIntervalSince1970: 1))
        p.draftSubject = "Photographing Aurora Strings at Jalopy."
        p.draftBody = "I photograph performing arts in New York."
        ctx.insert(p)
        let r = Recipient(id: Recipient.makeId(email: nil, formURL: formURL)!, email: nil,
                          name: "Jake Berg", provenance: .act,
                          contactMethodRaw: ContactMethod.formOrDM.rawValue, contactFormURL: formURL)
        p.setRecipients([r])
        try? ctx.save()
        return p
    }

    // The record mirrors what a real send stamps (SendService.deliver): this contact is sent, the show
    // carries its first-send rollup, and it is contacted. Without the rollup the show would read as
    // never pitched everywhere the ~20 lead-level readers ask.
    @Test func recordingAFormOutreachStampsTheContactAndTheShow() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let r = p.recipients[0]
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(p.recordFormOutreach(r, now: now))

        #expect(r.outreachChannel == .contactForm)
        #expect(r.formOutreachRecordedAt == now)
        #expect(r.sendState == .sent)
        #expect(r.sentAt == now)
        #expect(p.sentAt == now)
        #expect(p.status == .contacted)
    }

    // L37, history is stamped at write time. `contactFormURL` is scout-owned and rewritten by every
    // re-ingest (PrepImporter), so reading the submitted URL back off it would later describe a page
    // Dan never used. The record keeps the one he actually submitted.
    @Test func theRecordKeepsTheFormURLDanSubmittedEvenAfterAReIngestRewritesTheContact() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let r = p.recipients[0]

        p.recordFormOutreach(r, now: Date(timeIntervalSince1970: 1_000_000),
                             formURL: "https://aurorastrings.example/contact")
        // What a later Prep run does to this row (PrepImporter: `r.contactFormURL = c.formUrl ?? ...`).
        r.contactFormURL = "https://aurorastrings.example/booking-enquiries"

        #expect(r.formOutreachURL == "https://aurorastrings.example/contact")
    }

    // The defect this issue must not ship (L45, #1691; the #792 failure mode). Recording the outreach
    // takes the show out of Review, and it is in no Scout, Prep or Send state either, so if Reached out
    // refuses it too the show matches NO stage: still in the store, gone from the product, with a live
    // pitch outstanding. `reachedOutKeys` is derived from ReachedOutQueue itself rather than handed in,
    // so this proves the real wiring and not a convenient argument.
    @Test func aShowPitchedThroughAFormIsStillSomewhereDanCanReachIt() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let now = Date(timeIntervalSince1970: 1_000_000)
        p.recordFormOutreach(p.recipients[0], now: now, formURL: "https://aurorastrings.example/contact")

        let reachedOutKeys = Set(ReachedOutQueue.activeWithDates(from: [p], now: now).map { $0.prospect.naturalKey })
        let stage = StageNavigation.stage(containing: p.naturalKey, in: [p],
                                          reachedOutKeys: reachedOutKeys, today: "2026-07-28", now: now)

        #expect(stage == .reachedOut)
    }

    // The follow-up sequencer emails a nudge onto the original thread. A form outreach has neither an
    // address nor a thread, so a nudge for it cannot be sent at all: offering one puts a button in the
    // Follow-ups list that can only fail, about a pitch that is fine. It rides the decide clock below
    // instead.
    @Test func aFormOutreachIsNeverOfferedAFollowUpNudge() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let now = Date(timeIntervalSince1970: 1_000_000)
        p.recordFormOutreach(p.recipients[0], now: now, formURL: "https://aurorastrings.example/contact")
        let wellPastTheGap = now.addingTimeInterval(30 * 86_400)

        #expect(p.recipients[0].isAwaitingFollowUp == false)
        #expect(FollowUp.dueRecipients(from: [p], now: wellPastTheGap).isEmpty)
    }

    // ...and it still has to be somewhere, so it keeps its own clock: after the same gap a first email
    // follow-up uses (Dan's call, 2026-07-28), Overture asks him what happened rather than offering to
    // send anything.
    @Test func aFormOutreachComesDueForADecisionAfterTheFollowUpGap() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = p.recipients[0]
        p.recordFormOutreach(r, now: now, formURL: "https://aurorastrings.example/contact")

        let due = ReachedOutQueue.nextReachOut(for: r, of: p, now: now)

        #expect(due == now.addingTimeInterval(TimeInterval(FollowUpConfig().gapDays) * 86_400))
    }

    // Dan's call, 2026-07-28: a hand-recorded pitch is real evidence and counts everywhere an emailed
    // one counts, but it is weaker evidence than a confirmed send, so a Downbeat match asks instead of
    // booking silently. Deliberately the same fixture as DownbeatBookingTests.exactMatchAutoBooks, which
    // DOES auto-book, so the only difference in play is the channel.
    @Test func aFormPitchCountsAsContactedButItsBookingIsOnlyASuggestion() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = Prospect(naturalKey: "Acme Festival Chorus", groupName: "Acme Festival Chorus",
                         discipline: "choral", venue: "V", performanceDate: "2026-07-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.downbeatClientId = "C1"
        p.draftBody = "I photograph performing arts in New York."
        ctx.insert(p)
        let form = "https://acmechorus.example/contact"
        let r = Recipient(id: Recipient.makeId(email: nil, formURL: form)!, email: nil,
                          provenance: .act, contactMethodRaw: ContactMethod.formOrDM.rawValue,
                          contactFormURL: form)
        p.setRecipients([r])
        p.recordFormOutreach(r, now: sendDay, formURL: form)

        #expect(p.wasProvablyContacted)

        let b = OvertureBooking(id: "B99", clientId: "C1", clientDisplayName: "Acme Festival Chorus",
                                shootName: "Gala", startDate: "2026-07-01", endDate: "2026-07-01",
                                venueId: nil, venueName: "V")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date(timeIntervalSince1970: 9_999))

        #expect(count == 0)
        #expect(p.outcome != .booked)
        #expect(p.bookingSuggested)
    }

    // Assume it runs twice. A double-tap, or a click on a row that re-rendered, must not restamp the
    // record: the outreach date is what the decide clock and #16's funnel are measured from, so moving
    // it silently resets a countdown that is already running.
    @Test func recordingTheSameFormOutreachTwiceKeepsTheFirstRecord() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let r = p.recipients[0]
        let first = Date(timeIntervalSince1970: 1_000_000)
        let laterClick = first.addingTimeInterval(4 * 86_400)

        #expect(p.recordFormOutreach(r, now: first, formURL: "https://aurorastrings.example/contact"))
        #expect(p.recordFormOutreach(r, now: laterClick, formURL: "https://elsewhere.example/contact") == false)

        #expect(r.formOutreachRecordedAt == first)
        #expect(r.formOutreachURL == "https://aurorastrings.example/contact")
        #expect(r.sentAt == first)
        #expect(p.sentAt == first)
    }

    // He clicked "Copy pitch and open form", looked at the form, and decided not to send after all. The
    // record has to come off cleanly, or the show reads as pitched forever on the strength of a misclick.
    @Test func undoingAFormOutreachPutsTheShowBackWhereItWas() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let r = p.recipients[0]
        p.recordFormOutreach(r, now: Date(timeIntervalSince1970: 1_000_000),
                             formURL: "https://aurorastrings.example/contact")

        #expect(p.undoFormOutreach(r))

        #expect(r.formOutreachRecordedAt == nil)
        #expect(r.formOutreachURL == nil)
        #expect(r.outreachChannel == .email)
        #expect(r.sendState == .pending)
        #expect(r.sentAt == nil)
        #expect(p.sentAt == nil)
        #expect(p.wasProvablyContacted == false)
        #expect(p.status == .drafted)
    }

    // ...but never once a real email has also gone out on the show. The lead-level rollup (the send
    // date, the frozen ranking features, the relationship captured at send) belongs to that email, and
    // clearing it to unwind a form record would silently rewrite the history of a genuine send.
    @Test func aFormOutreachCannotBeUndoneOnceAnEmailHasAlsoGoneOut() throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let formContact = p.recipients[0]
        let emailed = Recipient(id: "boss@presenter.example", email: "boss@presenter.example",
                                provenance: .presenter)
        p.addRecipient(emailed)
        p.recordFormOutreach(formContact, now: Date(timeIntervalSince1970: 1_000_000),
                             formURL: "https://aurorastrings.example/contact")
        emailed.sendState = .sent
        emailed.sentAt = Date(timeIntervalSince1970: 2_000_000)
        emailed.gmailMessageId = "<mid-1@x.org>"

        #expect(p.undoFormOutreach(formContact) == false)

        #expect(formContact.formOutreachRecordedAt != nil)
        #expect(p.sentAt == Date(timeIntervalSince1970: 1_000_000))
    }

    // What Dan pastes into a form has to be the whole pitch, greeting included. The greeting is not in
    // the stored draft: it was composed inside SendService at the moment of sending and nowhere else, so
    // copying `draftBody` would have handed him a pitch that opens cold with no name on it. This pins
    // the two to the same helper: the text on the clipboard IS the text Gmail would have sent.
    @Test func theCopiedPitchIsExactlyWhatAnEmailWouldHaveSent() async throws {
        let ctx = ModelContext(try container())
        let p = formOnlyDrafted(ctx)
        let r = p.recipients[0]

        let copied = OutgoingPitch.text(for: r, of: p)

        #expect(copied?.hasPrefix("Hi Jake,") == true)
        #expect(copied?.contains("I photograph performing arts in New York.") == true)

        // The same recipient, given an address, sent for real: the body Gmail receives is that string.
        r.email = "jake@aurorastrings.example"
        p.status = .approved
        let sender = PitchCapturingSender()
        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 1_000_000), sender: sender)

        #expect(sender.last?.body == copied)
    }
}

// The control's own state machine, which decides what the Review row offers. Kept out of the SwiftUI
// view so it can be tested at all (#863).
@MainActor
@Suite("Form pitch control")
struct FormPitchStateTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, email: String? = nil,
                      formURL: String? = "https://aurorastrings.example/contact") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "Jalopy",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftBody = "I photograph performing arts in New York."
        ctx.insert(p)
        if let id = Recipient.makeId(email: email, formURL: formURL) {
            p.setRecipients([Recipient(id: id, email: email, provenance: .act,
                                       contactMethodRaw: ContactMethod.formOrDM.rawValue,
                                       contactFormURL: formURL)])
        }
        return p
    }

    @Test func aFormOnlyShowOffersTheCopyAndOpenControl() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        #expect(FormPitch.state(of: p) == .ready(recipientId: p.recipients[0].id,
                                                 formURL: "https://aurorastrings.example/contact"))
    }

    // Dan pressed copy and went to the browser. The confirm has to survive him closing the window and
    // coming back next week, or the row reads as untouched again, which is this issue in miniature.
    @Test func onceHeHasOpenedTheFormTheRowWaitsOnHisAnswer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.beginFormPitch(p.recipients[0], now: Date(timeIntervalSince1970: 1_000_000))
        #expect(FormPitch.state(of: p) == .awaitingConfirmation(recipientId: p.recipients[0].id,
                                                                formURL: "https://aurorastrings.example/contact"))
    }

    @Test func onceRecordedTheRowSaysSoInsteadOfOfferingTheControlAgain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let now = Date(timeIntervalSince1970: 1_000_000)
        p.recordFormOutreach(p.recipients[0], now: now, formURL: "https://aurorastrings.example/contact")
        #expect(FormPitch.state(of: p) == .recorded(at: now))
    }

    // Dan's scope, 2026-07-28: forms only. A show with a working address goes through Overture's own
    // send path, and this control must never become a way to mark anything at all as pitched.
    @Test func aShowWithAnEmailNeverOffersTheControl() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, email: "hello@aurorastrings.example", formURL: nil)
        #expect(FormPitch.state(of: p) == .unavailable)
    }

    // An Instagram is a verified dead end, not a form (#1626, #1004). The judgment is made once, in
    // usableContactFormURLs, and this control inherits it rather than re-deciding.
    @Test func aSocialOnlyContactIsNotAForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, formURL: "https://www.instagram.com/heybailay/")
        #expect(FormPitch.state(of: p) == .unavailable)
    }
}

// Records the mail it was handed, so a test can compare the copied pitch against the sent one.
private final class PitchCapturingSender: MailSender, @unchecked Sendable {
    var last: OutgoingMail?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        last = mail
        return SentReceipt(threadId: "t", messageID: "<m>")
    }
}
