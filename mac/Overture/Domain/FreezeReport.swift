import Foundation

// #3435 Phase 2e: THE READER, built in the same change as the detector.
//
// A detector that reports to nobody is the brief unmet, and a field only ever written looks alive to
// every is-this-used check while the purpose it was added for silently never happens (L46). This is the
// cheapest reader consistent with this repository: `RunBoundaryViolations`'s precedent, which counts what
// is in a file, says its sentence ONCE per new record, and remembers what it has said in defaults so a
// crash does not lose the fact.
//
// #3439 is the SECOND reader, and it needs something else: the longest stall over a real working session,
// asked for rather than waited for. `FreezeReport.floor(in:)` is that, and it reads the same file.
enum FreezeReport {

    // What Dan is told, or nil when there is nothing new to tell him.
    //
    // FOUR STATES, and each has its own wording, because two outcomes a guard gives distinct messages but
    // the same consequence are one outcome in practice, and two that share a message are worse (L11, L260):
    //
    //   1. nothing new to say                    nil, and nothing is drawn
    //   2. N freezes, the longest M seconds      the ordinary report
    //   3. the watchdog did not run at all       said plainly, because a session with no detector and a
    //                                            session with no freezes look identical from silence
    //   4. some of them named no surface         said as part of the report rather than hidden
    //
    // State 3 is the one this whole design turns on. The file being absent means EITHER that nothing froze
    // OR that nothing was watching, and those are the two most different answers available (L98).
    //
    // #4453: CALLED OFF THE MAIN ACTOR, through `FreezeLogHousekeeper`, and it reads only what is new. See
    // `FreezeLog.ArchiveAnchor` for why reading the archive from its end is correct, and `Said` below for
    // what is remembered instead of every identity ever considered.
    static func newlyReported(in support: URL,
                              watchdogRan: Bool,
                              writesThatFailed: Int = 0,
                              defaults: UserDefaults = .standard,
                              sources: Sources = .files) -> String? {
        // A record the app could not WRITE is the one state worse than a freeze, because it means the
        // file is not the evidence anybody thinks it is. Said first and on its own: folding it into a
        // count would make an unwritable file read as a quiet session (L11, L13).
        if writesThatFailed > 0 { return FreezeNoticeCopy.writesFailed(writesThatFailed) }

        guard watchdogRan else {
            // Said once per session, and never alongside a count: a count taken with no watchdog is a
            // claim about a file rather than about this session.
            return FreezeNoticeCopy.watchdogDidNotRun
        }

        // WHAT HAS ALREADY BEEN SAID, by the record's whole identity. See `FreezeLog.reportedIdsKey`: the
        // sequence alone is not one, and keying on it made the notice go permanently silent after the
        // first session.
        //
        // #4453 REPLACED what this paragraph used to say, that "the set written back is the identities of
        // every record CONSIDERED, so it is bounded by the live file's cap plus the archive's own 31 day
        // retention". Bounded was true and was not cheap: on 2026-10-02 that set was 29,527 identities, a
        // 1,749,034 byte preferences file rewritten on every call, beside a 9.2 MB archive decoded on the
        // main thread to rebuild it. What is remembered now is `Said`: the live file's identities, which
        // the live file's cap bounds, and where the archive ended.
        //
        // #3851 OVERTURNED THE DECISION THIS COMMENT USED TO RECORD, and the old reasoning is kept here
        // rather than deleted, because it was right for the world it was written in (L61, L249, #3077).
        // It said this reader "deliberately ignores" the archive, "because the launch notice wants the
        // last session's shape while the archive exists for the population". That held while a session
        // could not fill the live file on its own: the records a compaction moved out had been reported at
        // an earlier launch, so ignoring them lost nothing.
        //
        // #3812 ended it. Before that, a session stopped writing at its 200th stall, so 500 records spanned
        // several sessions. Writing every stall means ONE heavy session can write past the cap, and its own
        // records are compacted into the archive before any launch has read them. They were then lost to
        // this notice permanently, and the loss was worst in exactly the sessions that froze most (L216).
        //
        // Measured on Dan's own files 2026-09-12: 700 records live against a cap of 500, and 780 already
        // archived, every one of them invisible here.
        //
        // What the old decision got RIGHT is kept: this is still a notice about what has not been SAID,
        // never about the whole history, and `scripts/what-froze-the-queue.sh` is still the reader for the
        // population. The only change is that having been archived no longer counts as having been said.
        let before = said(in: defaults)
        let alreadySaid = Set(before.liveIdentities)

        // An install upgrading FROM the version keyed on the sequence carries a backlog nothing could
        // ever report, and it is reported, once, exactly like any other backlog a crash or an unread
        // session leaves behind. There is no special case for it and that is deliberate: the first build
        // that could speak saying NOTHING is indistinguishable from the defect that silenced it, which is
        // the state this whole change exists to end (L98). Dan's call, 2026-09-06, in this session,
        // reversing the suppression this shipped with.
        // #3851: the archive FIRST, so the combined list is roughly chronological, on the same reasoning
        // `scripts/what-froze-the-queue.sh` already uses: a compaction only ever moves records OLDER than
        // everything the live file kept. An absent archive is the ordinary state, because most installs
        // have never compacted, and `FreezeLog.read` reports that as `fileWasAbsent` with no records.
        //
        // #4453: the archive is read only from where it ended last time. Everything it gained since was
        // compacted out of the live file, so a record that was in the live file at the last report is in
        // `alreadySaid` and one that arrived and was compacted before this report is not, which is the
        // #3851 case exactly. The ARCHIVE is read before the live file, so a compaction landing between
        // the two reads can only show a record in both, never in neither.
        let liveURL = FreezeLog.url(in: support)
        let archived = sources.archive(FreezeLog.archiveURL(besideLogAt: liveURL), before.archiveAnchors)
        let found = sources.live(liveURL)

        // ONE freeze is one record however many files hold it. A compaction whose live rewrite failed
        // leaves a record in both files (#3763), and counting it twice would report a freeze that did not
        // happen (L427).
        var counted = Set<String>()
        let fresh = (archived.records + found.records).filter {
            !alreadySaid.contains($0.identity) && counted.insert($0.identity).inserted
        }

        // A FILE THAT COULD NOT BE READ KEEPS ITS PART OF WHAT WAS SAID, so nothing it holds is lost or
        // repeated when it can be read again. An unreadable live file keeps the identities it had. An
        // unreadable archive keeps its position, and keeps every identity already said as well, because
        // the records a compaction moves out of the live file meanwhile land past that position and are
        // judged against this list when the archive is read again (L105, L211).
        var after = before
        if !found.couldNotBeRead {
            after.liveIdentities = found.records.map(\.identity)
        }
        if archived.couldNotBeRead {
            var kept = Set(before.liveIdentities)
            let carried = before.liveIdentities + after.liveIdentities.filter { kept.insert($0).inserted }
            // BOUNDED, so an archive that stays unopenable cannot regrow the list #4453 removed. The
            // newest are kept, and what falls off the front can only be said AGAIN once the archive
            // opens, never lost. Not while migrating: the old list is the only account of a month of
            // notices, and cutting it would repeat that month at once (L36).
            let migrating = defaults.object(forKey: FreezeLog.reportedIdsKey) != nil
            after.liveIdentities = migrating ? carried : Array(carried.suffix(carriedIdentityCeiling))
        } else {
            after.archiveAnchors = archived.anchors
        }

        let somethingUnread = found.couldNotBeRead || archived.couldNotBeRead
        let message: String?
        if let worst = fresh.max(by: { $0.seconds < $1.seconds }) {
            message = FreezeNoticeCopy.report(count: fresh.count,
                                              longestSeconds: worst.seconds,
                                              surface: worst.surface,
                                              load: worst.load,
                                              // Both files' unreadable lines, because a line this reader
                                              // could not decode is the same fact whichever file held it.
                                              // The archive's are those in what it gained since last
                                              // time, which is the only part read.
                                              unreadableLines: found.unreadableLines + archived.unreadableLines,
                                              earlierRecordsUnopened: somethingUnread)
        } else if somethingUnread, !before.unopenedSaid {
            // Said on its own ONCE while it lasts, never hourly: a file that cannot be opened is a reason
            // the silence below could be wrong, and silence is what a clean session looks like (L98), but
            // the same sentence every hour is what teaches somebody to stop reading the slot (L36).
            message = FreezeNoticeCopy.recordsUnopened
        } else {
            message = nil
        }
        after.unopenedSaid = somethingUnread && (message != nil || before.unopenedSaid)

        remember(after, replacing: before, in: defaults)
        return message
    }

