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
    // #3859: the seven sheets that used to have no case, so a stall while any of them was on screen was
    // recorded as `queue`.
    //
    // WHY THEY ARE SEVEN CASES AND NOT ONE `otherSheet`. The point of the field is that a reading of the
    // distribution can say which surface the time went to, and a shared case reproduces the same mixed
    // population one level down: the next person reading it would have to ask which sheet `otherSheet`
    // meant and have nothing to answer with (L11, L216). `patterns` in particular is not a cheap panel:
    // until #3871 it held four live whole-table prospect queries at once counting the queue's.
    //
    // THE PREVIOUS BEHAVIOUR WAS DELIBERATE and is being overturned with a reason, not by oversight.
    // `presentedSurface`'s header argued that an unknown sheet leaves the answer as whatever is
    // underneath it, "a true statement about a real surface rather than a wrong one". That was defensible
    // while the field was read one record at a time. It stopped being defensible when milestone #80 began
    // reading the DISTRIBUTION: a `queue` count that is the queue OR any of seven sheets over it is two
    // populations in one number and no reading taken from it can say which (L542, L216).
    case patterns
    case struckAddresses
    case daysOff
    case excludedTowns
    case voiceGuidance
    case inquiryIntake
    case prepSelection
    // #3435: the fourth state, and it has its own wording wherever it is reported. The surface is stamped
    // by the MAIN thread and read by the watchdog, so a stall recorded before anything ever stamped it,
    // or by a build where the stamping was removed, has no surface rather than a wrong one (L11, L98).
    case notRecorded

    // #3859: how many surfaces the build that wrote a record could name.
    //
    // This is what keeps the 1,562 `queue` records already on Dan's Mac READABLE rather than silently
    // re-defined. Adding the seven cases changes what `queue` counts, so a record written before this
    // shipped and one written after are not the same measurement, and nothing on the record said which
    // (L683). A reader can now tell them apart: `nil` is a record from a build that could name six
    // surfaces plus `notRecorded`, so its `queue` is the mixed population; a number is the size of the
    // vocabulary that record's writer had.
    //
    // DERIVED from `allCases` rather than written down, so it cannot fall behind the enum it describes
    // (L41). It is a COUNT rather than a version number for the same reason: a version is a second thing
    // to remember to bump, and the count answers the only question a reader has.
    static var vocabularySize: Int { allCases.count }
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
// #3788: whether any window was open when the stall happened.
//
// THREE VALUES. `unknown` is not "no": it is what a record written before this field shipped says, and what a
// build that never stamped says, and folding it into either answer would make "nobody was looking" and
// "nothing was recording whether anybody was looking" one claim (L98, L11).
enum WindowPresence: String, Codable, Equatable, Sendable {
    case open
    case none
    case unknown

    // Derived from the window COUNT rather than from `scenePhase`. `RootView` stands the watchdog down on
    // `.background`, whose own comment says that for this scene "the window is gone", and measured
    // 2026-09-11 that is not true of this app: with zero windows on screen the watchdog had been running for
    // two hours. Overture is resident in the menu bar, so the scene outlives the window.
    //
    // A NEGATIVE count is not a count and cannot come from AppKit. It reads as `.unknown` rather than being
    // folded into `.none`, because a value the system never produces reaching a real answer would be this
    // field inventing a measurement (L11).
    static func from(visibleWindowCount count: Int) -> WindowPresence {
        if count < 0 { return .unknown }
        return count == 0 ? WindowPresence.none : .open
    }
}

