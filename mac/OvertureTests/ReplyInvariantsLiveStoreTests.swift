import Testing
import Foundation
import SwiftData

// #2150. Three defects reached Dan on 2026-08-05 with a fully green suite: a row naming a contact who
// never wrote (#2122/#2125), a reply's words discarded and the answer addressed to the wrong person
// (#2147), and a panel claiming nothing was captured. Every one was a DATA-SHAPE surprise rather than a
// logic slip, and every fixture in the suite had the tidy version of that shape because it was invented.
//
// The specific miss: Dan pitched nbecker@everyvoicechoirs.org and Nicole answered from
// nicolebecker@everyvoicechoirs.org. No fixture had a reply from an address matching no contact, because
// nobody thought to write one. The live store had exactly that in it the whole time.
//
// So the reply and reached-out derivations are asked of the REAL rows. What this suite can do that the
// synthetic one cannot is notice a shape nobody thought to write; what it cannot do is cover a shape the
// store does not currently hold, which is why it is an addition to the invented fixtures and not a
// replacement for them.
//
// Reads a COPY, never the live file, and writes nothing anywhere (L2). Skips visibly on a machine with no
// store rather than passing silently.
@Suite("The real store's reply rows hold together (#2150)")
struct ReplyInvariantsLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // #1672: through the ONE shared clone. Copying the .store and its sidecars one file at a time
    // races a live writer, and a clone whose -wal does not match the .store beside it makes
    // whatever this suite concludes a statement about a torn copy rather than about Dan's data.
    // LiveStoreClone takes it through SQLite's online backup, which folds the WAL in as it goes,
    // so the newest writes are still there and there is no sidecar left to mismatch.
    private func copyLiveStore(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
    }

    private func withLiveShows(_ body: ([Prospect]) throws -> Void) async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("reply-invariants-\(UUID().uuidString)",
                                                                   isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            let url = try copyLiveStore(to: dir)
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
            let shows = try context.fetch(FetchDescriptor<Prospect>())
            // A store that reads as empty is a failed open, not a clean bill of health.
            #expect(!shows.isEmpty, "the copied store holds no shows, so nothing below measured anything")
            #expect(shows.contains { !$0.recipients.isEmpty },
                    "the copied store holds no contacts, so the derivations below ran over nothing")
            try body(shows)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // Every replied row, with what wrote it, so a failure names the row rather than a count.
    //
    // Honest about its own limit: when Dan has no unresolved replies this returns nothing and the four
    // tests below pass without measuring anything. That is not asserted against, because zero replies is
    // a legitimate state and a tripwire on it would cry wolf every time he finished a conversation. Green
    // here means "nothing in the store violates these rules", never "these rules were exercised".
    private func repliedRows(in shows: [Prospect]) -> [(Prospect, Recipient)] {
        shows.flatMap { p in p.recipients.filter(\.replied).map { (p, $0) } }
    }

    // #2985: the rows a reply is still OPEN on, which is a narrower set than `replied` and the only set
    // `ReplyIdentity.answering` makes any claim about. Its first guard returns the row itself once
    // `hasUnhandledReply` is false, because a handled reply has nothing left to answer.
    //
    // The writer-resolution invariant below used to run over every `replied` row. On 2026-08-19 Dan handled
    // a reply at 13:56 and the suite went red forty minutes later, asserting a resolution the code had
    // never promised for that state, and blocking every merge that touches the Mac app. A test that fails
    // when the workflow SUCCEEDS is the defect, not the handled reply: answering a reply is the outcome
    // this whole queue exists to produce.
    private func openReplyRows(in shows: [Prospect]) -> [(Prospect, Recipient)] {
        repliedRows(in: shows).filter { $0.1.hasUnhandledReply }
    }

    // #2122/#2125, as an invariant. The panel resolves a reply to the peer whose address matches the
    // recorded writer; the row the LIST stands on is picked by sorted id and is routinely somebody else.
    // The defect was that resolution silently landing on the wrong person. It cannot be caught by asking
    // "did it resolve", only by asking "did it resolve to the RIGHT one when a right one exists".
    //
    // LIVE-STORE-CLAIM verified=2026-08-19 measure="rows whose reply is still OPEN and whose recorded writer is held by some contact on the show, and whether the reply resolves to that contact. Re-measured 2026-08-19 after #2985 narrowed the scope from every replied row: 4 replied rows in the store, 0 of them still open, so this rule currently runs over nothing and the corpus test says so"
    // Measured 2026-08-05: 2 replied rows, both on the Pumpkin Singalong send group, both recording
    // nicolebecker@everyvoicechoirs.org, which no contact on that show held. Asserted as the rule rather
    // than as that shape, because the shape changes with every reply and the rule does not.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func aReplyResolvesToTheContactHoldingTheWritersAddressWheneverOneExists() async throws {
        try await withLiveShows { shows in
            var wrong: [String] = []
            // #2985: only the rows whose reply is still open. See `openReplyRows`.
            for (p, r) in openReplyRows(in: shows) {
                guard let writer = r.replyFromAddress, !writer.isEmpty else { continue }
                guard let holder = ReplyPanel.contact(holding: writer, of: p) else { continue }
                let answering = ReplyIdentity.answering(for: r, in: p)
                if answering.id != holder.id {
                    wrong.append("\(p.groupName): \(writer) is held by \(holder.id) "
                                 + "but the reply resolves to \(answering.id)")
                }
            }
            #expect(wrong.isEmpty, Comment(rawValue: "a reply resolved to somebody other than the person who wrote it:\n"
                    + wrong.prefix(5).joined(separator: "\n")))
        }
    }

    // Whatever it resolves to must EXIST on the show. A resolution pointing at a contact the prospect no
    // longer holds is a card about nobody, and it is the shape a merge or a removal can create between
    // the write and the read.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyReplyResolvesToAContactTheShowStillHolds() async throws {
        try await withLiveShows { shows in
            var dangling: [String] = []
            for (p, r) in repliedRows(in: shows) {
                let answering = ReplyIdentity.answering(for: r, in: p)
                if !p.recipients.contains(where: { $0.id == answering.id }) {
                    dangling.append("\(p.groupName): resolved to \(answering.id), which is not on the show")
                }
            }
            #expect(dangling.isEmpty, Comment(rawValue: dangling.prefix(5).joined(separator: "\n")))
        }
    }

    // #2147: the send must never quietly reach somebody who did not write. This is the whole safety net
    // asked of the real data: on every replied row, either the answer reaches the writer, or the panel
    // refuses AND says why. A refusal with nothing said is the #2152 defect, and a send that goes through
    // to the wrong person is the #2147 one, so both live here.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noRealRowCanSendAnAnswerThatMissesThePersonWhoWrote() async throws {
        try await withLiveShows { shows in
            var silent: [String] = []
            for (p, r) in repliedRows(in: shows) {
                let answering = ReplyIdentity.answering(for: r, in: p)
                let audience = SendGroup.replyAudience(of: answering)
                let refusal = ReplyPanel.refusal(body: "a typed reply", subject: nil, audience: audience,
                                                 gmailConnected: true,
                                                 writer: answering.replyFromAddress)
                guard let writer = answering.replyFromAddress, !writer.isEmpty else { continue }
                let reaches = audience.contains { ReplyDetection.isSameAddress($0, writer) }
                if reaches {
                    #expect(refusal == nil || refusal == .noAudience,
                            Comment(rawValue: "\(p.groupName): the answer reaches \(writer) but the panel still refuses"))
                    continue
                }
                // It does not reach them, so the send has to be refused AND the refusal has to be stated.
                if refusal == nil {
                    silent.append("\(p.groupName): would send to \(audience) without reaching \(writer)")
                } else if ReplyPanelCopy.refusalLine(refusal) == nil {
                    silent.append("\(p.groupName): refuses to answer \(writer) and says nothing about it")
                }
            }
            #expect(silent.isEmpty, Comment(rawValue: silent.prefix(5).joined(separator: "\n")))
        }
    }

    // #2149 and #2151, as one question about honesty: a row with no words on it must be able to say WHY,
    // and a writer on no contact must be offered for saving rather than left invisible. Both are surfaces
    // that used to render a bare placeholder over a real gap (L67).
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyGapOnARealRowHasSomethingTrueToSayAboutItself() async throws {
        try await withLiveShows { shows in
            var mute: [String] = []
            for (p, r) in repliedRows(in: shows) {
                let answering = ReplyIdentity.answering(for: r, in: p)
                if ReplyPanel.theirWords(answering) == nil,
                   ReplyPanel.missingWordsReason(answering) == nil {
                    mute.append("\(p.groupName): no words and no reason given for their absence")
                }
                // A writer nobody holds is exactly Dan's case, and it must be surfaced rather than silent.
                if let writer = answering.replyFromAddress, !writer.isEmpty,
                   ReplyPanel.contact(holding: writer, of: p) == nil,
                   ReplyPanel.unknownWriter(on: answering, of: p) == nil {
                    mute.append("\(p.groupName): \(writer) is on no contact and nothing says so")
                }
            }
            #expect(mute.isEmpty, Comment(rawValue: mute.prefix(5).joined(separator: "\n")))
        }
    }

    // The reached-out queue itself, over the real rows: every row it offers has SOME way to reach the
    // person, or it is a card about somebody who cannot be contacted at all.
    //
    // LIVE-STORE-CLAIM verified=2026-08-19 measure="reached-out rows with no email address, and whether each has a contact form to reach instead. Re-measured 2026-08-19: all 14 recipients ever sent to belong to shows carrying a showOutcome, so isInPlay excludes every one and there are 0 rows in play, which #2986 made a reported number rather than a failure"
    // Written first as "every row has an email address", which FAILED on three real rows: Perri Vale,
    // Battle of the Siblings, and Eva Noblezada & Alder Bourne. Measured rather than assumed: all three
    // are contact_method form_or_dm and all three carry a contactFormURL, so they are reachable and the
    // assumption was wrong, not the app. Email is one route of two here (#1585's reachability work), and
    // an invariant that forgets the other would have failed forever on working software.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyReachedOutRowHasSomeWayToReachThePerson() async throws {
        try await withLiveShows { shows in
            // #2986: the REAL clock, and NO tripwire on an empty selection.
            //
            // Two separate corrections. The clock was pinned to 2025-08-05 "so the run is reproducible",
            // which bought nothing: the other input is the LIVE store, so the run was never reproducible,
            // and pinning one end of a comparison whose other end keeps walking is L130. A bare `Date()`
            // is right here precisely BECAUSE the data is live, so both ends move together and the
            // question stays the same question every day.
            //
            // The `!rows.isEmpty` tripwire that used to sit here is gone, and that was the actual cause of
            // the red run. Measured 2026-08-19: all 14 recipients Dan has ever sent to belong to shows he
            // has since closed out, so `ReachedOutQueue.isInPlay` correctly excludes every one and the
            // selection is legitimately empty. Finishing your pitches is not a regression. It contradicted
            // this file's own stated design too (see `repliedRows`: "a tripwire on it would cry wolf every
            // time he finished a conversation").
            //
            // Emptiness is NOT thereby swept under the carpet, which would be L98: it is reported out loud,
            // every run, by `theSuiteReportsHowManyRowsEachInvariantCouldMeasure` below. That is the whole
            // point of separating the two: this test asks "is any live row unreachable", and that one asks
            // "how many rows was that asked of".
            let rows = ReachedOutQueue.activeWithDates(from: shows, now: Date())
            var unreachable: [String] = []
            for row in rows {
                let hasEmail = row.recipient.email?.isEmpty == false
                let hasForm = row.recipient.contactFormURL?.isEmpty == false
                if !hasEmail && !hasForm {
                    unreachable.append("\(row.prospect.groupName): a reached-out row with no email and no form")
                }
            }
            #expect(unreachable.isEmpty, Comment(rawValue: unreachable.prefix(5).joined(separator: "\n")))
        }
    }

    // #2985/#2986: how much this suite actually measured, reported every run.
    //
    // Both invariants above are now allowed to find NOTHING, because both of their corpora legitimately
    // empty when Dan finishes his work: closing out a show takes its contacts out of play, and answering a
    // reply closes the only state the writer-resolution rule speaks about. Neither emptiness is a
    // regression, and a tripwire on either fires on the workflow succeeding.
    //
    // But an invariant that examined zero rows and an invariant that examined every row must not look
    // alike (L98), and with the tripwires gone the only thing left to tell them apart is a number nobody
    // has. So this test IS that number. It prints the three corpus sizes on every run, so "these rules were
    // exercised" and "these rules had nothing to run over" are different lines of output rather than the
    // same silent green.
    //
    // It is deliberately a MEASUREMENT rather than a threshold. Any floor here would be the tripwire again
    // under a new name, and would fire on exactly the state this issue exists to stop failing on. What it
    // does assert is the containment that must hold whatever the sizes are, so it is not merely a print
    // statement: an open reply is a replied row, and a row in play was sent to. Those cannot go wrong
    // quietly.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theSuiteReportsHowManyRowsEachInvariantCouldMeasure() async throws {
        try await withLiveShows { shows in
            let replied = repliedRows(in: shows)
            let open = openReplyRows(in: shows)
            let inPlay = ReachedOutQueue.activeWithDates(from: shows, now: Date())
            print("LIVE STORE CORPUS: \(shows.count) shows, \(replied.count) replied rows, "
                  + "\(open.count) with a reply still open, \(inPlay.count) reached-out rows in play. "
                  + "A zero here means the invariants in this suite ran over nothing.")
            // An open reply is a replied row, by construction, so the narrower set can never be the larger.
            #expect(open.count <= replied.count)
            // A row in play was sent to: `ReachedOutQueue.isInPlay` refuses a recipient with no `sentAt`,
            // so a row here without one means that gate stopped holding.
            #expect(inPlay.allSatisfy { $0.recipient.sentAt != nil })
            // Every open reply is one of the replied rows, by identity and not merely by count, so a
            // filter that started selecting something else entirely cannot pass on the sizes alone.
            let repliedIds = Set(replied.map { "\($0.0.naturalKey)|\($0.1.id)" })
            #expect(open.allSatisfy { repliedIds.contains("\($0.0.naturalKey)|\($0.1.id)") })
        }
    }
}
