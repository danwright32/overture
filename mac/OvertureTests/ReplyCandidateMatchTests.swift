import Testing
import Foundation
import SwiftData

// #2714: rank the messages #2713 found, and REFUSE the ones that must never be proposed.
//
// The draft specified this only by what makes it fire, which both reviewers independently called the
// central risk, and the live store says they were right. Measured 2026-08-14 on the Release store,
// the five open form and DM pitches are:
//
//   54 Sings Shuffle Along, Or... A 10th Anniversary Celebration | 54 Below          | Corin Hale      | corinhale.example
//   Song & Word                                                  | The Green Room 42 | Vivace Arts Coll.  | instagram.com/vivaceartscollective
//   Eva Noblezada & Alder Bourne                                 | The Green Room 42 | Alder Bourne       | alderbourne.example
//   Battle of the Siblings                                       | The Green Room 42 | Tobias Lund  | tobiaslund.example
//   Perri Vale                                                   | The Green Room 42 | (no stored name)   | perrivale.example
//
// FOUR OF THE FIVE ARE AT THE SAME ROOM. A token set including the venue would score that room's own
// newsletter above the real presenter on four of Dan's five open pitches, every week, for ever. So the
// venue is not merely dropped from the tokens: every word of it is stripped out of the title tokens
// too, and there is a test below that fails if a venue word can ever contribute a point.
//
// The other half of the measurement is the good news: four of the five routes are personal-name
// domains and the fifth is a handle carrying the collective's name, and `Recipient.name` holds the
// person Dan actually pitched on four of five. Those two are the strongest signals available, and the
// draft mentioned neither.
//
// Every test injects `now` or avoids the clock entirely (L130).
@MainActor
@Suite("Which inbound message could be the presenter answering (#2714)")
struct ReplyCandidateMatchTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let sent = Date(timeIntervalSince1970: 1_785_900_000)

    private func show(_ ctx: ModelContext, name: String, venue: String?, presenter: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: name, groupName: name, discipline: "music", venue: venue,
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func pitch(_ ctx: ModelContext, on p: Prospect, contactName: String?, route: String) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: contactName, provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = sent.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    private func message(_ id: String, from: String, subject: String,
                         listUnsubscribe: String? = nil) -> GmailReplySearch.InboundMessage {
        GmailReplySearch.InboundMessage(
            messageId: id, threadId: id,
            fromAddress: ReplyDetection.email(from: from),
            fromName: ReplyDetection.displayName(from: from),
            subject: subject, sentAt: sent, listUnsubscribe: listUnsubscribe)
    }

    // MARK: refusals, applied before anything is ranked

    // Refused rather than merely scored low, because a low score still WINS when the field is weak,
    // and a failed identification that falls back to a nearby candidate is the defect L75 names: Dan
    // confirms a plausible sender, the address is written onto the contact, and a future pitch goes
    // there by email.
    @Test("an automated sender is refused, never ranked")
    func anAutomatedSenderIsRefused() {
        let m = message("m", from: "no-reply@ticketing.example.com", subject: "Your order")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "54 Below", selfEmail: me) == .automated)
    }

    @Test("the room's own address is refused, never ranked")
    func theRoomsOwnAddressIsRefused() {
        let m = message("m", from: "Bargemusic <hello@bargemusic.org>", subject: "About your enquiry")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "Bargemusic", selfEmail: me) == .theRoomsOwn)
    }

    // The oldest standing rule in the product (#368) reached by a new route, so it is refused even when
    // every other signal says yes. This is the case that would otherwise score HIGHEST of all.
    @Test("the room's own address is refused even when its display name matches the act exactly")
    func theRoomIsRefusedEvenWhenItLooksLikeTheAct() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Bargemusic", venue: "Bargemusic")
        let r = pitch(ctx, on: p, contactName: "Bargemusic", route: "https://bargemusic.org/contact")
        let m = message("m", from: "Bargemusic <bookings@bargemusic.org>", subject: "Re: Bargemusic")

        #expect(ReplyCandidateMatch.judge([m], for: r, on: p, selfEmail: me) == .nothingLooksLikeThem)
    }

    @Test("a press desk is refused, never ranked")
    func aPressDeskIsRefused() {
        let m = message("m", from: "press@someorg.org", subject: "Media guidelines")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "54 Below", selfEmail: me) == .aPressDesk)
    }

    // A newsletter is told from a person by the header bulk senders are required to set, not by
    // guessing at words. `ReplyDetection.isAutomated` catches only mailer-daemon and friends, so
    // hello@, info@ and boxoffice@ all sail through it, and a text-shape matcher over a personal inbox
    // matches far more than its target while an over-match reads exactly like the feature working
    // (L104).
    @Test("bulk mail is refused on the header bulk senders set, not on a guess about its words")
    func bulkMailIsRefused() {
        let m = message("m", from: "The Green Room 42 <hello@greenroom42.com>",
                        subject: "This week at The Green Room 42",
                        listUnsubscribe: "<https://greenroom42.com/u/abc>, <mailto:u@greenroom42.com>")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "The Green Room 42", selfEmail: me) == .bulkMail)
    }

    // FLIPPED by #2743, in the change that fixed it, which is what the earlier version of this test asked
    // whoever got there to do.
    //
    // It used to assert the guard did NOT catch this room, with a pointer to #2743, because the slugged
    // venue "thegreenroom42" never equalled the domain label "greenroom42" and so the guard protecting
    // Dan from a room's own address had never fired on the room behind four of his five open form
    // pitches. Now it does, and this asserts that, because a test still claiming the old behaviour would
    // be a guard passing on a fact that is no longer true.
    //
    // The bulk-mail refusal above is still the one that matters for a NEWSLETTER, and still has its own
    // test: it catches one whatever the domain, including from a room whose site Overture cannot connect
    // to the venue name at all.
    @Test("the venue guard now catches this room too, since #2743")
    func theVenueGuardCatchesALeadingThe() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@greenroom42.com",
                                                 venue: "The Green Room 42"))
    }

    @Test("Dan's own mail is refused, so an answer can never be proposed from his own sent copy")
    func dansOwnMailIsRefused() {
        let m = message("m", from: "Dan Wright <dan@danwrightphotography.com>", subject: "Re: your show")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "54 Below", selfEmail: me) == .dansOwn)
    }

    @Test("an ordinary person is not refused")
    func anOrdinaryPersonIsNotRefused() {
        let m = message("m", from: "Casey Grainger <casey@examplemail.com>", subject: "Re: your note")

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "54 Below", selfEmail: me) == nil)
    }

    // MARK: the venue can never earn a point

    // The single most important scoring rule on Dan's live data: four of five open pitches share The
    // Green Room 42, so any path by which a venue word scores would put that room ahead of the
    // presenter on almost every pitch he has open.
    //
    // The SHOW here is the live one whose own title repeats its room's name: "54 Sings Shuffle Along"
    // at "54 Below" share the token "54". That pairing is what makes this test real, and it was found
    // by mutation rather than by review. The first version used "Song & Word" at "The Green Room 42",
    // which share no word at all, so subtracting the venue changed nothing and the test passed whether
    // the subtraction was there or not: it SURVIVED the mutation deleting the very rule it exists to
    // protect (L1, L144).
    @Test("a venue word carried in the show's own title still cannot earn a point")
    func venueWordsNeverScore() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration",
                     venue: "54 Below")
        let r = pitch(ctx, on: p, contactName: "Corin Hale",
                      route: "https://www.corinhale.example/contact")
        let m = message("m", from: "Table Bookings <bookings@someagency.com>",
                        subject: "54 Below table bookings for the season")

        let scored = ReplyCandidateMatch.score(m, tokens: ReplyCandidateMatch.tokens(for: r, on: p))

        #expect(scored.score == 0, "a venue word earned \(scored.score) points via \(scored.reasons)")
    }

    // The other half of the same rule, so the subtraction cannot be satisfied by dropping the title
    // tokens altogether: a distinctive word from the title that is NOT the venue's still scores.
    @Test("a distinctive word from the title still scores once the venue's words are gone")
    func aDistinctiveTitleWordStillScores() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration",
                     venue: "54 Below")
        let r = pitch(ctx, on: p, contactName: "Corin Hale",
                      route: "https://www.corinhale.example/contact")
        let m = message("m", from: "Someone <someone@elsewhere.com>", subject: "About Shuffle Along")

        let scored = ReplyCandidateMatch.score(m, tokens: ReplyCandidateMatch.tokens(for: r, on: p))

        #expect(scored.score > 0, "the title's own distinctive words stopped scoring: \(scored.reasons)")
    }

    // MARK: the signals that do score

    @Test("the presenter answering from the form's own domain is the strongest signal there is")
    func theRouteDomainMatch() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: nil, route: "https://www.perrivale.example/contact")
        let m = message("m", from: "Perri Vale <perri@perrivale.example>", subject: "Re: photography")

        let verdict = ReplyCandidateMatch.judge([m], for: r, on: p, selfEmail: me)

        guard case .proposed(let top) = verdict else {
            Issue.record("expected a proposal, got \(verdict)"); return
        }
        #expect(top.message.messageId == "m")
    }

    // The live case this whole milestone came from: the form is on a personal-name domain and the answer
    // arrived from an ordinary mail provider's address on an unrelated domain, so the DOMAIN says nothing
    // and only the NAME identifies them. The address here is invented; the shape it stands for is not.
    @Test("the person answers from an unrelated mailbox and is still recognised by name")
    func theNameCarriesItWhenTheDomainSaysNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration",
                     venue: "54 Below")
        let r = pitch(ctx, on: p, contactName: "Corin Hale",
                      route: "https://www.corinhale.example/contact")
        let m = message("m", from: "Corin Hale <corin.hale@example.com>",
                        subject: "Re: Photography for the anniversary celebration")

        let verdict = ReplyCandidateMatch.judge([m], for: r, on: p, selfEmail: me)

        guard case .proposed(let top) = verdict else {
            Issue.record("expected a proposal, got \(verdict)"); return
        }
        #expect(top.message.messageId == "m")
    }

    @Test("an unrelated personal email is not proposed")
    func anUnrelatedPersonalEmailIsNotProposed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: nil, route: "https://www.perrivale.example/contact")
        let m = message("m", from: "Mum <mum@familymail.com>", subject: "Sunday lunch")

        #expect(ReplyCandidateMatch.judge([m], for: r, on: p, selfEmail: me) == .nothingLooksLikeThem)
    }

    // A different act at the same room is the nastiest near-miss, because it shares the venue, the
    // date window and the general subject matter, and differs only in who it is.
    @Test("a different act at the same room is not proposed")
    func aDifferentActAtTheSameRoomIsNotProposed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: nil, route: "https://www.perrivale.example/contact")
        let m = message("m", from: "Tobias Lund <tobias@tobiaslund.example>",
                        subject: "Re: Battle of the Siblings at The Green Room 42")

        #expect(ReplyCandidateMatch.judge([m], for: r, on: p, selfEmail: me) == .nothingLooksLikeThem)
    }

    // MARK: ambiguous is its own answer

    // A top candidate that does not beat the runner-up by the stated margin is not a proposal. Saying
    // "is this them?" about one of two equally plausible messages is asking Dan to guess, and having
    // him confirm the wrong one writes a stranger's address onto the contact (L11, L75).
    @Test("two equally plausible candidates are ambiguous, not a proposal")
    func twoEquallyPlausibleCandidatesAreAmbiguous() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: "Perri Vale", route: "https://www.perrivale.example/contact")
        let a = message("a", from: "Perri Vale <perri@perrivale.example>", subject: "Re: photography")
        let b = message("b", from: "Perri Vale <bookings@perrivale.example>", subject: "Re: photography")

        let verdict = ReplyCandidateMatch.judge([a, b], for: r, on: p, selfEmail: me)

        guard case .ambiguous(let top) = verdict else {
            Issue.record("two identical scores must be ambiguous, got \(verdict)"); return
        }
        #expect(Set(top.map(\.message.messageId)) == ["a", "b"])
    }

    @Test("a clear winner beside a weak also-ran is still a proposal")
    func aClearWinnerBesideAWeakAlsoRanIsAProposal() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: "Perri Vale", route: "https://www.perrivale.example/contact")
        let strong = message("strong", from: "Perri Vale <perri@perrivale.example>", subject: "Re: photography")
        let weak = message("weak", from: "Sam <sam@elsewhere.com>", subject: "Alex asked me to write")

        let verdict = ReplyCandidateMatch.judge([strong, weak], for: r, on: p, selfEmail: me)

        guard case .proposed(let top) = verdict else {
            Issue.record("expected a proposal, got \(verdict)"); return
        }
        #expect(top.message.messageId == "strong")
    }

    @Test("a refused message cannot break a tie or become the runner-up")
    func aRefusedMessageIsNotEvenInTheField() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: "Perri Vale", route: "https://www.perrivale.example/contact")
        let real = message("real", from: "Perri Vale <perri@perrivale.example>", subject: "Re: photography")
        let bulk = message("bulk", from: "Perri Vale <news@perrivale.example>", subject: "Perri Vale newsletter",
                           listUnsubscribe: "<https://perrivale.example/u>")

        let verdict = ReplyCandidateMatch.judge([real, bulk], for: r, on: p, selfEmail: me)

        guard case .proposed(let top) = verdict else {
            Issue.record("the bulk message must not make this ambiguous, got \(verdict)"); return
        }
        #expect(top.message.messageId == "real")
    }

    @Test("no candidates at all is nothing looks like them")
    func noCandidatesIsNothingLooksLikeThem() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, name: "Perri Vale", venue: "The Green Room 42")
        let r = pitch(ctx, on: p, contactName: nil, route: "https://www.perrivale.example/contact")

        #expect(ReplyCandidateMatch.judge([], for: r, on: p, selfEmail: me) == .nothingLooksLikeThem)
    }

    // MARK: the firing rate, measured over the preserve side

    // The single live sample is the case the token list was derived from, so it passes by construction
    // (L48, L107). What has to be measured is the OTHER side: how often the scorer fires on mail Dan
    // legitimately receives that is not the presenter. This runs every one of the five live pitches
    // against the same set of messages that must be preserved, and asserts the total firing rate is
    // zero rather than asserting each one separately, so a single over-match anywhere fails it.
    @Test("across all five live pitches, no message that must be preserved is ever proposed")
    func theFiringRateOnThePreserveSideIsZero() throws {
        let ctx = ModelContext(try container())
        let live: [(name: String, venue: String, presenter: String?, contact: String?, route: String)] = [
            ("54 Sings Shuffle Along, Or... A 10th Anniversary Celebration", "54 Below", nil,
             "Corin Hale", "https://www.corinhale.example/contact"),
            ("Song & Word", "The Green Room 42", "Vivace Arts Collective", "Vivace Arts Collective",
             "https://www.instagram.com/vivaceartscollective/"),
            ("Eva Noblezada & Alder Bourne", "The Green Room 42", nil, "Alder Bourne",
             "https://www.alderbourne.example/booking"),
            ("Battle of the Siblings", "The Green Room 42", nil, "Tobias Lund",
             "https://tobiaslund.example/appointments"),
            ("Perri Vale", "The Green Room 42", nil, nil, "https://www.perrivale.example/contact"),
        ]
        // Written for this test rather than captured, because a capture of Dan's real window is his
        // personal correspondence (L19). Each one is a shape that genuinely lands in his inbox.
        let mustBePreserved = [
            message("newsletter", from: "The Green Room 42 <hello@greenroom42.com>",
                    subject: "This week at The Green Room 42",
                    listUnsubscribe: "<https://greenroom42.com/u>"),
            message("ticket", from: "54 Below <boxoffice@54below.com>",
                    subject: "Your tickets for 54 Sings Shuffle Along"),
            message("press", from: "press@anotherhall.org", subject: "Media accreditation"),
            message("personal", from: "Mum <mum@familymail.com>", subject: "Sunday lunch"),
            message("otheract", from: "Quinn Asher <quinn@quinnasher.example>",
                    subject: "Re: my show at The Green Room 42"),
            message("bounce", from: "Mail Delivery Subsystem <mailer-daemon@googlemail.com>",
                    subject: "Delivery Status Notification"),
            message("danself", from: "Dan Wright <dan@danwrightphotography.com>",
                    subject: "Re: photography for your show"),
        ]

        var proposals: [(show: String, message: String)] = []
        for (i, row) in live.enumerated() {
            let p = show(ctx, name: "\(row.name) #\(i)", venue: row.venue, presenter: row.presenter)
            p.groupName = row.name
            let r = pitch(ctx, on: p, contactName: row.contact, route: row.route)
            if case .proposed(let top) = ReplyCandidateMatch.judge(mustBePreserved, for: r, on: p,
                                                                   selfEmail: me) {
                proposals.append((row.name, top.message.messageId))
            }
        }

        #expect(proposals.isEmpty, "proposed a message that must be preserved: \(proposals)")
    }

    // The other half of the same measurement: the scorer must still fire on the real thing, or a rate
    // of zero on the preserve side is bought by a scorer that never proposes anything at all.
    @Test("across all five live pitches, the presenter's own answer is proposed every time")
    func theRealAnswerIsFoundForEveryLivePitch() throws {
        let ctx = ModelContext(try container())
        let live: [(name: String, venue: String, presenter: String?, contact: String?, route: String,
                    reply: String)] = [
            ("54 Sings Shuffle Along, Or... A 10th Anniversary Celebration", "54 Below", nil,
             "Corin Hale", "https://www.corinhale.example/contact",
             "Corin Hale <corin.hale@example.com>"),
            ("Song & Word", "The Green Room 42", "Vivace Arts Collective", "Vivace Arts Collective",
             "https://www.instagram.com/vivaceartscollective/",
             "Vivace Arts Collective <hello@vivaceartscollective.org>"),
            ("Eva Noblezada & Alder Bourne", "The Green Room 42", nil, "Alder Bourne",
             "https://www.alderbourne.example/booking", "Alder Bourne <alder@alderbourne.example>"),
            ("Battle of the Siblings", "The Green Room 42", nil, "Tobias Lund",
             "https://tobiaslund.example/appointments",
             "Tobias Lund <tobias@tobiaslund.example>"),
            ("Perri Vale", "The Green Room 42", nil, nil, "https://www.perrivale.example/contact",
             "Perri Vale <perri@perrivale.example>"),
        ]

        var missed: [String] = []
        for (i, row) in live.enumerated() {
            let p = show(ctx, name: "\(row.name) #\(i)", venue: row.venue, presenter: row.presenter)
            p.groupName = row.name
            let r = pitch(ctx, on: p, contactName: row.contact, route: row.route)
            let reply = message("reply\(i)", from: row.reply, subject: "Re: photography for the show")
            if case .proposed = ReplyCandidateMatch.judge([reply], for: r, on: p, selfEmail: me) {
                continue
            }
            missed.append(row.name)
        }

        #expect(missed.isEmpty, "did not propose the presenter's own answer for: \(missed)")
    }
}
