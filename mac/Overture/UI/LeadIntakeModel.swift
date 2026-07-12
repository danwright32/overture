import Foundation
import SwiftData
import Observation

// #799 slice 4b: the Add-a-lead sheet's brain. Dan pastes a link; Overture fetches the page itself,
// pins it, hands it to the detached extract run, waits (visibly), and shows him what it found so he
// can confirm before anything is written.
//
// Every dependency is injected, so the whole flow is a real unit test with no network, no Claude run
// and no UI. The states below are the ones Dan actually sees, so what they SAY is the behaviour.
@MainActor
@Observable
final class LeadIntakeModel {
    enum Phase: Equatable {
        case idle
        case working(startedAt: Date)            // fetching, then the detached run is reading it
        case review([ExtractedEvent], note: String?)
        case problem(String)                     // every unhappy ending, NAMED, never a silent spinner
        case added(Int)
    }

    var urlText: String = ""
    private(set) var phase: Phase = .idle
    var selected: Set<String> = []

    // Set when the page Dan pasted had nothing readable on it and we followed its ticket link to the
    // page that did. He MUST be told: he pasted his ensemble's site and the listing came off Lincoln
    // Center's. Silently swapping the page under him would be exactly the kind of quiet cleverness that
    // makes a tool impossible to trust.
    private var followedFromNote: String?
    // Whose lead this is, when we had to leave the page Dan pasted (see SourceFetcher.onlyForOrg).
    private var onlyForOrg: String?

