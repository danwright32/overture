import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3, oracle part two on fixtures): each ported term answers the same over live models
// as over the same rows extracted to `RowFacts`. The live store and 4x corpus arm is
// `TermsOverFactsLiveStoreTests`; the per-term behaviour stays in each term's own suite, which also calls
// `TermsOverFacts.findings` on its own fixtures.
//
// The fixture is built so EVERY arm of the three terms is exercised, with a positive control for each
// (L159): a comparison that can never see a difference would pass a fixture where every term answers
// nothing, so the test first asserts each term DID answer something here.
@MainActor
@Suite("Every ported queue term answers the same over facts as over models (#4357)")
struct TermsOverFactsTests {
    private let asOf = "2026-09-20"

    private func context() throws -> ModelContext {
        // `OrgReachabilityAnswer` is named because the T5 tests insert one; leaving it to be reached through
        // the schema's relationships would make the fixture depend on how SwiftData resolves an unnamed type.
        ModelContext(try TestModelContainer.inMemory([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String?, opens: String?,
                     runEnd: String? = nil, missed: Int = 0, listing: String? = nil,
                     scoutTitle: String? = nil, nights: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: listing, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: nights ?? opens.map { [$0] } ?? [])
        p.missedScoutCount = missed
        p.scoutGroupName = scoutTitle
        ctx.insert(p)
        return p
    }

    // Invented names throughout (L155, L222).
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        // T3: a source-wide break of three flagged rows on one count, one of them with a live twin (T2).
        let hall = "Harrowgate Hall"
        row(ctx, key: "lantern|2026-10-03", title: "Lantern Parade", venue: hall, opens: "2026-10-03", missed: 4)
        row(ctx, key: "ninefold|2026-10-10", title: "Ninefold Quartet", venue: hall, opens: "2026-10-10", missed: 4)
        row(ctx, key: "copper|2026-10-17", title: "Copper Moth Revue", venue: hall, opens: "2026-10-17", missed: 4)
        row(ctx, key: "lantern live|2026-10-02", title: "Lantern Parade", venue: hall, opens: "2026-10-02",
            runEnd: "2026-10-06")
        // T2: a venueless flagged row and a venueless live twin, the `""` room both sides.
        row(ctx, key: "drift|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01", missed: 3)
        row(ctx, key: "drift live|2026-11-01", title: "Driftwood Choir", venue: nil, opens: "2026-11-01")
        // T1: three rows of one show at one room, one renamed on its display title but not its scout one,
        // joined through overlapping nights; one stopped being listed, so the collapse fronts the others.
        row(ctx, key: "saltmarsh a", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-04",
            runEnd: "2026-12-06", nights: ["2026-12-04", "2026-12-05", "2026-12-06"])
        row(ctx, key: "saltmarsh b", title: "Saltmarsh Suite, Renamed By Hand", venue: "Quillon Room",
            opens: "2026-12-05", scoutTitle: "Saltmarsh Suite")
        row(ctx, key: "saltmarsh c", title: "Saltmarsh Suite", venue: "Quillon Room", opens: "2026-12-06",
            missed: 1)
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func eachTermAnswersTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        // Positive controls: every term answered something in this fixture.
        #expect(!ShowLink.group(all.map(ShowLink.Row.init)).isEmpty, "the fixture forms no ShowLink group")
        #expect(!ShowLink.collapse(all.map(ShowLink.Row.init), drawn: ["saltmarsh a", "saltmarsh b"]).hidden.isEmpty,
                "the fixture hides no row in the collapse")
        #expect(ContradictedCancellation.contradictedKeys(among: all).count == 2,
                "the fixture should contradict exactly the twinned hall row and the venueless one")
        #expect(FeedBreakEvent.events(among: all, asOf: asOf).first?.coveredByAnotherCard == 1,
                "the fixture's feed break should count one member covered by another card")

        let findings = TermsOverFacts.findings(all, asOf: asOf, drawn: ["saltmarsh a", "saltmarsh b"])
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // The comparison can see a retained row that went stale: facts taken BEFORE a flagged row came back
    // into the feed disagree with the models after it, in T2, T3 and the collapse.
    @Test func theComparisonSeesARowThatChangedAfterItWasExtracted() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let stale = all.map(RowFacts.extract)
        let flagged = try #require(all.first { $0.naturalKey == "lantern|2026-10-03" })
        flagged.missedScoutCount = 0
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("ContradictedCancellation.contradictedKeys") },
                "a row that stopped being flagged was not seen by the contradiction comparison")
        #expect(findings.contains { $0.hasPrefix("FeedBreakEvent.events") },
                "a row that left a feed break was not seen by the event comparison")
        #expect(findings.contains { $0.hasPrefix("disappearedFromFeed") },
                "the flag itself was not compared")
        #expect(!findings.contains { $0.contains("Lantern") || $0.contains("Harrowgate") },
                "a finding named a title or a venue rather than the row's identifier")
    }

    // MARK: T4 and T5 (slice B)

    private let producer = "Wexcombe Touring Players"
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z") ?? Date(timeIntervalSince1970: 0)

    // On top of `seed`: a producer playing two rooms (so it qualifies and its shows inherit), one of its
    // shows carrying its own paid answer (so it must NOT inherit), a hall's own presenting brand, and a
    // presenter spelled exactly like a room. One fresh positive answer for the producer.
    private func seedProducers(_ ctx: ModelContext, _ all: [Prospect]) throws -> TermsOverFacts.Ledger {
        func row(_ key: String) throws -> Prospect { try #require(all.first { $0.naturalKey == key }) }
        try row("lantern|2026-10-03").presenter = producer      // Harrowgate Hall
        try row("saltmarsh a").presenter = producer             // Quillon Room
        let ownAnswer = try row("copper|2026-10-17")            // Harrowgate Hall, already checked itself
        ownAnswer.presenter = producer
        ownAnswer.reachabilityProbedAt = now.addingTimeInterval(-3600)
        try row("ninefold|2026-10-10").presenter = "Harrowgate Hall Presents"
        try row("saltmarsh c").presenter = "Quillon Room"
        let answer = OrgReachabilityAnswer(
            orgKey: try #require(OrgKey.stored(for: producer)), result: .emailFound,
            probedAt: now.addingTimeInterval(-86_400), sourceNaturalKey: "lantern|2026-10-03",
            sourceGroupName: "Lantern Parade", presenterName: producer,
            foundEmails: ["bookings@example.invalid"])
        ctx.insert(answer)
        return TermsOverFacts.Ledger(answers: [answer], now: now)
    }

    @Test func theProducerTablesAndTheLedgerAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let ledger = try seedProducers(ctx, all)
        // Positive controls: each arm of T4 and T5 answered something in this fixture (L159).
        let tables = QueueModel.ProducerTables(shows: all.map(ProducerGate.Show.init), overrides: .none)
        #expect(tables.corpus.distinctVenueCount(try #require(ProducerGate.key(producer))) == 2,
                "the producer should play two rooms")
        #expect(tables.venueBrands.contains("Harrowgate Hall Presents"), "the fixture holds no venue brand")
        #expect(tables.venueBrands.isRoomName("Quillon Room"), "the fixture holds no presenter spelled like a room")
        let inherited = QueueModel.inheritedAnswers(ledger.answers, corpus: all, overrides: .none,
                                                    refusals: .none, heldKeys: [], now: now)
        #expect(Set(inherited.keys) == ["lantern|2026-10-03", "saltmarsh a"],
                "the producer's two shows without their own answer should inherit, and only those")

        let findings = TermsOverFacts.findings(all, asOf: asOf, ledger: ledger)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // Dan's producer correction reaches the brand table `scope` builds through `ProducerTables(rows:overrides:)`
    // (slice C). Demoting the producer makes it a venue's own brand, so its card stops naming it. Asked
    // through `scope` itself, the path the app takes, because a check on the table alone would not see the
    // pass building it without the corrections. Runs in CI: the live store arm that first saw this fault is
    // gone with the slice C oracle that held it.
    @Test func aProducerCorrectionReachesTheBrandTableScopeBuilds() throws {
        let ctx = try context()
        let all = try seed(ctx)
        _ = try seedProducers(ctx, all)
        let key = try #require(ProducerGate.key(producer))
        func line(_ overrides: ProducerOverrides) throws -> String? {
            let items = QueueModel.items(from: all, corpus: all, overrides: overrides, now: now)
            return try #require(items.first { $0.id == "saltmarsh a" }).presenterLine
        }
        #expect(try line(.none) == producer, "with no correction the producer is named on its card")
        #expect(try line(ProducerOverrides(demoted: [key])) == nil,
                "a demoted producer is still named, so the correction never reached the brand table scope built")
    }

    // And the comparison can see a presenter that changed after the row was extracted: the projection, the
    // venue count and the inherited answer all move.
    @Test func theComparisonSeesAPresenterThatChangedAfterItWasExtracted() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let ledger = try seedProducers(ctx, all)
        let stale = all.map(RowFacts.extract)
        try #require(all.first { $0.naturalKey == "saltmarsh a" }).presenter = "Somebody Else Entirely"
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf, ledger: ledger)
        #expect(findings.contains { $0.hasPrefix("ProducerGate.Show differs") },
                "a presenter that changed was not seen in the projection")
        #expect(findings.contains { $0.hasPrefix("ProducerTables.corpus venue count differs") },
                "the producer's lost room was not seen in the corpus")
        #expect(findings.contains { $0.hasPrefix("OrgAnswerLedger.inherited differs") },
                "the lost inheritance was not seen in the ledger")
        #expect(!findings.contains { $0.contains("Wexcombe") || $0.contains("Quillon") || $0.contains("Harrowgate") },
                "a finding named a presenter or a venue rather than the row's identifier")
    }

    // MARK: T6 (slice C)

    // On top of `seed`: the Lantern Parade run at Harrowgate Hall (closing 2026-10-06) tours on to another
    // room two nights later, inside the engagement gap, so its three rows form one cross-venue engagement.
    @Test func theEngagementLinkAnswersTheSameOverFactsAsOverModelsAndSeesAVenueThatMoved() throws {
        let ctx = try context()
        _ = try seed(ctx)
        row(ctx, key: "lantern tour|2026-10-08", title: "Lantern Parade", venue: "Quillon Room", opens: "2026-10-08")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        // Positive control (L159): the touring row is linked to the hall's rows, and only through T6.
        let linked = EngagementLink.group(among: all)
        #expect(linked["lantern tour|2026-10-08"]?.count == 2,
                "the touring row should be linked to the hall's two Lantern Parade rows")
        #expect(TermsOverFacts.findings(all, asOf: asOf).isEmpty)

        // Facts taken before the touring row moved into the hall: the engagement no longer spans two rooms
        // over models, and the comparison has to say so by the row's identifier alone.
        let stale = all.map(RowFacts.extract)
        try #require(all.first { $0.naturalKey == "lantern tour|2026-10-08" }).venue = "Harrowgate Hall"
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("EngagementLink.group members differ") },
                "a row that stopped touring was not seen by the engagement comparison")
        #expect(!findings.contains { $0.contains("Lantern") || $0.contains("Quillon") || $0.contains("Harrowgate") },
                "a finding named a title or a venue rather than the row's identifier")
    }

    // The three entry points `scope` calls hand the term EVERY row, in any order. Asked of every rotation,
    // so each row is last once and first once: a forwarder that dropped or skipped one would be invisible
    // to oracle part two (both arms share it) and to a live comparison whose dropped row joins nothing,
    // which is how a dropped last row survived the first mutation run of this slice.
    @Test func theEntryPointsHandTheTermEveryRowInAnyOrder() throws {
        let ctx = try context()
        _ = try seed(ctx)
        row(ctx, key: "lantern tour|2026-10-08", title: "Lantern Parade", venue: "Quillon Room", opens: "2026-10-08")
        let all = try ctx.fetch(FetchDescriptor<Prospect>()).sorted { $0.naturalKey < $1.naturalKey }
        let drawn: Set<String> = ["saltmarsh a", "saltmarsh b"]
        #expect(!EngagementLink.group(among: all).isEmpty && !ShowLink.group(among: all).isEmpty,
                "the fixture links nothing, so the rotations below compare empty tables")
        for start in all.indices {
            let rotated = Array(all[start...] + all[..<start])
            #expect(EngagementLink.group(among: rotated) == EngagementLink.group(rotated.map(EngagementLink.Row.init)),
                    "EngagementLink.group(among:) differs from the term with rotation \(start)")
            #expect(ShowLink.group(among: rotated) == ShowLink.group(rotated.map(ShowLink.Row.init)),
                    "ShowLink.group(among:) differs from the term with rotation \(start)")
            let viaEntry = ShowLink.collapse(among: rotated, drawn: drawn)
            let viaTerm = ShowLink.collapse(rotated.map(ShowLink.Row.init), drawn: drawn)
            #expect(viaEntry.fronts == viaTerm.fronts && viaEntry.hidden == viaTerm.hidden,
                    "ShowLink.collapse(among:) differs from the term with rotation \(start)")
            #expect(QueueModel.ProducerTables(rows: rotated, overrides: .none)
                        .corpus == QueueModel.ProducerTables(shows: rotated.map(ProducerGate.Show.init), overrides: .none).corpus,
                    "ProducerTables(rows:) differs from the shows form with rotation \(start)")
        }
    }

    // MARK: slice D1, the members on the facts protocols

    // Contacts in every state the moved members tell apart: a live emailed pitch, a reply nobody has
    // answered, a reply answered since, a form pitch with and without an attached conversation, a bounce, a
    // booking recorded on the contact, and stand-downs of the pitch and of the closing note.
    private func seedContacts(_ ctx: ModelContext, on p: Prospect) {
        let at = { (offset: Double) in Date(timeIntervalSince1970: 1_790_000_000 + offset) }
        func contact(_ id: String, email: String? = nil, form: String? = nil,
                     _ shape: (Recipient) -> Void) {
            let r = Recipient(id: id, email: email, provenance: .act, contactFormURL: form)
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        contact("live@example.invalid", email: "live@example.invalid") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.gmailMessageId = "m1"; $0.gmailThreadId = "t1"
            $0.outreachStoodDownAt = at(50)
        }
        contact("waiting@example.invalid", email: "waiting@example.invalid") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.gmailMessageId = "m2"; $0.gmailThreadId = "t2"
            $0.replied = true; $0.repliedAt = at(100); $0.inboundReplySentAt = at(90)
            $0.replyDraftRequestedAt = at(150)   // slice F: a reply draft still awaited, so it can stall
        }
        contact("answered@example.invalid", email: "answered@example.invalid") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.gmailMessageId = "m3"; $0.gmailThreadId = "t3"
            $0.replied = true; $0.repliedAt = at(100); $0.replyHandledAt = at(200)
            $0.closingNoteStoodDownAt = at(300)
        }
        contact("form-quiet", form: "https://example.invalid/contact") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.outreachChannel = .contactForm
            $0.formOutreachRecordedAt = at(0)
        }
        contact("form-attached", form: "https://example.invalid/contact") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.outreachChannel = .contactForm
            $0.formOutreachRecordedAt = at(0); $0.gmailThreadId = "t5"
        }
        contact("bounced@example.invalid", email: "bounced@example.invalid") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.gmailMessageId = "m6"; $0.bounced = true
        }
        contact("booked@example.invalid", email: "booked@example.invalid") {
            $0.sendState = .sent; $0.sentAt = at(0); $0.gmailMessageId = "m7"; $0.resolution = .booked
            $0.outcomeSource = .manual
        }
        contact("untried@example.invalid", email: "untried@example.invalid") { _ in }
    }

    @Test func theMovedMembersAnswerTheSameOverFactsAsOverModelsAndEachTakesBothValues() throws {
        let ctx = try context()
        let all = try seed(ctx)
        let pitched = try #require(all.first { $0.naturalKey == "saltmarsh a" })
        seedContacts(ctx, on: pitched)
        pitched.statusRaw = ReviewStatus.contacted.rawValue
        pitched.outreachStoodDownAt = Date(timeIntervalSince1970: 1_790_000_050)
        try #require(all.first { $0.naturalKey == "drift|2026-11-01" }).showOutcomeRaw = ShowOutcome.allCases.first?.rawValue
        let leadBooked = try #require(all.first { $0.naturalKey == "ninefold|2026-10-10" })
        leadBooked.outcomeRaw = Outcome.booked.rawValue

        // Positive controls (L159): across the fixture's contacts, every Boolean member is true for one and
        // false for another, so a member that answered the same everywhere could not hide behind agreement.
        let contacts = pitched.factContacts.map(TermsOverFacts.ContactMembers.init)
        for child in Mirror(reflecting: contacts[0]).children where child.value is Bool {
            let label = child.label ?? "?"
            let values = Set(contacts.map { member in
                Mirror(reflecting: member).children.first { $0.label == label }?.value as? Bool
            })
            #expect(values == [true, false], "contact member \(label) takes only \(values) in the fixture")
        }
        // And every show member, whatever its type, takes at least two values across the fixture's shows.
        let shows = all.map(TermsOverFacts.ShowMembers.init)
        for child in Mirror(reflecting: shows[0]).children {
            let label = child.label ?? "?"
            let values = Set(shows.map { member in
                String(describing: Mirror(reflecting: member).children.first { $0.label == label }?.value)
            })
            #expect(values.count >= 2, "show member \(label) takes only \(values) in the fixture")
        }

        // Behaviour, read through the protocol, so these hold the rules themselves once the part one oracle
        // is deleted (part two cannot: both of its arms run the same body).
        func member(_ id: String) throws -> TermsOverFacts.ContactMembers {
            TermsOverFacts.ContactMembers(try #require(pitched.factContacts.first { $0.id == id }))
        }
        #expect(try member("form-quiet").hasProvenOutreach, "a recorded form pitch is proven outreach")
        #expect(try !member("untried@example.invalid").hasProvenOutreach, "an unsent contact is not")
        #expect(try member("waiting@example.invalid").replyArrivedAt == Date(timeIntervalSince1970: 1_790_000_090),
                "a reply is dated by when they sent it, not when it was noticed")
        #expect(TermsOverFacts.ShowMembers(leadBooked).isBooked,
                "a booking recorded on the show, with no contact booked, is still a booked show")

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))

        // A contact answered after its facts were taken: the comparison names the member and the contact.
        let stale = all.map(RowFacts.extract)
        try #require(pitched.recipients.first { $0.id == "waiting@example.invalid" }).replyHandledAt =
            Date(timeIntervalSince1970: 1_790_000_500)
        let staleFindings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(staleFindings.contains { $0.hasPrefix("contact members") && $0.contains("hasUnhandledReply") },
                "a reply answered after extraction was not seen by the member comparison")
        #expect(!staleFindings.contains { $0.contains("example.invalid") },
                "a finding named a contact's address rather than its identifier")
    }

    // MARK: slice D2, the reached-out terms

    // Pitches in every state the reached-out terms tell apart, dated against the instant the comparison
    // judges at (noon Eastern on `asOf`): on a show still to come, a silent contact owed a nudge, a second
    // silent contact due at the same moment (an address tie), an unwatched form pitch, and two repliers; on
    // a show already played, a contact who replied (the close-out is owed) and an unwatched form pitch whose
    // night has passed (Dan is asked what happened).
    private func seedReachedOut(_ ctx: ModelContext, _ all: [Prospect]) throws {
        let now = TermsOverFacts.reachedOutInstant(asOf)
        let daysAgo = { (days: Double) in now.addingTimeInterval(-days * 86_400) }
        func contact(_ id: String, on p: Prospect, email: String? = nil, form: Bool = false,
                     _ shape: (Recipient) -> Void = { _ in }) {
            let r = Recipient(id: id, email: email, provenance: .act,
                              contactFormURL: form ? "https://example.invalid/contact" : nil)
            r.sendState = .sent
            r.sentAt = daysAgo(20)
            if form {
                r.outreachChannel = .contactForm
                r.formOutreachRecordedAt = daysAgo(20)
            } else {
                r.gmailMessageId = "m-\(id)"
                r.gmailThreadId = "t-\(id)"
            }
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        let coming = try #require(all.first { $0.naturalKey == "saltmarsh a" })        // 2026-12-04
        contact("nudge-a@example.invalid", on: coming, email: "nudge-a@example.invalid")
        contact("nudge-b@example.invalid", on: coming, email: "nudge-b@example.invalid")
        contact("form-coming", on: coming, form: true)
        let played = try #require(all.first { $0.naturalKey == "lantern live|2026-10-02" })
        played.performanceDate = "2026-09-10"
        played.runEndDate = nil
        contact("closer@example.invalid", on: played, email: "closer@example.invalid") {
            $0.replied = true; $0.repliedAt = daysAgo(15); $0.replyHandledAt = daysAgo(14)
        }
        contact("form-played", on: played, form: true)
        let replies = try #require(all.first { $0.naturalKey == "copper|2026-10-17" })
        replies.missedScoutCount = 0
        contact("first@example.invalid", on: replies, email: "first@example.invalid") {
            $0.replied = true; $0.repliedAt = daysAgo(3)
        }
        contact("second@example.invalid", on: replies, email: "second@example.invalid") {
            $0.replied = true; $0.repliedAt = daysAgo(2)
        }
        // A show that BOOKED through one contact: its other, still silent, pitch is no longer anything to
        // reach out about, so the show stays off the list.
        let booked = try #require(all.first { $0.naturalKey == "drift live|2026-11-01" })
        contact("silent-on-booked@example.invalid", on: booked, email: "silent-on-booked@example.invalid")
        contact("booker@example.invalid", on: booked, email: "booker@example.invalid") {
            $0.resolution = .booked
        }
    }

    @Test func theReachedOutTermsAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedReachedOut(ctx, all)
        let now = TermsOverFacts.reachedOutInstant(asOf)
        // Positive controls (L159): rows on the list, and every action the row's control can take.
        let rows = ReachedOutQueue.activeWithDates(from: all, now: now)
        #expect(rows.count == 3, "the fixture should put three shows on the reached-out list")
        #expect(!rows.contains { $0.prospect.naturalKey == "drift live|2026-11-01" },
                "a show booked through one contact still put its other pitch on the reached-out list")
        let actions = Set(all.flatMap { p in p.recipients.map { ReachedOutAction.of($0, in: p, now: now, today: asOf) } })
        #expect(actions == Set(ReachedOutAction.allCases), "the fixture reaches only \(actions)")
        #expect(rows.first { $0.prospect.naturalKey == "copper|2026-10-17" }?.recipient.id == "first@example.invalid",
                "the earliest replier should speak for a show two contacts replied on")
        // Both nudges fell due 14 days before `now` and the form pitch's clock is the night itself, months
        // out, so the two nudges tie on the soonest date and the address breaks the tie.
        #expect(rows.first { $0.prospect.naturalKey == "saltmarsh a" }?.recipient.id == "nudge-a@example.invalid",
                "the soonest due contact, address first on a tie, should speak for the show still to come")

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }

    // The tie class classifier: facts taken before a reply arrived disagree ACROSS classes (a different reply
    // instant), and facts taken before a tied contact's address changed disagree only WITHIN one.
    @Test func theRepresentativeComparisonTellsATieBreakFromARuleFault() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedReachedOut(ctx, all)
        let replies = try #require(all.first { $0.naturalKey == "copper|2026-10-17" })
        let second = try #require(replies.recipients.first { $0.id == "second@example.invalid" })
        let stale = all.map(RowFacts.extract)
        second.repliedAt = TermsOverFacts.reachedOutInstant(asOf).addingTimeInterval(-5 * 86_400)
        let across = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(across.contains { $0.contains("representative differs across tie classes") },
                "an earlier reply arriving after extraction was not seen as a different tie class")

        second.repliedAt = try #require(replies.recipients.first { $0.id == "first@example.invalid" }?.repliedAt)
        let tied = all.map(RowFacts.extract)
        second.email = "a-second@example.invalid"
        let within = TermsOverFacts.findings(all, facts: tied, asOf: asOf)
        #expect(within.contains { $0.contains("representative differs within its tie class") },
                "a tie broken differently by address was not seen as a tie break")
        #expect(!(across + within).contains { $0.contains("example.invalid") },
                "a finding named a contact's address rather than its identifier")
    }

    // MARK: slice E1, the stage placement and the members it reads

    // One show in each stage the placement counts, plus a past client's show offered beyond the ordinary
    // window, so every arm of `matches` answers true somewhere (L159). Invented names throughout (L155, L222).
    private func seedStages(_ ctx: ModelContext) throws -> [Prospect] {
        func show(_ key: String, opens: String = "2026-10-20", status: ReviewStatus,
                  _ shape: (Prospect) -> Void = { _ in }) -> Prospect {
            let p = row(ctx, key: key, title: "Stage \(key)", venue: "Quillon Room", opens: opens)
            p.statusRaw = status.rawValue
            shape(p)
            return p
        }
        func contact(_ id: String, on p: Prospect, _ shape: (Recipient) -> Void) {
            let r = Recipient(id: id, email: "\(id)@example.invalid", provenance: .act)
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        let claimed = Date(timeIntervalSince1970: 1_700_000_000)
        _ = show("scout", status: .new)
        _ = show("client", opens: "2027-03-01", status: .new) { $0.sourceIds = ["client-a"] }
        _ = show("prep", status: .queued)
        _ = show("review", status: .drafted) { $0.draftBody = "Hi there,\n\nA short note." }
        _ = show("approved", status: .approved) { $0.draftBody = "Hi there,\n\nA short note." }
        let blocked = show("blocked", status: .contacted) { $0.draftBody = "Hi there,\n\nA short note." }
        contact("held", on: blocked) { $0.looksLikeVenue = true }
        contact("sent", on: blocked) { $0.sendState = .sent; $0.sentAt = claimed }
        _ = show("errored", status: .approved) { $0.sendError = "refused" }
        contact("stuck", on: show("stuck", status: .contacted)) { $0.sendState = .sending; $0.sendClaimedAt = claimed }
        contact("degraded", on: show("degraded", status: .contacted)) {
            $0.sendState = .sent; $0.replyTrackingDegraded = true
        }
        contact("threading", on: show("threading", status: .contacted)) {
            $0.sendState = .sent; $0.threadingDegraded = true
        }
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func theStagePlacementAnswersTheSameOverFactsAsOverModelsInEveryStage() throws {
        let ctx = try context()
        let all = try seedStages(ctx)
        let stageContext = TermsOverFacts.stageContext(for: all, asOf: asOf)
        let placed = StageNavigation.placements(in: all, context: stageContext)
        // Positive controls (L159): every counted stage holds a show here, and the past client's far show is
        // offered for triage, which only the client window can do.
        for focus in StageNavigation.countedFocuses {
            #expect(!StageNavigation.naturalKeys(for: focus, in: placed).isEmpty,
                    "no show in the fixture is placed under \(focus.rawValue)")
        }
        #expect(StageNavigation.naturalKeys(for: .scout, in: placed).contains("client"),
                "the past client's show beyond the ordinary window was not offered")
        let clean = TermsOverFacts.findings(all, asOf: asOf)
        #expect(clean.isEmpty, Comment(rawValue: clean.joined(separator: "\n")))

        // A contact claimed for sending after its facts were taken: the stuck stage and the contact's own
        // rule both move over models and not over the retained facts, and the findings say so by identifier.
        let stale = all.map(RowFacts.extract)
        let quiet = try #require(all.first { $0.naturalKey == "degraded" }?.recipients.first)
        quiet.sendState = .sending
        quiet.sendClaimedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("StageNavigation.placements sendStuck differs") },
                "a contact that became stuck after extraction was not seen by the placement comparison")
        #expect(findings.contains { $0.hasPrefix("stage contact members differ") },
                "a contact that became stuck after extraction was not seen by the member comparison")
        #expect(!findings.contains { $0.contains("example.invalid") || $0.contains("Stage ") },
                "a finding named an address or a title rather than an identifier")
    }

    // A show's status, read on the model, through `ProspectFacts`, through `PrepEligibilityFacts` and through the
    // view the stage predicate hands Prep, returns, and every route returns the same. A first cut of this slice
    // made `ProspectFacts` refine `PrepEligibilityFacts`, and `Prospect.status` then dispatched back into itself
    // until the stack ran out, crashing the test host 261 times in one run. A recursion here is a crash, not a
    // red expectation, so this test passing at all is the assertion that matters.
    @Test func aShowsStatusReadThroughEveryRouteReturnsAndAgrees() throws {
        let ctx = try context()
        let all = try seedStages(ctx)
        func viaPrep<T: PrepEligibilityFacts>(_ t: T) -> ReviewStatus { t.status }
        func viaFacts<T: ProspectFacts>(_ t: T) -> ReviewStatus { t.status }
        for p in all {
            let direct = p.status
            #expect(viaPrep(p) == direct && viaFacts(p) == direct && viaPrep(PrepEligibilityView(row: p)) == direct
                    && viaPrep(PrepEligibilityView(row: RowFacts.extract(p))) == direct,
                    Comment(rawValue: "a route disagreed about the status of row \(p.persistentModelID)"))
            func draftViaPrep<T: PrepEligibilityFacts>(_ t: T) -> Bool { t.hasDraft }
            #expect(draftViaPrep(p) == p.hasDraft && draftViaPrep(PrepEligibilityView(row: p)) == p.hasDraft)
        }
        #expect(Set(all.map(\.status)).count > 2, "the fixture holds too few statuses for this to compare anything")
    }

    // The rules the placement reads, held on their own once oracle part one is deleted.
    @Test func theMovedStageRulesHoldTheirMeaning() throws {
        let ctx = try context()
        let all = try seedStages(ctx)
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.naturalKey, $0) })
        let blocked = try #require(byKey["blocked"])
        let scout = try #require(byKey["scout"])
        #expect(blocked.blockedContactCount == 1, "one held contact on a show already sent to is one blocked contact")
        #expect(blocked.hasEnteredSendHalf, "a contacted show has entered the send half")
        #expect(!scout.hasEnteredSendHalf, "an untriaged show has not")
        #expect(blocked.greetingAudienceSize == 1, "one pending reachable contact is an audience of one")
        // Two pending, reachable contacts: one send reaches both together, and one each when sent separately.
        let pair = try #require(byKey["scout"])
        for id in ["first", "second"] {
            let r = Recipient(id: id, email: "\(id)@example.invalid", provenance: .act)
            ctx.insert(r)
            pair.recipients.append(r)
        }
        #expect(pair.sendsTogether && pair.greetingAudienceSize == 2, "together, one send reaches both")
        pair.sendsTogetherOverride = false
        #expect(!pair.sendsTogether && pair.greetingAudienceSize == 1, "separately, each send reaches one")
        let stuck = try #require(byKey["stuck"]?.recipients.first)
        #expect(stuck.isSendStuck(now: Date(timeIntervalSince1970: 1_700_000_000 + RunTimeouts.send)),
                "a claim as old as the send timeout is stuck")
        #expect(!stuck.isSendStuck(now: Date(timeIntervalSince1970: 1_700_000_000 + RunTimeouts.send - 1)),
                "a claim a second younger is not")
        // Only a claim still SENDING is stuck: a contact the send finished for is not, whatever claim it carries.
        let sent = try #require(byKey["degraded"]?.recipients.first)
        sent.sendClaimedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!sent.isSendStuck(now: Date(timeIntervalSince1970: 1_700_000_000 + 10 * RunTimeouts.send)),
                "a sent contact carrying an old claim was called stuck")
        let review = try #require(byKey["review"])
        let prep = try #require(byKey["prep"])
        #expect(review.hasDraft && !prep.hasDraft)
        review.reprepDraftRequested = true
        #expect(review.isReprepQueued, "a requested redraft is queued Prep work")
        #expect(scout.hasOpened(today: "2026-10-21"))
        #expect(!scout.hasOpened(today: "2026-10-20"), "a run opening tonight has not opened")
    }

    // MARK: slice F, the agent input terms

    // A drafted show with nobody to send to and one with somebody; reply drafts asked for an hour before the
    // judging instant (stalled), a minute before it (still inside the five minute timeout), once before an
    // answer was sent (not awaited at all), and once with a draft already on file (not awaited either).
    private func seedAgentInputs(_ ctx: ModelContext, _ all: [Prospect]) throws {
        let now = TermsOverFacts.reachedOutInstant(asOf)
        try #require(all.first { $0.naturalKey == "lantern|2026-10-03" }).statusRaw = ReviewStatus.drafted.rawValue
        let drafted = try #require(all.first { $0.naturalKey == "ninefold|2026-10-10" })
        drafted.statusRaw = ReviewStatus.drafted.rawValue
        drafted.presenter = "Wexcombe Touring Players"
        func contact(_ id: String, _ shape: (Recipient) -> Void) {
            let r = Recipient(id: id, email: id, provenance: .act)
            shape(r)
            ctx.insert(r)
            drafted.recipients.append(r)
        }
        contact("stalled@example.invalid") { $0.replyDraftRequestedAt = now.addingTimeInterval(-3600) }
        contact("fresh@example.invalid") { $0.replyDraftRequestedAt = now.addingTimeInterval(-60) }
        contact("answered@example.invalid") {
            $0.replyDraftRequestedAt = now.addingTimeInterval(-7200); $0.replyHandledAt = now.addingTimeInterval(-3600)
        }
        contact("drafted@example.invalid") {
            $0.replyDraftRequestedAt = now.addingTimeInterval(-7200); $0.replyDraftBody = "Thanks, see you there."
        }
    }

    @Test func theAgentInputTermsAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedAgentInputs(ctx, all)
        let now = TermsOverFacts.reachedOutInstant(asOf)
        // Positive controls (L159), and the rules themselves, which part two cannot hold.
        #expect(DraftedDeadEnd.count(in: all) == 1, "exactly the drafted show with no contacts is a dead end")
        // Named, not only counted: an inverted rule swaps which drafted show it picks and keeps the count.
        let deadEnd = try #require(all.first { $0.naturalKey == "lantern|2026-10-03" })
        let withContacts = try #require(all.first { $0.naturalKey == "ninefold|2026-10-10" })
        #expect(DraftedDeadEnd.hasNobodyToSendTo(deadEnd), "the drafted show with no contacts is not a dead end")
        #expect(!DraftedDeadEnd.hasNobodyToSendTo(withContacts), "a drafted show with contacts reads as a dead end")
        // The organisation count's entry point hands its term every row in any order (the slice C rotation).
        let sorted = all.sorted { $0.naturalKey < $1.naturalKey }
        for start in sorted.indices {
            let rotated = Array(sorted[start...] + sorted[..<start])
            #expect(QueueModel.organisationRowCounts(among: rotated) == QueueModel.organisationRowCounts(rotated.map(\.presenter)),
                    "organisationRowCounts(among:) differs from the term with rotation \(start)")
        }
        let stalled = StalledReplyDraft.dueRecipients(from: all, now: now, runAlive: false)
        #expect(stalled.map(\.recipient.id) == ["stalled@example.invalid"],
                "only the draft asked for an hour ago is stalled; the fresh, answered and delivered ones are not")
        #expect(StalledReplyDraft.dueRecipients(from: all, now: now, runAlive: true).isEmpty,
                "a live reply run means nothing is stalled yet")
        #expect(StalledReplyDraft.dueRecipients(from: all, now: .distantFuture, runAlive: false).count == 2,
                "at the end of time both awaited drafts are stalled and the two that are not awaited are not")
        #expect(!QueueModel.organisationRowCounts(among: all).isEmpty, "the fixture presents no organisation")

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))

        // A draft delivered after the facts were taken: the stalled list and the member comparison both see it.
        let stale = all.map(RowFacts.extract)
        try #require(all.flatMap(\.recipients).first { $0.id == "stalled@example.invalid" }).replyDraftBody = "Late, but here."
        let staleFindings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(staleFindings.contains { $0.hasPrefix("StalledReplyDraft.dueRecipients differs") },
                "a draft delivered after extraction was not seen by the stalled list comparison")
        #expect(!staleFindings.contains { $0.contains("example.invalid") },
                "a finding named a contact's address rather than its identifier")
    }

    // MARK: slice H, the long tail (T8)

    // Every arm of the long tail answers something here (L159): a dismissed row and a full tie in the queue
    // order, three later lookalikes of one row (two tied on an unknown sighting, one newer), an unseen merge
    // survivor still ahead and open beside one closed by a do not contact and one already played, and one
    // possible match flagged across three shows. Invented names throughout (L155, L222).
    private func seedLongTail(_ ctx: ModelContext) throws -> [Prospect] {
        let target = row(ctx, key: "tail target", title: "Harbour Lantern", venue: "Quillon Room", opens: "2026-11-02")
        let lookalikes: [(key: String, seen: Date?)] = [("tail look b", nil), ("tail look a", nil),
                                                        ("tail look new", Date(timeIntervalSince1970: 1_790_000_000))]
        for (key, seen) in lookalikes {
            let p = row(ctx, key: key, title: "Harbour Lantern Again", venue: "Quillon Room", opens: "2026-11-03")
            p.arrivedLookingLike = target.naturalKey
            p.firstSeenAt = seen
        }
        let unseen = Date(timeIntervalSince1970: 1_790_000_000)
        row(ctx, key: "tail survivor open", title: "Tallow Choir", venue: "Quillon Room", opens: "2026-11-10")
            .mergeSurvivorUnseenAt = unseen
        let closed = row(ctx, key: "tail survivor closed", title: "Tallow Choir Two", venue: "Quillon Room", opens: "2026-11-11")
        closed.mergeSurvivorUnseenAt = unseen
        closed.orgDoNotContact = true
        row(ctx, key: "tail survivor played", title: "Tallow Choir Three", venue: "Quillon Room", opens: "2026-08-01")
            .mergeSurvivorUnseenAt = unseen
        for k in 0..<3 {
            row(ctx, key: "tail fan \(k)", title: "Fan Act \(k)", venue: "Quillon Room", opens: "2026-12-0\(k + 1)")
                .possibleMatchName = "Wrenfold Ensemble"
        }
        row(ctx, key: "tail tie a", title: "Undated A", venue: nil, opens: nil)
        row(ctx, key: "tail tie b", title: "Undated B", venue: nil, opens: nil)
        row(ctx, key: "tail empty night", title: "Blank Night", venue: nil, opens: nil).performanceDate = ""
        row(ctx, key: "tail gone", title: "Dismissed Row", venue: nil, opens: "2026-10-01").statusRaw =
            ReviewStatus.dismissed.rawValue
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func theLongTailAnswersTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seedLongTail(ctx)
        // Positive controls (L159).
        let scope = QueueModel.queueScope(all)
        #expect(scope.count == all.count - 1, "the dismissed row was not the only one left out of the scope")
        #expect(QueueModel.laterLookalikes(among: all)["tail target"] == ["tail look new", "tail look a", "tail look b"],
                "newest first, then the tied sightings by key")
        #expect(QueueRenderPass.unseenSurvivors(among: all, today: asOf) == ["tail survivor open"],
                "only the open survivor still ahead is unseen")
        #expect(QueueRenderPass.fanOutWarning(all) != nil, "the fixture's fan out drew no warning")
        #expect(QueueModel.nightsByKey(among: all)["tail tie a"] == nil && QueueModel.titlesByKey(among: all).count == all.count)
        #expect(QueueModel.nightsByKey(among: all)["tail empty night"] == nil, "a night stored as the empty string is no night")
        #expect(QueueModel.nightsByKey(among: all)["tail target"] == "2026-11-02")
        let clean = TermsOverFacts.findings(all, asOf: asOf)
        #expect(clean.isEmpty, Comment(rawValue: clean.joined(separator: "\n")))

        // Facts taken before the open survivor's organisation asked Dan to stop, and before a lookalike's
        // pointer moved: the comparison has to say so by the row's identifier alone.
        let stale = all.map(RowFacts.extract)
        try #require(all.first { $0.naturalKey == "tail survivor open" }).orgDoNotContact = true
        try #require(all.first { $0.naturalKey == "tail look new" }).arrivedLookingLike = nil
        let findings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(findings.contains { $0.hasPrefix("QueueRenderPass.unseenSurvivors differs") })
        #expect(findings.contains { $0.hasPrefix("isClosed differs") })
        #expect(findings.contains { $0.hasPrefix("QueueModel.laterLookalikes differs") })
        #expect(!findings.contains { $0.contains("Wrenfold") || $0.contains("Tallow") || $0.contains("Harbour") },
                "a finding named a title or a match rather than an identifier")
    }

    // The closing rule, held on its own: a do not contact closes a show, a booking closes it, an open show is
    // open, and the model's member and the protocol's agree on each.
    @Test func theClosingRuleHoldsItsMeaningOnBothConformers() throws {
        let ctx = try context()
        let all = try seedLongTail(ctx)
        func viaFacts<T: ProspectFacts>(_ t: T) -> Bool { t.isClosed }
        let open = try #require(all.first { $0.naturalKey == "tail survivor open" })
        let refused = try #require(all.first { $0.naturalKey == "tail survivor closed" })
        #expect(!open.isClosed && !viaFacts(open) && !RowFacts.extract(open).isClosed)
        #expect(refused.isClosed && viaFacts(refused) && RowFacts.extract(refused).isClosed)
        open.outcomeRaw = Outcome.booked.rawValue
        #expect(open.isClosed && viaFacts(open), "a booked show is closed")
        // A lead Dan closed by hand, softly or for good, on a show with no contact yet: only the outcome says so.
        for lost in [Outcome.lostSoft, .lostHard] {
            open.outcomeRaw = lost.rawValue
            #expect(open.performanceStatus == .new, "the fixture should leave the outcome as the only closing fact")
            #expect(open.isClosed && viaFacts(open) && RowFacts.extract(open).isClosed,
                    Comment(rawValue: "a lead closed as \(lost.rawValue) still reads as open"))
        }
    }

    // MARK: slice E2, the due work terms

    // On top of the reached-out pitches, one of each thing the due lists settle between them: a form pitch on
    // the played show with a proposed conversation (the confirm question wins over the post-event prompt), a
    // reply on the played show nobody has answered (the answer comes before how the show ended), the two
    // repliers on the show still to come made one joint email the second of them answered (one row, standing
    // on the writer), a reply whose requested draft died (listed once, as the stalled draft), and a silent
    // pitch on a show Dan resolved by hand (its nudges stopped).
    private func seedDueWork(_ ctx: ModelContext, _ all: [Prospect]) throws {
        try seedReachedOut(ctx, all)
        let now = TermsOverFacts.reachedOutInstant(asOf)
        let daysAgo = { (days: Double) in now.addingTimeInterval(-days * 86_400) }
        func contact(_ id: String, on p: Prospect, _ shape: (Recipient) -> Void = { _ in }) {
            let r = Recipient(id: id, email: id, provenance: .act)
            r.sendState = .sent
            r.sentAt = daysAgo(20)
            r.gmailMessageId = "m-\(id)"
            r.gmailThreadId = "t-\(id)"
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        let played = try #require(all.first { $0.naturalKey == "lantern live|2026-10-02" })
        let form = try #require(played.recipients.first { $0.id == "form-played" })
        form.replyProposedMessageId = "proposed-message"
        form.replyProposedThreadId = "proposed-thread"
        form.replyProposedFromAddress = "proposer@example.invalid"
        form.replyProposedSentAt = daysAgo(4)
        contact("late@example.invalid", on: played) { $0.replied = true; $0.repliedAt = daysAgo(1) }
        let replies = try #require(all.first { $0.naturalKey == "copper|2026-10-17" })
        for r in replies.recipients {
            r.sendGroupId = "copper-group"
            r.replyFromAddress = "second@example.invalid"
        }
        let stalledShow = try #require(all.first { $0.naturalKey == "saltmarsh b" })
        contact("stalled-reply@example.invalid", on: stalledShow) {
            $0.replied = true; $0.repliedAt = daysAgo(1); $0.replyDraftRequestedAt = now.addingTimeInterval(-3600)
        }
        let resolved = try #require(all.first { $0.naturalKey == "saltmarsh c" })
        resolved.outcomeSourceRaw = OutcomeSource.manual.rawValue
        contact("resolved-show@example.invalid", on: resolved)
    }

    @Test func theDueWorkTermsAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedDueWork(ctx, all)
        let now = TermsOverFacts.reachedOutInstant(asOf)
        // Positive controls (L159): every list holds a row, and each settles what it should against the others.
        let rows = DueWork.rows(prospects: all, inquiries: [], now: now, replyRunAlive: false)
        #expect(rows.afterTheShow.map(\.recipient.id) == ["closer@example.invalid"],
                "only the replier who was answered is owed the post-event question; the proposal and the waiting reply come first")
        #expect(rows.conversationsToConfirm.map(\.recipient.id) == ["form-played"],
                "the form pitch with a proposed conversation is the one to confirm")
        #expect(rows.stalledReplyDrafts.map(\.recipient.id) == ["stalled-reply@example.invalid"],
                "the reply whose requested draft died is the stalled one")
        let waiting = rows.repliesToAnswer.compactMap { conversation -> String? in
            guard case .show(_, let r) = conversation else { return nil }
            return r.id
        }
        #expect(waiting == ["second@example.invalid", "late@example.invalid"],
                "the joint email is one row standing on its writer, the stalled reply is not listed twice, longest wait first")
        let silent = Set(rows.silent.map(\.recipient.id))
        #expect(silent.isSuperset(of: ["nudge-a@example.invalid", "nudge-b@example.invalid"]), "the silent pitches are not owed a nudge")
        #expect(!silent.contains("resolved-show@example.invalid"), "a show Dan resolved by hand still nudges")
        #expect(DueWork.nextChange(prospects: all, now: now, replyRunAlive: false) == EasternDate.date(from: "2026-10-18"),
                "the next change is the day after the earliest show with a pitch still owed its post-event question")

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))

        // A reply answered after the facts were taken: both lists it moves between see it.
        let stale = all.map(RowFacts.extract)
        try #require(all.flatMap(\.recipients).first { $0.id == "late@example.invalid" }).replyHandledAt = now
        let staleFindings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        #expect(staleFindings.contains { $0.hasPrefix("DueWork.rows repliesToAnswer differs") },
                "a reply answered after extraction was not seen by the replies comparison")
        #expect(staleFindings.contains { $0.hasPrefix("DueWork.rows afterTheShow differs") },
                "a reply answered after extraction was not seen by the post-event comparison")
        #expect(!staleFindings.contains { $0.contains("example.invalid") },
                "a finding named a contact's address rather than its identifier")
    }

    // MARK: slice G2, the card and the members it reads

    // An approved draft with three contacts (a presenter and an act, both sendable, and a press inbox the guard
    // holds), one of them an answered reply whose draft predates their message; a drafted show with no subject
    // line and an uncleared day off; and a show whose only route is a form Dan has opened but not confirmed.
    private func seedCard(_ ctx: ModelContext, _ all: [Prospect]) throws {
        let now = TermsOverFacts.reachedOutInstant(asOf)
        func show(_ key: String) throws -> Prospect { try #require(all.first { $0.naturalKey == key }) }
        func contact(_ id: String, on p: Prospect, email: String? = nil, provenance: RecipientProvenance,
                     form: String? = nil, _ shape: (Recipient) -> Void = { _ in }) {
            let r = Recipient(id: id, email: email, provenance: provenance, contactFormURL: form)
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        let approved = try show("lantern|2026-10-03")
        approved.statusRaw = ReviewStatus.approved.rawValue
        approved.draftSubject = "Photographs of the Lantern Parade"
        approved.draftBody = "Hello,\n\nI photograph performing arts in New York."
        approved.showSummaryAbsentReasonRaw = ShowSummaryAbsence.noListingPage.rawValue
        contact("presenter@example.invalid", on: approved, email: "presenter@example.invalid", provenance: .presenter)
        contact("zz-act@example.invalid", on: approved, email: "zz-act@example.invalid", provenance: .act) {
            $0.replied = true; $0.repliedAt = now.addingTimeInterval(-3600)
            $0.replyDraftRequestedAt = now.addingTimeInterval(-7200); $0.replyHandledAt = now.addingTimeInterval(-1800)
        }
        contact("press@example.invalid", on: approved, email: "press@example.invalid", provenance: .presenter) {
            $0.looksLikePressContact = true
        }
        let blocked = try show("ninefold|2026-10-10")
        blocked.statusRaw = ReviewStatus.drafted.rawValue
        blocked.draftBody = "Hello,\n\nI photograph performing arts in New York."
        blocked.conflictKey = BlockedCalendar.Day(date: "2026-10-10", kind: .dayOff, name: "Rest").key
        blocked.conflictOpen = true
        blocked.skippedRunNights = [NightDecision(night: "2026-10-11", at: now, origin: .chosen).stored]
        contact("blocked@example.invalid", on: blocked, email: "blocked@example.invalid", provenance: .act)
        let form = try show("copper|2026-10-17")
        contact("form-pitch", on: form, provenance: .act, form: "https://coppermoth.example/contact") {
            $0.formOutreachStartedAt = now.addingTimeInterval(-600)
        }
    }

    @Test func theCardAndItsMembersAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedCard(ctx, all)
        // Positive controls (L159): what the card says on each show built for it.
        func show(_ key: String) throws -> Prospect { try #require(all.first { $0.naturalKey == key }) }
        let approved = try show("lantern|2026-10-03")
        let groups = SendGroup.CardGroups(of: approved, today: asOf)
        #expect(groups.pending.map(\.id) == ["zz-act@example.invalid", "presenter@example.invalid"],
                "the approved show's send group is not the act then the presenter, with the press inbox held")
        let card = QueueItem(approved, sendGroups: groups)
        #expect(card.contacts.first { $0.id == "press@example.invalid" }?.isHeldFromSending == true)
        #expect(card.weakContactHoldReason == .venueOrPress, "the press inbox is not held as a venue or press address")
        #expect(card.contacts.first { $0.id == "zz-act@example.invalid" }?.replyIsAnswered == true)
        #expect(card.contacts.first { $0.id == "zz-act@example.invalid" }?.replyPostdatesDraftRequest == true)
        #expect(card.showSummaryAbsence == .noListingPage)
        #expect(card.greetingAudienceSize == 3, "the card's greeting audience is not the show's three pending addresses")
        let blocked = try show("ninefold|2026-10-10")
        #expect(blocked.draftIsMissingSubject, "a draft with no subject line is not missing one")
        #expect(blocked.conflictNote != nil, "an uncleared day off says nothing on the card")
        #expect(blocked.skippedNightDecisions.map(\.night) == ["2026-10-11"], "the skipped night is not read back")
        #expect(SendGroup.CardGroups(of: blocked, today: asOf).preview.isEmpty,
                "a contact on a show with no subject line and an uncleared day off is sendable")
        if case .awaitingConfirmation = FormPitch.state(of: try show("copper|2026-10-17")) {} else {
            Issue.record("the form Dan opened and has not confirmed is not awaiting confirmation")
        }

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))

        // A press guard lifted after the facts were taken: the groups, the card and the contact all see it.
        let stale = all.map(RowFacts.extract)
        try #require(approved.recipients.first { $0.id == "press@example.invalid" }).looksLikePressContactDismissed = true
        let staleFindings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        for prefix in ["SendGroup.Groups differ", "QueueItem differs", "the card's contact answers"] {
            #expect(staleFindings.contains { $0.hasPrefix(prefix) }, "a guard lifted after extraction was not seen by \(prefix)")
        }
        #expect(!staleFindings.contains { $0.contains("example") },
                "a finding named an address or a URL rather than an identifier")
    }

    // MARK: slice G1, the row and the reachability members it reads

    // One show for each of the five verdicts the contacts can derive (an open address, an address a guard
    // holds, a form on the act's own site, a social profile Dan confirmed, and only a name-match guess), and
    // one already pitched, which keeps its stored verdict whatever its contacts now say. Each show's stored
    // verdict is "no email found", so every unpitched one re-derives.
    private func seedRows(_ ctx: ModelContext, _ all: [Prospect]) throws {
        func contact(_ id: String, on key: String, email: String? = nil, form: String? = nil,
                     _ shape: (Recipient) -> Void = { _ in }) throws {
            let p = try #require(all.first { $0.naturalKey == key })
            p.reachabilityResult = .noEmailFound
            let r = Recipient(id: id, email: email, provenance: .act, contactFormURL: form)
            shape(r)
            ctx.insert(r)
            p.recipients.append(r)
        }
        try contact("open@example.invalid", on: "lantern|2026-10-03", email: "open@example.invalid")
        try contact("front-desk@example.invalid", on: "ninefold|2026-10-10", email: "front-desk@example.invalid") {
            $0.looksLikeVenue = true
        }
        try contact("form", on: "copper|2026-10-17", form: "https://coppermoth.example/contact")
        try contact("confirmed-profile", on: "drift live|2026-11-01", form: "https://instagram.com/driftwoodchoir") {
            $0.nameMatchOnly = true; $0.nameMatchOnlyDismissed = true
        }
        try contact("guessed-profile", on: "drift|2026-11-01", form: "https://instagram.com/driftwoodchoirs") {
            $0.nameMatchOnly = true
        }
        try contact("pitched@example.invalid", on: "saltmarsh a", email: "pitched@example.invalid") {
            $0.sendState = .sent; $0.sentAt = Date(timeIntervalSince1970: 1_790_000_000)
        }
        try #require(all.first { $0.naturalKey == "saltmarsh a" }).sentAt = Date(timeIntervalSince1970: 1_790_000_000)
    }

    @Test func theRowAndItsReachabilityAnswerTheSameOverFactsAsOverModels() throws {
        let ctx = try context()
        let all = try seed(ctx)
        try seedRows(ctx, all)
        // Positive controls (L159): every verdict the contacts can derive, each on the show built for it, and
        // the pitched show keeping its stored one.
        func show(_ key: String) throws -> Prospect { try #require(all.first { $0.naturalKey == key }) }
        #expect(try show("lantern|2026-10-03").reachabilityResultFromRecipients == .emailFound)
        #expect(try show("ninefold|2026-10-10").reachabilityResultFromRecipients == .weakContactOnly,
                "an address the venue guard holds is not a weak contact")
        #expect(try show("copper|2026-10-17").reachabilityResultFromRecipients == .contactFormOnly)
        #expect(try show("drift live|2026-11-01").reachabilityResultFromRecipients == .socialOnly,
                "a profile Dan confirmed is not a social route")
        #expect(try show("drift|2026-11-01").reachabilityResultFromRecipients == .noEmailFound,
                "a name-match guess counted as a route")
        let pitched = try show("saltmarsh a")
        #expect(pitched.reachabilityResultFromRecipients == .emailFound)
        #expect(pitched.reachabilityResultAsHeld == .noEmailFound, "a pitched show re-derived its stored verdict")
        #expect(try show("lantern|2026-10-03").reachabilityResultAsHeld == .emailFound,
                "an unpitched show kept its stored verdict rather than re-deriving it")
        let rows = all.map { QueueScopeRow($0, facts: RecipientFacts.of($0)) }
        #expect(Set(rows.compactMap(\.reachabilityResult)) == Set(Reachability.ProbeResult.allCases),
                "the rows do not carry every verdict")

        let findings = TermsOverFacts.findings(all, asOf: asOf)
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))

        // A guard lifted after the facts were taken: the contact, the row's facts and the row all see it.
        let stale = all.map(RowFacts.extract)
        try #require(all.flatMap(\.recipients).first { $0.id == "front-desk@example.invalid" }).looksLikeVenueDismissed = true
        let staleFindings = TermsOverFacts.findings(all, facts: stale, asOf: asOf)
        for prefix in ["RecipientFacts.of differs", "QueueScopeRow differs", "the row's reachability answers differ",
                       "the address members differ"] {
            #expect(staleFindings.contains { $0.hasPrefix(prefix) }, "a guard lifted after extraction was not seen by \(prefix)")
        }
        #expect(!staleFindings.contains { $0.contains("example") },
                "a finding named an address or a URL rather than an identifier")
    }
}
