import Foundation

// #3435 Phase 2e, with #3442: the app's record of its own freezes.
//
// Until this the only detector was Dan noticing. Everything else this milestone has built measures a
// SWEEP or a PASS in a test; none of it can see the app stop answering on his Mac, which is the thing he
// reported and the thing #3439 has to read a floor from.
//
// This file is the whole of it that is PURE: what a stall record holds, what is kept when there are too
// many of them, and what Dan is told. The watchdog that takes the measurement is `MainThreadWatchdog`,
// and it is deliberately a thin wrapper over these decisions, because a rule inside a timer callback is a
// rule no test can reach (#885).

// WHAT SURFACE WAS ON SCREEN, as a closed enum with NO associated values.
//
// That is #3435's own remedy for its own defect and it is structural rather than a rule in prose (L27,
// L230). A surface name as a free `String` would be written by whoever adds the next sheet, and the
// natural spelling of "the surface on screen" here is the sheet plus the row that raised it, which
// carries a `groupName`. That string would pass every type guard cleanly and land in a durable file, and
// a scrub of the repository cannot see into a file the app writes on Dan's Mac (L222).
//
// So a case that could carry a show's name is impossible to write rather than forbidden. `PrivacyOfTheFreezeLogTests`
// asserts the enum has no payload and that the record type takes no `Prospect`, `Recipient` or `QueueItem`.
//
// EVERY CASE HAS A WRITER, and `TheWatchdogStandsDownTests` checks that against the code that writes
// them rather than a list here. Four did not when this shipped, and one of them mattered: with nothing
// able to record "no window open", a freeze in that state reported the QUEUE, which is wrong rather than
// merely incomplete (L90). Three were deleted and `settings` was wired. There is deliberately no case for
// a windowless app any more, because the watchdog now stands down when the window goes away, so a stall
// there cannot be recorded and a case for it would read zero forever.
enum StallSurface: String, Codable, CaseIterable, Sendable {
    case queue
    case archive
    case followUps
    case sourcesSheet
    case organisations
    case settings
    // #3435: the fourth state, and it has its own wording wherever it is reported. The surface is stamped
    // by the MAIN thread and read by the watchdog, so a stall recorded before anything ever stamped it,
    // or by a build where the stamping was removed, has no surface rather than a wrong one (L11, L98).
    case notRecorded
}

// #3442: what else this Mac was doing when the stall happened.
//
// The issue's own proposal, the presence of `run-tests-locked.sh`'s lock, was MEASURED and rejected on
// 2026-09-01: with no suite running and therefore no lock held, Lightroom sat at 349.5%, Synology's
// daemon at 99.4% and Backblaze's at 84.0%, and the lock would have reported "not loaded" throughout.
//
// Three values, never two, and `unmeasured` is never folded into `baseline`: a reading that could not be
// taken and a quiet machine call for opposite next steps, and the emptiest possible failure must not read
// as the cleanest possible pass (L98, L11).
enum MachineLoad: String, Codable, Sendable {
    case baseline
    case elevated
    case unmeasured
}

// One stall, as it is written to the file.
//
// WHOSE DATA IT TOUCHES, enforced rather than promised: a duration, an instant, a surface CASE, a load
// class and a load figure. Never a prospect name, a venue, an address, a subject or a draft body. There
// is no field here that could carry one and no initialiser that takes a model.
struct StallRecord: Codable, Equatable, Sendable {
    // The process this was recorded in, so a retry or a crash mid-write cannot double count: a record is
    // identified by its session and its sequence, and both are assigned by the watchdog.
    let session: String
    let sequence: Int
    let at: Date
    let seconds: Double
    let surface: StallSurface
    let load: MachineLoad
    // #3442: the one minute load average as a NUMBER beside the class, so a later reader can re-judge the
    // threshold without the classification being the only thing recorded. A record that says only
    // "elevated" cannot be re-examined against a different line, which is the shape #3464 had to go back
    // and fix for the freeze tool's own threshold (L316, L107).
    let loadAverage: Double?
    // #3760: how many render passes the main thread ran while this stall lasted.
    //
    // THREE VALUES, and `nil` is never folded into `0`. `nil` is UNMEASURED: no pass has ever been
    // counted in this process, so this record cannot say. `0` means the surface did not rebuild during
    // the freeze, which is the reading that REFUTES "a burst of store changes did this" and sends the
    // work somewhere else. `N` is the count. A zero standing for both would make the refutation
    // indistinguishable from the instrument being absent (L98, L11).
    //
    // OPTIONAL also because the log on Dan's Mac holds hundreds of records written before this shipped,
    // and those are the "before" half of milestone 80's own reading. They decode with this absent.
    let passes: Int?

    // The whole identity, as one string, because a reader that remembers what it has said has to remember
    // BOTH halves: the sequence restarts at 1 in every process, so it is not an identity on its own.
    var identity: String { "\(session)#\(sequence)" }
}