    // Injected seams (defaults are the real thing).
    private let fetch: (URL) async throws -> FetchedPage
    private let pin: (FetchedPage, String) throws -> URL
    private let launch: ([ScoutExtractQueueItem]) throws -> Void
    private let readResults: (String) -> ScoutExtractResults?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         fetch: @escaping (URL) async throws -> FetchedPage = { try await SourceFetcher.fetch($0) },
         pin: @escaping (FetchedPage, String) throws -> URL = { try ScoutPagePin.write($0, forSourceId: $1) },
         launch: @escaping ([ScoutExtractQueueItem]) throws -> Void = { items in
             try ScoutExtractService.startExtract(items: items, now: Date())
         },
         readResults: @escaping (String) -> ScoutExtractResults? = { _ in
             guard let data = try? Data(contentsOf: ScoutExtractResultsDecoder.defaultURL) else { return nil }
             return try? ScoutExtractResultsDecoder.decode(data)
         }) {
        self.defaults = defaults
        self.fetch = fetch
        self.pin = pin
        self.launch = launch
        self.readResults = readResults
    }

    // A stable identity for a found show, so Dan's checkbox survives a redraw.
    func key(for event: ExtractedEvent) -> String {
        "\(event.title)|\(event.performanceDate ?? "")|\(event.venue ?? "")"
    }

    var startedAt: Date? {
        if case .working(let at) = phase { return at }
        return nil
    }

    // Real "N of M" from the run's own progress file, so the sheet counts rather than spins.
    var progressDetail: String? {
        ScoutExtractProgressDecoder.label(from: ScoutExtractProgressDecoder.loadCurrent())
    }

    func reset() {
        phase = .idle
        selected = []
        urlText = ""
        followedFromNote = nil
        onlyForOrg = nil
    }

    func start(now: Date, pollEvery: TimeInterval = 2, giveUpAfter: TimeInterval = RunTimeouts.scoutExtract,
               sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            phase = .problem("That doesn't look like a link. Paste the web address of the show or the org's events page.")
            return
        }
        // We already know how this one ends, so do not spend a fetch and a Claude run rediscovering a
        // login wall (verified: a raw fetch of a public Instagram post is ~600KB of login page).
        if LeadIntake.knownUnreadableHost(url) != nil {
            phase = .problem(LeadIntake.loginWalledMessage)
            return
        }
        // Dan's rule: a link he has already handed over is not re-read. Handing over a lead means the
        // org is worth watching, and the watchlist re-checks it; spending another fetch and another
        // Claude run on the same page buys nothing. It also makes the stale-results race unreachable
        // (a second run under the same id could otherwise find the FIRST run's results file and hand
        // back its shows instantly, without waiting).
        if LeadSubmissions.contains(url, in: defaults) {
            phase = .problem("You've already added that link. Its shows are in your queue, and once the watchlist is on, that organization gets re-checked on its own.")
            return
        }

        phase = .working(startedAt: now)
        let sourceId = Self.sourceId(for: url)

        let page: FetchedPage
        let path: URL
        do {
            page = try await fetch(url)

            // Caught natively, BEFORE a Claude run is spent. A page whose bytes carry only a navigation
            // shell (a Wix or Squarespace site that draws its calendar in JavaScript) has nothing in it
            // to read. Handing it to the AI wastes a minute and an invocation to be told what we already
            // know, and invites the worst outcome there is: a confident WRONG "no events on this page"
            // about a page that is full of events we cannot see. That is exactly what happened to Dan on
            // his first real lead, and he was told his org's page was not an events page. It was.
            guard PageNormalizer.carriesReadableContent(page.normalizedHTML) else {
                phase = .problem(LeadIntake.unreadableMessage)
                return
            }
            if page.followedTicketLinkFrom != nil, let host = URL(string: page.finalURL)?.host {
                followedFromNote =
                    "I couldn't read that page, so I followed its ticket link and read \(host) instead."
                onlyForOrg = page.onlyForOrg
            }
            path = try pin(page, sourceId)
        } catch let error as SourceFetchError {
            phase = .problem(error.errorDescription ?? "Couldn't read that page.")
            return
        } catch {
            phase = .problem("Couldn't read that page: \(error.localizedDescription)")
            return
        }

        // A run that is still FINISHING is a reason to wait a few seconds, not a reason to refuse Dan's
        // next lead. He hit this: the previous run had already given him an answer but its process was
        // still exiting, so it still held the lock, and the app told him to go away and try again. The
        // lock exists to stop two runs clobbering one results file, not to bounce the user.
        let item = ScoutExtractQueueItem(sourceId: sourceId, orgName: onlyForOrg ?? url.host,
                                         listingsURL: page.finalURL, pagePath: path.path,
                                         onlyForOrg: onlyForOrg)
        var waited: TimeInterval = 0
        while true {
            do {
                try launch([item])
                break
            } catch ScoutExtractService.ExtractLaunchError.alreadyRunning {
                guard waited <= giveUpAfter else {
                    phase = .problem("Overture is still reading a previous page. Give it a moment and try again.")
                    return
                }
                await sleep(pollEvery)
                waited += max(pollEvery, 1)
            } catch let error as ScoutExtractService.ExtractLaunchError {
                phase = .problem(error.errorDescription ?? "Couldn't start the reader.")
                return
            } catch {
                phase = .problem("Couldn't start the reader: \(error.localizedDescription)")
                return
            }
        }

        await waitForResults(sourceId: sourceId, startedAt: now,
                             pollEvery: pollEvery, giveUpAfter: giveUpAfter, sleep: sleep)
    }

    private func waitForResults(sourceId: String, startedAt: Date, pollEvery: TimeInterval,
                                giveUpAfter: TimeInterval, sleep: (TimeInterval) async -> Void) async {
        var waited: TimeInterval = 0
        while waited <= giveUpAfter {
            if let results = readResults(sourceId), results.verdict(for: sourceId) != nil {
                apply(LeadIntake.outcome(from: results, sourceId: sourceId, onlyForOrg: onlyForOrg))
                return
            }
            await sleep(pollEvery)
            waited += pollEvery
        }
        // A run that never came back is NOT "no shows found". Say which one it was.
        phase = .problem("The reader didn't finish in time. It may still be running; try again in a minute.")
    }

    private func apply(_ outcome: LeadIntake.Outcome) {
        switch outcome {
        case .found(let events, let note):
            phase = .review(events, note: [followedFromNote, note].compactMap { $0 }.joined(separator: " "))
            selected = Set(events.map(key(for:)))     // all checked; he unchecks what he doesn't want
        case .foundButUnusable(let rejected, _):
            // NOT "no shows". The page had shows and none has a real venue, which means this source's
            // detail pages are not being read. Naming it is what makes it fixable.
            phase = .problem("Found \(rejected.count) show\(rejected.count == 1 ? "" : "s") on that page, but none of them name a venue, so I can't use them. That usually means the show's own page didn't load.")
        case .noUpcomingShows(let message), .notAnEventsPage(let message), .unreadable(let message):
            phase = .problem(message)
        case .nothingCameBack:
            phase = .problem("The reader came back with nothing for that page. Try again, or paste the org's events page.")
        }
    }

    // Confirmed shows go in through the EXISTING classify/assemble/upsert chain, never a hand-built
    // insert. That is what keeps blocked dates, the #769 do-not-contact suppression, the #798
    // upcoming-only guard and the #797 run identity applying to a hand-added lead exactly as they do to
    // a scouted one. One pipeline, not two, and a refused org cannot be smuggled in by hand.
    //
    // #826: with ONE stage of that pipeline held back. `reconcilesFeed: false` says what is true: this
    // is one page Dan pasted, not a sweep of a venue's calendar, so a stored show being absent from it
    // is evidence of nothing. Without it, adding a lead counted a miss against every upcoming Carnegie
    // show, and two leads in a row marked them disappeared and hid them from the queue.
    @discardableResult
    func confirm(into context: ModelContext, today: String = QueueModel.easternToday()) -> Int {
        guard case .review(let events, _) = phase else { return 0 }
        let chosen = events.filter { selected.contains(key(for: $0)) }
        guard !chosen.isEmpty else { return 0 }

        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let outcome = ScoutService.apply(events: chosen,
                                         clients: loaded.clients,
                                         history: LocalHistory.forMatching(existing: existing),
                                         blocked: Set(loaded.blockedDates),
                                         today: today, reconcilesFeed: false, into: context)
        let added = outcome.inserted + outcome.updated
        // Recorded only now, not at submit: a link that failed to read, or whose shows Dan dropped, is
        // one he must be able to try again. Only a link that actually produced something counts as
        // handed over.
        if added > 0, let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            LeadSubmissions.record(url, in: defaults)
        }
        phase = .added(added)
        return added
    }

    // A stable, safe id for the pinned page and the work-list. Derived from the URL so re-pasting the
    // same link reuses the same pin rather than littering the handoff folder.
    static func sourceId(for url: URL) -> String {
        ScoutPagePin.safeName("lead-" + (url.host ?? "page") + "-" + url.path)
    }
}