// #4114: what the MAIN RUN LOOP was doing while a stall lasted.
//
// WHY THE FIELD EXISTS. While an NSMenu tracks or a panel is modal, the main thread sits in a NESTED
// event loop, and the watchdog's `DispatchQueue.main.async` ping can wait there while the app is doing
// nothing wrong. Measured 2026-09-21: Dan opened a card's genre dropdown and clicked away without
// choosing anything, and the log recorded 1.62s and 1.17s stalls whose stack sample has the main thread
// idle 95.5% of the window with no Overture code running at all. #3660's bar is "no baseline-load
// main-thread stall over 100 ms, measured by the in-app watchdog", and a bar judged by an instrument
// that counts menu-open time can never be met, with nothing saying why (L400, L11).
//
// RECORDED, NEVER EXCLUDED. A rule that dropped these would also drop a real freeze that happened to
// occur while a menu was open, so `seconds` stays exactly as measured and this says what the run loop
// was doing (L116). #4153 makes the identical argument about sleep and names this issue as its sibling.
//
// THE READING NEEDS NO HELP FROM THE MAIN THREAD, which is the whole reason it can be taken at all.
// `CFRunLoopCopyCurrentMode(CFRunLoopGetMain())` is readable from any thread, so the watchdog takes it
// on its own queue. A reading that had to ask the main actor would be unavailable at exactly the moment
// a record is being written (L345), which is the trap `SurfaceBox` was built to avoid.
enum RunLoopActivity: String, Codable, CaseIterable, Equatable, Sendable {
    // No reading was taken: a record written before this field shipped, which is every one of the
    // thousand in Dan's log that are milestone 80's own "before" half, or a build that never sampled.
    case notRecorded
    // The main run loop was in its default mode. An ordinary freeze.
    case ordinary
    // The main run loop was running NO mode at all, which is the main thread being off the run loop and
    // in code. This is a READING and not a failed one, so it is not folded into `notRecorded`: "nobody
    // took a reading" and "the reading says the main thread is wedged" call for opposite next steps
    // (L98, L11). Expected to be rare in this app, whose main run loop is essentially always running.
    case offTheRunLoop
    // A mode this build cannot name. It is not the default mode, so it is a nested loop of some kind,
    // and saying which one would claim more than the reading supports (L11, L440).
    case otherMode
    // An event tracking loop: a menu, a scroll, a drag. The case this issue was opened for.
    case tracking
    // A modal panel loop.
    case modal

    // What `CFRunLoopCopyCurrentMode` returned, classified.
    //
    // PURE and here rather than inside the watchdog, so every case can be PRODUCED by a test rather than
    // reasoned about (L151). Every one is reachable in the running app.
    init(modeName: String?) {
        guard let modeName else { self = .offTheRunLoop; return }
        switch modeName {
        case "kCFRunLoopDefaultMode": self = .ordinary
        // Both spellings, because the constant AppKit exports and the string CoreFoundation returns are
        // not guaranteed to be one token, and a classifier that knew only one would silently call a
        // tracked menu `otherMode` on the platform that spells it the other way.
        case "NSEventTrackingRunLoopMode", "UITrackingRunLoopMode": self = .tracking
        case "NSModalPanelRunLoopMode": self = .modal
        default: self = .otherMode
        }
    }

    // How telling this reading is about the question the field answers, which is whether the stall could
    // be an artifact of a nested event loop. Higher wins a fold.
    //
    // A NESTED mode outranks everything, because one sample of it is enough to make the record suspect
    // and the samples either side of a menu are ordinary. `offTheRunLoop` sits above `ordinary` (the main
    // thread was in code, which is the more informative of the two) and below the nested modes (they
    // answer the question this field is for). `notRecorded` is last, so any reading that was TAKEN
    // survives a fold with one that was not.
    private var weight: Int {
        switch self {
        case .notRecorded: return 0
        case .ordinary: return 1
        case .offTheRunLoop: return 2
        case .otherMode: return 3
        case .tracking: return 4
        case .modal: return 5
        }
    }

