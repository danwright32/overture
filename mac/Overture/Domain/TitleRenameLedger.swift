import Foundation

// #4147: what a show's title WAS before the scout replaced it, and which arm of the upsert did it.
//
// WHY IT EXISTS. #4068 closed without ever answering its own question. Four dismissed rows had their
// titles replaced by unrelated shows, two mechanisms were unguarded in the window, and which one did it
// could not be established, because every instrument that could have answered had aged out by the time
// anybody looked: the launch backups rotate at 10 and reached back only to 2026-09-16, the frozen
// pre-move archive stops at 2026-07-23, and `NaturalKeyRemap` prunes at 7 days by design. The store
// holds the NEW title, `scoutGroupName` holds the new title, `groupNameOverriddenByDan` is 0, and
// nothing anywhere recorded that a title had changed at all.
//
// The harm class is #797: a stored row re-keyed onto a different show carries Dan's dismissal, his sent
// record and his thread id onto an act he never judged. It has happened at least twice, and every fix in
// this family makes a re-keying pass run MORE often, so the population that could be affected grows
// while the ability to audit it does not.
//
// WHY IT DOES NOT RIDE `NaturalKeyRemap`, which is the obvious place and the wrong one. That ledger
// records old-to-new KEY mappings so work in flight can still find its row, and every caller translates
// through it unconditionally. This fires on an ordinary re-ingest where NO key moved, which that one
// never sees, so its entries would have to be ignored by every existing reader, and its 7 day prune,
// chosen to bound how long a paid run can still be matched back, would have to be lengthened for a
// purpose it was not chosen for (L669). Two records with different lifetimes and no shared reader are
// two subjects, not one vocabulary split in half (L263).
//
// WHAT IT HOLDS, AND WHAT IT MUST NOT. Show titles, folded natural keys and an arm name: the same
// material the queue itself displays. No addresses, no message text, and no person beyond whatever a
// billing already puts in a title. It lives in the handoff directory, which is where the repo's privacy
// and cleanup rules already reach, and which `StoreLocation` redirects to a temp folder under test, so a
// test run can never write into Dan's live data (#2097, L2).
//
// RETENTION IS BUILT IN FROM THE FIRST COMMIT rather than waiting for a measurement of the weekly rate.
// That rate cannot be measured before the instrument exists, and the bound that matters is not the rate
// anyway: one run's renames are bounded above by the events it extracted, which was 357 on 2026-09-21.
// TWO rules, because either alone fails on a shape the other covers: anything older than `keepFor` goes
// whatever the count, and only the newest `maxEntries` survive whatever the age.
struct TitleRenameLedger: Codable, Equatable, Sendable {

    struct Entry: Codable, Equatable, Sendable {
        // The key the row holds AFTER the write, which is what a later query starts from.
        var key: String
        var from: String
        var to: String
        // Which arm of `ScoutService.upsertTarget` answered. A STRING rather than the enum, so a file
        // written by a build that knew an arm this one does not still decodes whole (L255).
        var arm: String
        var at: Date
    }

    var entries: [Entry] = []

    // Long enough that a fault noticed weeks later can still be traced, which is exactly what #4068
    // could not do. Its own constant, never `NaturalKeyRemap.keepFor`: that 7 days answers a different
    // question, and reusing it would silently lengthen the window for every one of its readers (L669).
    static let keepFor: TimeInterval = 180 * 24 * 60 * 60

    // And a ceiling, because age alone does not bound a file a burst can fill.
    static let maxEntries = 4000

    func pruned(now: Date) -> TitleRenameLedger {
        let fresh = entries.filter { now.timeIntervalSince($0.at) <= Self.keepFor }
        return TitleRenameLedger(entries: Array(fresh.suffix(Self.maxEntries)))
    }

    // MARK: - On disk

    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("title-renames.json")
    }

    // Nothing on disk is not an error and neither is an unreadable file: this is a diagnostic record, and
    // refusing to append because the existing file cannot be parsed would lose the NEW entries as well as
    // the old. The read is recorded by `HandoffFile` either way, so an unreadable ledger is visible
    // rather than silent (#2879, L11).
    static func read(from url: URL = defaultURL) -> TitleRenameLedger {
        HandoffFile.read(at: url) {
            try decoder().decode(TitleRenameLedger.self, from: $0)
        }.value ?? TitleRenameLedger()
    }

    // ISO 8601 dates and sorted keys, so the file a person opens reads as text rather than as a float,
    // and two runs that recorded the same entries produce the same bytes. The same pair `CardDivergence`
    // uses for the same reason.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // The write every caller makes, with the one catch they would otherwise each write themselves.
    //
    // A ledger write must never fail the work it is recording: the scout's rows and the merge's deletes
    // have already landed, and this is a diagnostic record beside them. It is LOGGED rather than
    // swallowed, because a ledger that quietly stopped being written is exactly the state #4068 was in
    // (L11, L98). One function rather than four `try?`s, so that reasoning lives in one place (L370).
    static func recordOrLog(_ renames: [Entry], now: Date, url: URL = defaultURL) {
        guard !renames.isEmpty else { return }
        do {
            try record(renames, now: now, url: url)
        } catch {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice
            AgentLog.problem("#4147 TitleRenameLedger: could not record \(renames.count) rename(s): \(error)")
            // copy-inventory:ignore-end
        }
    }

    @discardableResult
    static func record(_ renames: [Entry], now: Date, url: URL = defaultURL) throws -> TitleRenameLedger {
        guard !renames.isEmpty else { return read(from: url) }
        let combined = TitleRenameLedger(entries: read(from: url).entries + renames).pruned(now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder().encode(combined).write(to: url, options: .atomic)
        return combined
    }
}
