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
    static func newlyReported(in support: URL,
                              watchdogRan: Bool,
                              writesThatFailed: Int = 0,
                              defaults: UserDefaults = .standard,
                              read: (URL) -> FreezeLog.Read = FreezeLog.read(at:)) -> String? {
        let found = read(FreezeLog.url(in: support))

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
        // The set written back is the identities of every record the file STILL HOLDS, so it is bounded
        // by the file's own cap rather than growing forever, and a record compaction has dropped can
        // never be reported again anyway because it is not there to read.
        let alreadySaid = Set(defaults.stringArray(forKey: FreezeLog.reportedIdsKey) ?? [])

        // An install upgrading FROM the version keyed on the sequence carries a backlog nothing could
        // ever report, and it is reported, once, exactly like any other backlog a crash or an unread
        // session leaves behind. There is no special case for it and that is deliberate: the first build
        // that could speak saying NOTHING is indistinguishable from the defect that silenced it, which is
        // the state this whole change exists to end (L98). Dan's call, 2026-09-06, in this session,
        // reversing the suppression this shipped with.
        let fresh = found.records.filter { !alreadySaid.contains($0.identity) }
        defaults.set(found.records.map(\.identity), forKey: FreezeLog.reportedIdsKey)

        guard let worst = fresh.max(by: { $0.seconds < $1.seconds }) else { return nil }
        return FreezeNoticeCopy.report(count: fresh.count,
                                       longestSeconds: worst.seconds,
                                       surface: worst.surface,
                                       load: worst.load,
                                       unreadableLines: found.unreadableLines)
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
                       load: MachineLoad, unreadableLines: Int) -> String {
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
        return sentence
    }

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