    // #4453: where the report reads from, as ONE value, so a test hands it both files at once and can
    // never hand it one and leave the other to reach the disk (L2).
    struct Sources {
        var live: (URL) -> FreezeLog.Read
        var archive: (URL, [FreezeLog.ArchiveAnchor]) -> FreezeLog.ArchiveTail

        static var files: Sources {
            Sources(live: FreezeLog.read(at:),
                    archive: { FreezeLog.readArchiveTail(at: $0, after: $1) })
        }
    }

    // #4453: what has been said, as ONE stored value rather than several keys beside each other, so a
    // half written state cannot pair one file's position with another moment's identities (L544).
    //
    //   liveIdentities   the identities the LIVE file held at the last report. Bounded by the live
    //                    file's cap, because records only ever arrive there.
    //   archiveAnchors   the archive's last records at the last report, newest first, which is where
    //                    the next read of it stops. Empty means read all of it.
    //   unopenedSaid     a file that could not be opened has already been said on its own, so the
    //                    sentence is not repeated while it lasts.
    struct Said: Codable, Equatable, Sendable {
        var liveIdentities: [String] = []
        var archiveAnchors: [FreezeLog.ArchiveAnchor] = []
        var unopenedSaid: Bool = false
    }

    static let saidKey = "freezesSaid"