// The retention rule, which is the half #3435 names as its own defect.
//
// A cap by COUNT over a store where a 250ms blip and a 58 second freeze are one record each means cheap
// writers evict expensive observations (L191). The single reading this file exists to support is the
// MAXIMUM over a session, and that is exactly the record a count cap discards: an evening of ordinary
// small stalls flushes the one long entry out, and an eviction count tells you some were dropped but
// never that the largest was among them (L63).
enum StallLog {

    // #3760: how many render passes happened between two readings of the pass counter.
    //
    // PURE and here rather than inside the watchdog, so all four outcomes can be PRODUCED by a test
    // rather than reasoned about (L151). Every one is reachable in the running app.
    //
    // The counter has one writer (the main thread) and only ever increases, so a reading that went
    // BACKWARDS is a fault in the instrument rather than a stall that un-rendered itself, and it is
    // reported as unmeasured rather than as a negative number of passes (L11).
    static func passesSpanned(from before: Int?, to after: Int?) -> Int? {
        guard let after else { return nil }
        let start = before ?? 0
        guard after >= start else { return nil }
        return after - start
    }

    // How often the watchdog pings, and therefore what it can see.
    //
    // #3752: 0.1s, DOWN FROM 0.25s, so that a stall over 100 ms is a record with its real duration.
    //
    // WHY IT MOVED. Milestone 80's bar is "no baseline-load main-thread stall over 100 ms, measured by
    // the in-app watchdog". At 0.25s the watchdog could not see a 100 ms stall AT ALL: the floor was two
    // and a half times the bar, so an empty log would have read as the bar being met when it meant only
    // that nothing crossed 250 ms. That is the emptiest possible failure reading as the cleanest possible
    // pass, inside the milestone's own success criterion (L98). Measured on Dan's real log 2026-09-10:
    // 504 records, smallest 0.251s, so 100% of them exceeded the bar by construction and the entire
    // sub-250ms population was invisible.
    //
    // WHAT IT COSTS, measured rather than argued: `WatchdogCostTests` had one ping at 0.0058 ms of the
    // main thread, which was 0.0023% of a 250ms interval and is 0.0058% of a 100ms one. The guard's
    // ceiling is 1%, so this is still two orders of magnitude inside it, and the guard scales with the
    // interval so it would say if that stopped being true.
    //
    // A ping in flight is still never doubled (#3635), so a freeze longer than the interval queues one
    // ping rather than one per interval, and shortening the interval does not multiply the records a
    // single freeze writes.
    static let pingIntervalSeconds: TimeInterval = 0.1

    // Below this a stall is COUNTED and not stored as its own record.
    //
    // DERIVED from the interval rather than restated as a number, which is #3752's other half. It was
    // `0.25` written out, with a comment saying "`MainThreadWatchdog.pingInterval` is 0.25s", so the two
    // were one fact in two places and changing the interval would have silently left the floor behind
    // (L41, L70). The reason is unchanged: a ping late by less than one interval has been delayed by no
    // more than one missed turn of the run loop, which is ordinary scheduling on a busy machine and not
    // a freeze.
    static var floorSeconds: Double { pingIntervalSeconds }

    // How many individual records the file keeps.
    //
    // Small on purpose. The detail log is for reading a session's shape; the number that DECIDES anything
    // is the high-water entry below, which is never evicted.
    static let cap = 200

    // What survives one write. PURE, so the eviction rule can be exercised rather than watched not to
    // happen, and so the caller only ever writes what this returns.
    //
    // The HIGH WATER entry is held separately and is never evicted, which is the whole remedy: #3439 is
    // the gate that decides whether the deferred architecture escalation is triggered, and the quantity
    // it reads is the worst stall of a session. Judging that through a bounded recent list is judging the
    // quantity a guard protects by a proxy for it (L63).
    struct Kept: Equatable, Sendable {
        var records: [StallRecord]
        var highWater: StallRecord?
        var evicted: Int
        // Stalls below the floor, counted rather than stored. Reported, so a session of constant small
        // delays is visible as one number instead of being invisible.
        var belowFloor: Int
    }

    static func adding(_ stall: StallRecord, to kept: Kept,
                       floor: Double = floorSeconds, cap: Int = cap) -> Kept {
        var next = kept
        // The HIGH WATER is judged BEFORE the floor, deliberately. A session whose worst stall is under
        // the floor still has a worst stall, and reporting none would say a session was clean when what
        // happened is that nothing crossed a threshold (L98).
        if let current = next.highWater {
            if stall.seconds > current.seconds { next.highWater = stall }
        } else {
            next.highWater = stall
        }
        guard stall.seconds >= floor else {
            next.belowFloor += 1
            return next
        }
        next.records.append(stall)
        if next.records.count > cap {
            let dropped = next.records.count - cap
            next.records.removeFirst(dropped)
            next.evicted += dropped
        }
        return next
    }
}
