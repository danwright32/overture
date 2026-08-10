import Foundation

// #1613/#2105: when a file on disk was last written, read so that the answer is about the file NOW.
//
// Foundation caches resource values on a `URL` VALUE. A URL that has been asked once keeps answering with
// the reading it got then, for the life of that value, even after the file has been deleted. Measured
// 2026-08-04: delete the file and the same URL still reports the old modification date, while a freshly
// built URL correctly reports nothing.
//
// That turns "the file is gone" into "the file is still there and stale", and every reader in this app
// decides something from it: whether a detached run is alive, whether this run produced results, whether
// the Downbeat export has changed since the last reconcile, whether the export is healthy at all.
//
// #1613 fixed it inside `DetachedRunner.heartbeat`. The other five sites were never audited, and #2105 is
// that audit. They were all safe by ACCIDENT, because each happened to build its URL from a computed
// property on every call, which is luck rather than a design: the first caller to hold a URL in a `let`,
// or to read one right after deleting the file, gets the stale answer with nothing to warn them.
//
// So it is one helper rather than six careful call sites (L30: fix the class, not the instance). A reader
// added next year gets the right answer without knowing this defect exists.
enum FileTimestamp {

    // Nil when there is no file, which is the answer the cache was swallowing.
    //
    // `url` is taken by value and mutated locally on purpose: `removeAllCachedResourceValues` is mutating,
    // and the copy is what makes this safe to call with a URL the caller is holding on to. The caller's
    // own value keeps whatever it had cached; this one is asked fresh.
    static func modifiedAt(_ url: URL) -> Date? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? nil
    }
}