    // How many identities are carried while the archive cannot be opened: four live files' worth.
    static let carriedIdentityCeiling = FreezeLog.fileCap * 4

    // What has been said, read from wherever it is.
    //
    // THE MIGRATION from `FreezeLog.reportedIdsKey`, which held every identity ever considered. It is
    // read as `liveIdentities` with no archive position, so the first report on this build reads both
    // files whole ONCE, off the main actor, and judges every record against that list exactly as the
    // previous build did: nothing it said is said again, and anything it never reached is said now (L98).
    // The old key is then removed, which is what shrinks the preferences file, and from then on only
    // what is new is read.
    //
    // The old key WINS when both are present. Only this build removes it, so its presence means an older
    // build ran since this one last wrote, and its list is the newer account of what was said.
    static func said(in defaults: UserDefaults) -> Said {
        if let legacy = defaults.stringArray(forKey: FreezeLog.reportedIdsKey) {
            return Said(liveIdentities: legacy)
        }
        guard let data = defaults.data(forKey: saidKey),
              let stored = try? FreezeLog.decoder().decode(Said.self, from: data) else {
            // Nothing stored, or nothing this build can read: read everything and say what has not been
            // said, which is the backlog rule rather than a silence (L98).
            return Said()
        }
        return stored
    }

    // Written only when it CHANGED, so an hourly tick with nothing new writes nothing.
    private static func remember(_ after: Said, replacing before: Said, in defaults: UserDefaults) {
        let migrating = defaults.object(forKey: FreezeLog.reportedIdsKey) != nil
        let storedIsCurrent = defaults.data(forKey: saidKey) != nil
        guard after != before || migrating || !storedIsCurrent else { return }
        guard let data = try? FreezeLog.encoder().encode(after) else { return }
        defaults.set(data, forKey: saidKey)
        // Only once the new state is written, so a failed encode leaves the old list rather than nothing.
        if migrating { defaults.removeObject(forKey: FreezeLog.reportedIdsKey) }
    }

    // #3439's reader: the longest stall this file holds, asked for rather than found by opening a file.
    //
    // Returns nil when there is nothing to answer with, which the CALLER has to tell apart from a session
    // with no freezes; `newlyReported` above is where that distinction is made in words.
    static func floor(in support: URL, read: (URL) -> FreezeLog.Read = FreezeLog.read(at:)) -> StallRecord? {
        read(FreezeLog.url(in: support)).records.max(by: { $0.seconds < $1.seconds })
    }
}

// The sentences, in one place, so `docs/copy-inventory.md` carries them and the cold read has something to
// read (#915, #843).
enum FreezeNoticeCopy {

    static let watchdogDidNotRun =
        "Overture could not check whether it stopped responding this session, so nothing here can say whether it did."

