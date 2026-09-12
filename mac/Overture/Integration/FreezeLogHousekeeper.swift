import Foundation

// #3828: the freeze log's bookkeeping, OFF the main actor and serialised.
//
// WHY IT MOVED. #3796 put `FreezeLog.housekeeping` on `RootView`'s hourly tick, which runs on the main
// actor, and nothing measured what it costs there. Measured 2026-09-12 (`WhatTheHourlyMaintenanceCostsTests`):
//
//   quiet, a file at its 500 cap              4.71 ms    28.3% of one 60Hz frame
//   working, 700 records, archives+rewrites  12.75 ms    76.5% of one frame
//
// So it drops most of a frame in the hour it compacts and costs a quarter of one every other hour, for
// the whole life of a resident process, on the thread milestone 80 exists to shorten. At LAUNCH that was
// accepted, because nobody is waiting on a frame; hourly it is not.
//
// WHY AN ACTOR RATHER THAN A DETACHED TASK. Moving a read, modify, write off the main actor removes the
// serialisation that thread was providing for free. There are two callers, the launch task and the hourly
// tick, and they can overlap: a launch while a tick is in flight would give two concurrent compactions of
// one file, each reading the same records, each archiving them, and the archive would hold every dropped
// record twice. An actor makes that impossible by construction rather than by a rule nobody enforces
// (L27, "assume it runs twice").
//
// WHAT DID NOT MOVE. The WRITE on the freeze path is still a bare append from the watchdog's own queue,
// which is what makes it safe during a wedged main thread; only this read, modify, write is here (L105).
actor FreezeLogHousekeeper {

    // One instance, because the serialisation is the point: two instances would serialise nothing.
    static let shared = FreezeLogHousekeeper()

    func run(at url: URL, now: Date) -> FreezeLog.Housekeeping {
        FreezeLog.housekeeping(at: url, now: now)
    }
}
