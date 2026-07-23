import Foundation

// #821: one rule for how long Overture keeps its own forensic leftovers.
//
// Two files are written deliberately and read by nobody afterwards:
//
//   The pinned page (`overture-scout-page-<id>.html`). The extract run works from the exact bytes the app
//   fetched and hashed, never from whatever the site serves the agent a second later. Load-bearing, and
//   worth keeping after the run too: when a source comes back with nonsense, this file is the only record
//   of what that page actually said.
//
//   The `.corrupt` results (#868). The bytes of a run whose results file did not parse, moved aside
//   rather than deleted, because they are the only evidence of what the run really did.
//
// Neither had an owner, so both stayed forever. The pins from watched sources are self-limiting (each
// source overwrites its own, keyed by id), but a lead pin is not: `LeadIntakeModel.sourceId(for:)` builds
// the id from the pasted URL, so every distinct link Dan ever pastes leaves its own file behind. A source
// dropped from the watchlist orphans its pin the same way.
//
// Swept at launch, mirroring the store-backup rotation next door, which is the app's existing answer to
// "written deliberately, kept deliberately, cleaned up by nobody".
enum HandoffCleanup {
    // Dan's call (#821): two weeks. Long enough that a source behaving oddly can still be checked against
    // the page Overture actually read, short enough that the folder stays small.
    static let keepFor: TimeInterval = 14 * 24 * 60 * 60

    struct Result: Equatable {
        var deleted: [URL] = []
        // Reported rather than swallowed. Nothing surfaces these today (a file that resists deletion is
        // simply retried next launch, and nothing downstream depends on it being gone), but a sweep that
        // cannot say what it failed to do is a sweep that can silently stop working.
        var failed: [URL] = []
        // #849's rule, in reverse: the suite must never reach into the live handoff directory. Said out
        // loud rather than left as a silent no-op, so the guard can be asserted on. "Nothing happened" is
        // indistinguishable from a folder that simply had nothing to sweep.
        var refusedUnderTest = false
    }

    // The handoff directory is NOT a scratch folder. It holds Dan's booking history, his Gmail tokens, his
    // voice guidance, the queue and results files the detached runs hand back, and in Release the live
    // SwiftData store itself (which moved into this folder to get off the shared Application Support
    // root). So the test is by NAME first and age second: a file this enum does not own is not a candidate
    // at any age. An age-only sweep of this directory would eventually take every one of those, starting
    // with the store, and the loss would be silent.
    static func owns(_ filename: String) -> Bool {
        (filename.hasPrefix("overture-scout-page-") && filename.hasSuffix(".html"))
            || filename.hasSuffix(".corrupt")
    }

    // Best-effort, and it never throws: housekeeping must not be able to stop the app opening. A file it
    // cannot delete is recorded and skipped, and the rest of the sweep still runs, so one stubborn file
    // cannot quietly halt the cleanup of everything behind it.
    //
    // A pin an in-flight run is about to read is minutes old at most (the queue is built from pins written
    // in the same pass), so no horizon measured in days can reach one. That is why this needs no lock and
    // no check against the live queue.
    @discardableResult
    static func sweep(handoffDirectory: URL, now: Date, keepFor: TimeInterval = keepFor,
                      fileManager: FileManager = .default) -> Result {
        // The pin refuses to WRITE into the live handoff directory under test (#849). Deleting from it is
        // the same trespass, and a quieter one: nothing appears where it should not, something merely
        // stops being there. A test that passes its own temp directory is safe and every one of them does.
        if AppEnvironment.isRunningUnderTests, handoffDirectory == StoreLocation.handoffDirectory {
            return Result(refusedUnderTest: true)
        }

        var result = Result()
        // A fresh install, before anything has written a handoff file at all.
        let names = (try? fileManager.contentsOfDirectory(atPath: handoffDirectory.path)) ?? []
        let cutoff = now.addingTimeInterval(-keepFor)

        for name in names where owns(name) {
            let url = handoffDirectory.appendingPathComponent(name)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            // No readable date means no age, and a file with no age is never old enough to delete.
            // Unknown fails towards keeping the bytes, never towards destroying them.
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified < cutoff else { continue }

            do {
                try fileManager.removeItem(at: url)
                result.deleted.append(url)
            } catch {
                result.failed.append(url)
            }
        }
        return result
    }
}