    // COLD READ, 2026-09-06, each branch rendered and read in the order a person meets it (#843).
    //
    // ONE freeze and SEVERAL are different sentences rather than one with a count in it. Written the
    // obvious way, a single freeze read "Overture stopped responding once since it last said so. The
    // longest was 1.2 seconds", and both halves are wrong on first sight: "since it last said so" is a
    // reference to a time nothing ever said anything, and "the longest" of one thing is a superlative
    // over a set of one. Neither is untrue; both make the reader stop and work out what is meant, which
    // is what a cold read is for.
    //
    // THE SURFACE IS ITS OWN SENTENCE rather than a trailing clause, and that was the copy inventory's
    // finding rather than mine: a helper call glued to the preceding word produces a CLAUSE, so what
    // lands in `docs/copy-inventory.md` is a line of Swift and the cold read the file exists for cannot
    // be done on it (#2570, #2548). Reading the two forms side by side, the sentences are better anyway.
    static func report(count: Int, longestSeconds: Double, surface: StallSurface,
                       load: MachineLoad, unreadableLines: Int,
                       earlierRecordsUnopened: Bool = false) -> String {
        let seconds = String(format: "%.1f", longestSeconds)
        var sentence: String
        if count == 1 {
            sentence = "Overture stopped responding for \(seconds) seconds."
        } else {
            sentence = "Overture stopped responding \(count) times. The longest was \(seconds) seconds."
        }
        sentence += " "
        sentence += surfaceSentence(surface)
        sentence += loadClause(load)
        if unreadableLines > 0 {
            sentence += " "
            sentence += unreadableSentence(unreadableLines)
        }
        if earlierRecordsUnopened {
            sentence += " "
            sentence += partUnopened
        }
        return sentence
    }

    // #4453: a file of these records exists and could not be OPENED, which is a different fact from a
    // line in it that could not be decoded, and said differently (L11). Until #4453 it read as no file at
    // all, so whatever it held was silently never said.
    //
    // COLD READ, 2026-10-02. Two sentences rather than one, because they land in different places: the
    // first follows a count and so may lean on it, the second stands alone in the slot and must say what
    // it cannot know, in the words `watchdogDidNotRun` already uses for the same kind of gap.
    static let partUnopened =
        "Part of Overture's record of when it stopped responding could not be opened, so there may have been more."

    static let recordsUnopened =
        "Overture could not open its record of when it stopped responding, so nothing here can say whether it did."

    static func writesFailed(_ count: Int) -> String {
        if count == 1 {
            return "Overture stopped responding at least once and could not write the record of it, so nothing here can say how long for."
        }
        return "Overture stopped responding \(count) times and could not write the records of them, so nothing here can say how long for."
    }

    static func unreadableSentence(_ lines: Int) -> String {
        if lines == 1 {
            return "1 earlier record could not be read, which is what force quitting Overture while it is frozen leaves behind."
        }
        return "\(lines) earlier records could not be read, which is what force quitting Overture while it is frozen leaves behind."
    }

    // The SURFACE, in the words a person uses for it rather than the case name. `notRecorded` gets its own
    // sentence, because a freeze whose surface is unknown and one that happened with no window open are
    // different things and the second is ordinary for a menu bar app (L11).
    static func surfaceSentence(_ surface: StallSurface) -> String {
        switch surface {
        case .queue: return "The queue was on screen."
        case .archive: return "The archive was on screen."
        case .followUps: return "Follow ups was on screen."
        case .sourcesSheet: return "The sources sheet was on screen."
        case .organisations: return "The organisations list was on screen."
        case .settings: return "Settings was on screen."
        // #3859: the seven sheets that used to be recorded as the queue. Each names the sheet in the
        // words its own heading uses, so the sentence names something Dan can point at rather than a
        // case name (L399).
        case .patterns: return "The what converts report was on screen."
        case .struckAddresses: return "The list of addresses you removed was on screen."
        case .daysOff: return "The days off sheet was on screen."
        case .excludedTowns: return "The skipped towns sheet was on screen."
        case .voiceGuidance: return "The voice guidance sheet was on screen."
        case .inquiryIntake: return "The inquiry form was on screen."
        case .prepSelection: return "The picker for which kept shows to prep was on screen."
        case .notRecorded: return "Nothing recorded which screen was open."
        }
    }

    // #3442: the load, said only when it changes what the reading means. A BASELINE stall is the one worth
    // acting on, so it says nothing extra; the other two carry their caveat, because work done to fix a
    // freeze that was really a loaded machine can never be shown to have worked.
    static func loadClause(_ load: MachineLoad) -> String {
        switch load {
        case .baseline: return ""
        case .elevated:
            return " This Mac was busy with something else at the time, so it may say more about the machine than about Overture."
        case .unmeasured:
            return " How busy this Mac was at the time could not be read, so a busy Mac cannot be ruled out as the cause."
        }
    }
}
