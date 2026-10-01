import Foundation

// #4329 (A12): `SourceCheck.decide` stopped writing through the row; it returns its writes beside its decision,
// and a scout's landing block applies them (`WatchedSource.applyCaptured`). The tests below that pin a source's
// health lifecycle (it broke, it recovered, it did not change) read the ROW after a decision, so they ask
// through this: the same decision, with its writes applied exactly as the landing applies them. One helper
// rather than the two lines at every call site, so a test cannot apply a different set than the one decided.
@MainActor
extension SourceCheck {
    @discardableResult
    static func decideApplying(source: WatchedSource, result: Result<FetchedPage, SourceFetchError>,
                               depth: ScoutDepth, now: Date) -> Decision {
        let (decision, writes) = decide(source: source, result: result, depth: depth, now: now)
        source.applyCaptured(writes)
        return decision
    }
}