    // Fold two readings taken during one stall into the one the record carries.
    //
    // ORDER INDEPENDENT by construction, which is what lets the watchdog accumulate samples as they
    // arrive without holding them, and what a test asserts across every pair rather than a chosen few.
    static func moreTelling(_ a: RunLoopActivity, _ b: RunLoopActivity) -> RunLoopActivity {
        a.weight >= b.weight ? a : b
    }
}

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
    // #3859: how many surfaces the build that wrote this record could name, or nothing where it was
    // written before that was recorded. See `StallSurface.vocabularySize` for why a reading of the
    // distribution needs it.
    let surfaceVocabulary: Int?
    // #3760: how many render passes the main thread ran while this stall lasted.
    //
    // THREE VALUES, and `nil` is never folded into `0`. `nil` is UNMEASURED: no pass has ever been
    // counted in this process, so this record cannot say. `0` means NO PASS WAS COUNTED. `N` is the
    // count. A zero standing for both would make "nothing bumped it" indistinguishable from the
    // instrument being absent (L98, L11).
    //
    // #3783 NARROWED WHAT `0` MAY BE READ AS, and this is the correction rather than a gloss on it. This
    // comment used to say `0` means "the surface did not rebuild", which is a claim about a quantity the
    // counter never measures (L11, L144, L440). The only writer is the first line of
    // `QueueView.makeRenderData()`, so what is counted is BODY EVALUATIONS of one view. Outside it:
    //
    //   the `@Query` fetch that feeds that body, paid before the counting line runs and priced as its
    //     own arm of a store change by #3750;
    //   every other surface that runs its own derivation and bumps nothing (#3762);
    //   main thread work that is not a render pass at all, a save, a scout write, the launch task.
    //
    // Each of those reads as `0` here, so `0` REFUTES nothing on its own. Measured on Dan's live log
    // 2026-09-11, 146 of 576 counted records carried it, and reading them as the surface standing still
    // would have sent this milestone's next diagnosis away from the queue on no evidence.
    //
    // OPTIONAL also because the log on Dan's Mac holds hundreds of records written before this shipped,
    // and those are the "before" half of milestone 80's own reading. They decode with this absent.
    let passes: Int?

    // #3813: how many times ROOTVIEW evaluated its own body while this stall lasted, or nothing where no
    // root draw has ever been counted in this process.
    //
    // BESIDE `passes` and never added to it. Under `.queue` two views draw and only `QueueView` bumps
    // `passes`, so a stall spanning only `RootView` evaluations reads `passes: 0`, and `0` there is the
    // reading that sends the next diagnosis away from the queue. Folding the two together would redefine
    // the unit `passes` counts and make every new record incomparable with the 1,041 already written,
    // which are milestone 80's own "before" half (L683).
    //
    // THREE VALUES, the same as `passes`: `nil` is UNMEASURED, `0` means no root draw was counted during
    // this stall, `N` is the count.
    let rootDraws: Int?

    // #3815: how long this stall's render passes took, in seconds, or nothing where no pass has ever
    // been timed in this process.
    //
    // BESIDE the count and never divided into it. A ratio would hide a stall that spanned no pass at all,
    // and `0` on the count is already the reading that needs care (#3783). Two terms let a reader say
    // which of the two explanations a long stall has: 29s spanning one pass of 0.17s is a freeze the
    // render pass does not account for, and 29s spanning one pass of 29s is one the pass IS.
    //
    // WHAT IT CANNOT SAY. The cost is added when a pass RETURNS and the count is bumped when it STARTS,
    // so a pass that never returns, which is the wedged main thread this instrument exists for, is in the
    // count and not in the seconds. That is the signal rather than a gap, and it is why these are not
    // asserted to agree.
    //
    // OPTIONAL because Dan's log holds a thousand records written before it shipped, and those are
    // milestone 80's own "before" half (L133).
    let passSeconds: Double?

    // #4153: how many seconds of this stall the MAC WAS ASLEEP, or nothing where the reading could not be
    // taken.
    //
    // The longest record in Dan's log on 2026-09-22 was 1057.90s and was not a freeze: `pmset -g log` puts
    // a 1074 second sleep ending at that instant exactly. The main thread was not blocked, it was not
    // scheduled. At 49 times the next longest record it sets every maximum and percentile taken from that
    // file, and this milestone's bar is judged against that file.
    //
    // RECORDED, NEVER EXCLUDED. A rule that dropped these would also drop a real freeze that happened to
    // overlap a sleep, so `seconds` stays exactly as measured and this says how much of it the machine was
    // not running (L116). #4114 makes the same argument about menu tracking, which is the sibling way in.
    //
    // THREE VALUES, the same as `passes` and `passSeconds`: `nil` is UNMEASURED, `0` means the Mac stayed
    // awake through this stall, `N` is the span. Optional also because Dan's log holds a thousand records
    // written before this shipped, and those are milestone 80's own "before" half (L133).
    //
    // WHERE THE NUMBER COMES FROM, because the obvious source does not work on this hardware.
    // `mach_continuous_time` minus `mach_absolute_time` is the documented way to measure sleep and it was
    // measured here and found false: `fixtures/watch-gap-clock-measurement.json` reads every clock macOS
    // offers against `kern.boottime` over a 54.19 hour window holding 71,341 seconds of real sleep, and
    // that difference comes to 464.6s, 0.65% of it. #2220 wrote the conclusion into the fixture: there is
    // no awake clock to read on this hardware. So this is the sleep `SystemSleep` OBSERVED, through the
    // `NSWorkspace` notifications `SleepObserver` already listens to.
    let asleepSeconds: Double?

    // #4122: this record was PROMOTED back into the live log by a compaction, so it is not part of the
    // window the rest of the file describes.
    //
    // `FreezeLog.compacted` keeps the newest `fileCap` records and promotes the single longest older stall
    // back in, both deliberately (a cap by count over a file where a 250 ms blip and a 58 second freeze are
    // one line each lets cheap writers evict expensive observations). The consequence was invisible: Dan's
    // file on 2026-09-21 opened with a 1,047 second stall from 2026-09-18 followed by records from
    // 2026-09-21T20:07Z onwards, so any count, maximum or percentile taken over it silently answered about
    // a truncated window with one out of band member in it. #3660's bar is defined as a count over this
    // file, so a fix could be judged against a window whose oldest half was archived mid measurement.
    //
    // A `var`, uniquely among these fields, and that is the design rather than an oversight.
    // `FreezeLog.compacted` marks the promoted record by copying it and setting this, because rebuilding it
    // through `init` would re-derive `surfaceVocabulary` from the RUNNING build while the record claims to
    // be the one an older build wrote. That is the single field here that would read as correct and be
    // wrong (L443, L510), so the mark is a mutation of a copy and nothing else about the record can move.
    //
    // TWO VALUES ONLY, not three, and `nil` is the absent one: a record nobody promoted carries nothing
    // rather than `false`. Encoding `false` on every line would grow every record in the file to say
    // something about a rule that applies to one of them, and `nil` already means exactly what is wanted
    // here, which is "this reader has no reason to think it was promoted". What separates "no compaction
    // has happened" from "one happened and promoted nothing" is the FILE's note, not this field.
    var promotedFromOlderWindow: Bool?

    // #3788: decoded as `.unknown` when absent, which is every record in Dan's log written before this
    // shipped. A custom decode rather than an optional, because the ABSENT case already has a name here and
    // two ways of spelling it (nil and .unknown) would be two spellings of one fact (L544).
    let windows: WindowPresence

    // #4114: what the main run loop was doing while this stall lasted, folded from the samples taken
    // across it, or `.notRecorded` where none was.
    //
    // Decoded as `.notRecorded` when absent, which is every record in Dan's log written before this
    // shipped, on `windows`'s precedent exactly and for its reason: the ABSENT case already has a name
    // here, and two ways of spelling it (nil and .notRecorded) would be two spellings of one fact (L544).
    //
    // WHAT IT MAY BE READ AS, stated narrowly. `.tracking` says a tracking loop was seen at some point
    // during the stall, not that the stall was CAUSED by it, and the other fields are what settle that:
    // a record with `.tracking`, `passes: 0` and `passSeconds: 0` is the contaminated shape #4114
    // measured, while one with `.tracking` and real render time is a genuine freeze that happened to
    // overlap a menu. Nothing here excludes either (L116, L11).
    let runLoopActivity: RunLoopActivity

    // The whole identity, as one string, because a reader that remembers what it has said has to remember
    // BOTH halves: the sequence restarts at 1 in every process, so it is not an identity on its own.
    var identity: String { "\(session)#\(sequence)" }

    init(session: String, sequence: Int, at: Date, seconds: Double, surface: StallSurface,
         load: MachineLoad, loadAverage: Double?, passes: Int?, rootDraws: Int? = nil,
         passSeconds: Double? = nil, windows: WindowPresence = .unknown,
         asleepSeconds: Double? = nil, runLoopActivity: RunLoopActivity = .notRecorded,
         promotedFromOlderWindow: Bool? = nil) {
        self.session = session
        self.sequence = sequence
        self.at = at
        self.seconds = seconds
        self.surface = surface
        self.load = load
        self.loadAverage = loadAverage
        // #3859: DERIVED here, never a parameter. A caller that had to pass it could pass a stale number,
        // and the one value that would read as "correct but wrong" is a count from a build with a
        // different vocabulary. There is nothing for a call site to get wrong because there is nothing to
        // pass (L41, L168).
        self.surfaceVocabulary = StallSurface.vocabularySize
        self.passes = passes
        self.rootDraws = rootDraws
        self.passSeconds = passSeconds
        self.windows = windows
        self.asleepSeconds = asleepSeconds
        self.runLoopActivity = runLoopActivity
        self.promotedFromOlderWindow = promotedFromOlderWindow
    }

    // The absent field becomes `.unknown` rather than failing the whole record. Dan's log holds 500 records
    // written before this existed and they are milestone 80's own "before" half, so a decode that rejected
    // them would destroy the comparison this field exists to enable (L133).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(String.self, forKey: .session)
        sequence = try c.decode(Int.self, forKey: .sequence)
        at = try c.decode(Date.self, forKey: .at)
        seconds = try c.decode(Double.self, forKey: .seconds)
        // #3859: THE SAME RULE the windows field below records, applied to the two enum fields that were
        // still decoded directly. Decoding an enum rejects a spelling it does not know by throwing, which
        // fails the WHOLE record rather than one field, and #3859 is the change that makes that bite: it
        // adds seven surfaces, so every record this build writes about one of them is unreadable to any
        // build that predates it, and the next case added does the same to this one. A rule already fixed
        // for one field and left on its siblings is the defect, not the instance (L30, L255).
        //
        // An unrecognised surface folds into `.notRecorded`, whose documented meaning is exactly this
        // reader having no surface rather than a wrong one. An unrecognised load folds into `.unmeasured`,
        // whose meaning is the reading could not be taken. Neither invents an answer (L11).
        let surfaceSpelling = try c.decodeIfPresent(String.self, forKey: .surface)
        surface = surfaceSpelling.flatMap(StallSurface.init(rawValue:)) ?? .notRecorded
        let loadSpelling = try c.decodeIfPresent(String.self, forKey: .load)
        load = loadSpelling.flatMap(MachineLoad.init(rawValue:)) ?? .unmeasured
        loadAverage = try c.decodeIfPresent(Double.self, forKey: .loadAverage)
        surfaceVocabulary = try c.decodeIfPresent(Int.self, forKey: .surfaceVocabulary)
        passes = try c.decodeIfPresent(Int.self, forKey: .passes)
        rootDraws = try c.decodeIfPresent(Int.self, forKey: .rootDraws)
        passSeconds = try c.decodeIfPresent(Double.self, forKey: .passSeconds)
        // #4153: absent on every record written before it shipped, which is the whole of the "before" half
        // this milestone compares against, so absence is `nil` and never `0`.
        asleepSeconds = try c.decodeIfPresent(Double.self, forKey: .asleepSeconds)
        // #4122: absent on a record nobody promoted, which is almost all of them.
        promotedFromOlderWindow = try c.decodeIfPresent(Bool.self, forKey: .promotedFromOlderWindow)
        // Decoded as a STRING and mapped, never as the enum directly. `decodeIfPresent` on an enum THROWS on
        // a value it does not know, which fails the WHOLE record rather than one field, so a later build
        // adding a fourth state would make every record it writes unreadable to this one. This file's own
        // encoder pins its date strategy for exactly that reason, because a file read by a later version has
        // to decode what an earlier one wrote (L26, L255).
        //
        // An unrecognised spelling folds into `.unknown`, and that is right rather than merely convenient:
        // `.unknown` means "this reader cannot say", and "written before the field existed" and "written by a
        // build that knows more than I do" are both exactly that. No fourth case to tell them apart, because
        // nothing downstream would act differently on them.
        let spelling = try c.decodeIfPresent(String.self, forKey: .windows)
        windows = spelling.flatMap(WindowPresence.init(rawValue:)) ?? .unknown
        // #4114: decoded as a STRING and mapped, for the reason spelled out directly above. An
        // unrecognised spelling folds into `.notRecorded`, which means "this reader cannot say", and both
        // "written before the field existed" and "written by a build that knows a mode I do not" are
        // exactly that.
        let activitySpelling = try c.decodeIfPresent(String.self, forKey: .runLoopActivity)
        runLoopActivity = activitySpelling.flatMap(RunLoopActivity.init(rawValue:)) ?? .notRecorded
    }
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

    // #3815: how long the render passes inside a stall took, between two readings of the cost total.
    //
    // The MIRROR of `passesSpanned` above and deliberately its own function rather than a generic one:
    // the two answer different questions and their absent cases mean different things, so folding them
    // would make one message answer for both (L11).
    static func passSecondsSpanned(from before: Double?, to after: Double?) -> Double? {
        guard let after else { return nil }
        let start = before ?? 0
        guard after >= start else { return nil }
        return after - start
    }

    // #4153: how many seconds of OBSERVED SLEEP fell between two readings of `SystemSleep`'s total.
    //
    // ITS OWN FUNCTION rather than a reuse of `passSecondsSpanned` above, which has the identical body
    // today. The two answer different questions over different quantities, and the sentence a reader
    // needs when either returns `nil` is different: one says no pass has ever been timed in this process,
    // the other says the sleep total could not be read. Folding them would make one message answer for
    // both (L11), which is the reason `passSecondsSpanned` itself is not `passesSpanned`.
    //
    // A total that went BACKWARDS is unmeasured rather than negative sleep: it accumulates and never
    // shrinks, so a smaller second reading is a fault in the instrument and not a machine that un-slept.
    static func sleepSpanned(from before: Double?, to after: Double?) -> Double? {
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

    // What one stall does: what is KEPT in memory, and whether it is WRITTEN to the durable file.
    //
    // #3812 SPLIT THESE, and they were one comparison before it. The watchdog wrote a record only when
    // the kept set GREW, so once the set was full nothing was ever written again and the session went
    // quiet with nothing saying so. They are separate decisions and this type is what keeps them apart
    // (L53): a bounded in-memory set is a reading of the session's shape, and the file is the durable
    // record milestone 80's bar is read off.
    struct Admission: Equatable, Sendable {
        var kept: Kept
        // Whether the caller is to write this stall to the file. The in-memory cap has no say in it.
        var write: Bool
    }

    static func adding(_ stall: StallRecord, to kept: Kept,
                       floor: Double = floorSeconds, cap: Int = cap) -> Admission {
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
            return Admission(kept: next, write: false)
        }
        next.records.append(stall)
        if next.records.count > cap {
            let dropped = next.records.count - cap
            next.records.removeFirst(dropped)
            next.evicted += dropped
        }
        // WRITTEN, whatever the kept set did with it. A stall at or above the floor is a record; whether
        // the in-memory list had room for it is a different question and is answered above (#3812).
        return Admission(kept: next, write: true)
    }
}
