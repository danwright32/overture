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
enum StallSurface: String, Codable, CaseIterable, Sendable {
    case queue
    case archive
    case followUps
    case sourcesSheet
    case replySheet
    case draftReview
    case organisations
    case settings
    // No window at all, which is the ordinary state of a menu bar app and NOT the same as not knowing.
    case noWindow
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
}

// The retention rule, which is the half #3435 names as its own defect.
//
// A cap by COUNT over a store where a 250ms blip and a 58 second freeze are one record each means cheap
// writers evict expensive observations (L191). The single reading this file exists to support is the
// MAXIMUM over a session, and that is exactly the record a count cap discards: an evening of ordinary
// small stalls flushes the one long entry out, and an eviction count tells you some were dropped but
// never that the largest was among them (L63).
enum StallLog {

    // Below this a stall is COUNTED and not stored as its own record.
    //
    // The source of the number, which #3435 requires be stated: it is one ping interval plus a margin.
    // `MainThreadWatchdog.pingInterval` is 0.25s, so a ping that runs late by less than that has been
    // delayed by no more than one missed turn of the run loop, which is ordinary scheduling on a busy
    // machine and not a freeze. Anything Dan could perceive is several times this: the shortest thing
    // this milestone has measured him waiting for is a 378 ms rebuild.
    static let floorSeconds: Double = 0.25

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
