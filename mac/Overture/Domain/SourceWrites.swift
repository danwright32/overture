import Foundation

// #4329 (A12): what a scout's READ PHASE decided to write on one watched source, held as a value and
// applied by the landing block, never written through the row while the read is still going.
//
// WHY. The read phase awaits (the network, the classify pass off the actor, Dan's answer to the read budget
// question), and the window draws at every await. A row written in place before an await sits in the main
// context unsaved across it, so `ScopeMemo` (which serves a refetch only while `!main.hasChanges`) has to
// rebuild every surface for as long as the sweep runs, and A13's re-validation cannot set aside a reading a
// later run overtook, because the older reading's health and failure streak are already on the row. Held
// here instead, a source's writes are applied once, under the landing's token, after that re-validation, and
// saved by the landing's own save, so the context is clean across every read-phase await and a superseded
// reading leaves the row exactly as the later run left it.
//
// ONE value for every branch that writes, rather than a type per caller, so the landing block applies every
// source the same way and a test can prove every branch was driven (`Site`).
struct SourceWrites: Equatable, Sendable {

    // Where in the read phase a write was decided: one case per branch that writes, derived from the code
    // by `ScoutReadPhaseWritesNothingTests`, which also drives each one and fails on a case no fake reached.
    enum Site: String, CaseIterable, Sendable {
        // `SourceCheck.decide`: its failure branch, and its two success branches, the unchanged one both
        // with and without a re-read owed (#1217).
        case fetchFailed
        case pageUnchanged
        case pageUnchangedRereadOwed
        case pageChanged
        // `ScoutService.check`: a source with no usable address, the pending hash and months of a page
        // queued for the paid read, and a Squarespace events collection promoted to its native feed (#1503).
        case noUsableAddress
        case queuedForReading
        case promotedToSquarespace
        // `runScout`: an html page read natively from the structure behind it (#1295, #1529).
        case readInline
        // `ScoutService.readNative`: a native extractor that threw.
        case nativeReadFailed
        // `ScoutExtractIngest.ingest`: the run's own note (#875), a failed read (`fail`), and a quiet page Dan
        // already confirmed (#1027).
        case runNote
        case readFailed
        case confirmedEmpty
    }

    // One write, in the order the read phase used to make it.
    enum Step: Equatable, Sendable {
        case checkedAt(Date)                                   // lastCheckedAt
        case failedRead(SourceFailure, at: Date)               // recordFailedRead (#1759)
        case fetchedCleanly(observedHash: String, insecure: Bool) // health, lastFailure, #1048, #1544
        case unreadChanges(Bool)                               // hasUnreadChanges
        case pendingRead(hash: String?, months: [String])      // pendingContentHash, pendingPageMonths (#897)
        case ticketingFeed(String)                             // ticketingFeedURL (#1529)
        case kind(SourceKind)                                  // the Squarespace promotion (#1503)
        case notes(String?)                                    // the run's note (#875)
        // #1027's acceptance, its hash promotion included. The hash is the one the confirmation was judged
        // against when the result was read, carried rather than re-read from the row when it lands.
        case confirmedEmpty(at: Date, readHash: String?)
    }

    private(set) var sites: [Site] = []
    private(set) var steps: [Step] = []

    static let none = SourceWrites()

    init() {}

    init(_ site: Site, _ steps: [Step]) {
        self.sites = [site]
        self.steps = steps
    }

    var isEmpty: Bool { steps.isEmpty }

    // Another branch's writes after these, in the order the read phase decided them.
    mutating func append(_ other: SourceWrites) {
        sites += other.sites
        steps += other.steps
    }

    func appending(_ other: SourceWrites) -> SourceWrites {
        var out = self
        out.append(other)
        return out
    }
}

extension WatchedSource {
    // #4329: the ONE place a read phase's captured writes reach the row, called only from a landing block,
    // under its token and after its re-validation. A mutator by its own shape (it writes this row), so
    // `StoreWriteScan` recognises a call to it by name and a read phase that called it would be caught.
    func applyCaptured(_ writes: SourceWrites) {
        for step in writes.steps {
            switch step {
            case .checkedAt(let at):
                lastCheckedAt = at
            case .failedRead(let failure, let at):
                recordFailedRead(failure, now: at)
            case .fetchedCleanly(let observedHash, let insecure):
                health = .ok
                lastFailure = nil
                lastObservedContentHash = observedHash
                lastFetchWasInsecure = insecure
            case .unreadChanges(let unread):
                hasUnreadChanges = unread
            case .pendingRead(let hash, let months):
                pendingContentHash = hash
                pendingPageMonths = months
            case .ticketingFeed(let url):
                ticketingFeedURL = url
            case .kind(let kind):
                self.kind = kind
            case .notes(let notes):
                self.notes = notes
            case .confirmedEmpty(let at, let readHash):
                // #1027: a no_dated_content page Dan already confirmed, read again at the same bytes. Accepted,
                // not failed: the hash is stamped so the daily run sees no change, the unread flag and any prior
                // failing display are cleared. Baseline and successfulCheckCount are deliberately left alone
                // (an empty page is not this source's real size), and lastSucceededAt is not stamped: nothing
                // was ingested. #1759: read cleanly, so the run of runs that could not read it is over.
                lastCheckedAt = at
                health = .ok
                lastFailure = nil
                failedReadStreak = 0
                lastContentHash = readHash ?? lastContentHash
                pendingContentHash = nil
                pendingPageMonths = []
                hasUnreadChanges = false
            }
        }
    }
}
