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

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Overture.store")
        // The sidecars too, or the copy is a snapshot missing the newest writes: on 2026-08-05 the reply
        // that mattered was in the WAL and not yet in the main file.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
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

    // #2122/#2125, as an invariant. The panel resolves a reply to the peer whose address matches the
    // recorded writer; the row the LIST stands on is picked by sorted id and is routinely somebody else.
    // The defect was that resolution silently landing on the wrong person. It cannot be caught by asking
    // "did it resolve", only by asking "did it resolve to the RIGHT one when a right one exists".
    //
    // LIVE-STORE-CLAIM verified=2026-08-05 measure="replied rows whose recorded writer is held by some contact on the show, and whether the reply resolves to that contact"
    // Measured 2026-08-05: 2 replied rows, both on the Pumpkin Singalong send group, both recording
    // nicolebecker@everyvoicechoirs.org, which no contact on that show held. Asserted as the rule rather
    // than as that shape, because the shape changes with every reply and the rule does not.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func aReplyResolvesToTheContactHoldingTheWritersAddressWheneverOneExists() async throws {
        try await withLiveShows { shows in
            var wrong: [String] = []
            for (p, r) in repliedRows(in: shows) {
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
                let refusal = ReplyPanel.refusal(body: "a typed reply", audience: audience,
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
    // LIVE-STORE-CLAIM verified=2026-08-05 measure="reached-out rows with no email address, and whether each has a contact form to reach instead"
    // Written first as "every row has an email address", which FAILED on three real rows: Alex Syiek,
    // Battle of the Siblings, and Eva Noblezada & Reeve Carney. Measured rather than assumed: all three
    // are contact_method form_or_dm and all three carry a contactFormURL, so they are reachable and the
    // assumption was wrong, not the app. Email is one route of two here (#1585's reachability work), and
    // an invariant that forgets the other would have failed forever on working software.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyReachedOutRowHasSomeWayToReachThePerson() async throws {
        try await withLiveShows { shows in
            let now = Date(timeIntervalSince1970: 1_754_400_000)   // pinned, so the run is reproducible
            let rows = ReachedOutQueue.activeWithDates(from: shows, now: now)
            #expect(!rows.isEmpty, "no reached-out rows at all, so this measured nothing")
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
}
