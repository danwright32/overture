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
        // #859: carries the note too. Dan MUST still be told when the page he pasted could not be read
        // and Overture followed its ticket link and read somebody else's site instead. Silently swapping
        // the page under him is exactly the quiet cleverness that makes a tool impossible to trust, and
        // that warning used to live on the review step, which no longer exists.
        case added(Int, note: String?)
    }

    var urlText: String = ""
    private(set) var phase: Phase = .idle

    // Set when the page Dan pasted had nothing readable on it and we followed its ticket link to the
    // page that did. He MUST be told: he pasted his ensemble's site and the listing came off Lincoln
    // Center's. Silently swapping the page under him would be exactly the kind of quiet cleverness that
    // makes a tool impossible to trust.
    private var followedFromNote: String?
    // #858: which months of a calendar were read, and which could not be. Same reasoning as the note
    // above, twice over. He pasted ONE page and is getting four months, so say so. And a month that
    // failed to load must be NAMED: three months coming back instead of four just looks like a venue
    // with a quiet autumn, and the spike found the quiet season is the normal state, which is exactly
    // what an unread month can hide inside.
    private(set) var monthsNote: String?
    // Whose lead this is, when we had to leave the page Dan pasted (see SourceFetcher.onlyForOrg).
    private var onlyForOrg: String?

    // #768/#802: the calendar behind this lead, which Overture PROPOSES to keep watching.
    //
    // Handing over a lead means "I care about these people, keep looking at them", so its calendar should
    // join the watchlist. But Dan confirms, because two things Overture cannot know are exactly the ones
    // that matter: whether this is a recurring NYC calendar or a touring act's itinerary (an itinerary is
    // mostly not in New York and re-reading it daily pays for nothing), and whether the URL is the org's
    // CALENDAR or just one show's page (a single show's page never changes again, so watching it would
    // be watching nothing, forever, while reporting as perfectly healthy).
    var watchThisCalendar = true          // Overture proposes; he unticks it
    var watchOrgName = ""                 // both editable: a guess shown to him, never written silently
    var watchURL = ""
    private(set) var watchVerdict: WatchedSourceProposal.Verdict?

    // What we actually read, kept so the proposal can be built from it.
    private var readEvents: [ExtractedEvent] = []
    private var readPageURL: String?
    private var readVerdict: PageVerdict?

    // Injected seams (defaults are the real thing).
    private let fetch: (URL) async throws -> FetchedPage
    private let pin: (FetchedPage, String) throws -> URL
    private let launch: ([ScoutExtractQueueItem]) throws -> Void
    private let readResults: (String) -> ScoutExtractResults?
    // #848: is the detached run still alive? Its heartbeat marker, injected so a dead run is a real unit
    // test. The wait loop below used to watch only for RESULTS, so a run that finished having written
    // nothing looked identical to one still working, and Dan watched a live counter tick upward on a
    // process that had exited three minutes earlier.
    private let isRunAlive: () -> Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         // #858: the lead path, and ONLY the lead path, reads four months of a calendar. It can afford to:
         // it applies its shows with no `feed:`, so it never reconciles and never marks anything
         // cancelled. The watchlist keeps `SourceFetcher`'s default of one page, because there a
         // silently short sweep can strike live shows from Dan's queue. See the note on `fetch`.
         fetch: @escaping (URL) async throws -> FetchedPage = {
             try await SourceFetcher.fetch($0, monthHorizon: CalendarMonthIndex.defaultHorizon)
         },
         pin: @escaping (FetchedPage, String) throws -> URL = { try ScoutPagePin.write($0, forSourceId: $1) },
         launch: @escaping ([ScoutExtractQueueItem]) throws -> Void = { items in
             try ScoutExtractService.startExtract(items: items, now: Date())
         },
         readResults: @escaping (String) -> ScoutExtractResults? = { _ in
             guard let data = try? Data(contentsOf: ScoutExtractResultsDecoder.defaultURL) else { return nil }
             return try? ScoutExtractResultsDecoder.decode(data)
         },
         isRunAlive: @escaping () -> Bool = { ScoutExtractService.isRunning(now: Date()) }) {
        self.defaults = defaults
        self.fetch = fetch
        self.pin = pin
        self.launch = launch
        self.readResults = readResults
        self.isRunAlive = isRunAlive
    }

    // A stable identity for a found show, so Dan's checkbox survives a redraw.
    func key(for event: ExtractedEvent) -> String {
        "\(event.title)|\(event.performanceDate ?? "")|\(event.venue ?? "")"
    }

    // #768/#802: work out what to propose watching, and prefill the editable fields with it. Called by
    // the sheet when it reaches the review step, because only the view can supply the existing sources.
    //
    // The proposal is a SUGGESTION. `confirm` re-derives it from the store before writing anything, so a
    // refused org cannot be re-added even if this went wrong or the UI was somehow stale.
    func prepareWatchProposal(existing: [WatchedSource]) {
        guard let pageURL = readPageURL, let verdict = readVerdict else {
            watchVerdict = nil
            return
        }
        let v = WatchedSourceProposal.verdict(pageURL: pageURL, verdict: verdict,
                                              events: readEvents, existing: existing)
        watchVerdict = v
        if case .propose(let orgName, let listingsURL) = v {
            if watchOrgName.isEmpty { watchOrgName = orgName }
            if watchURL.isEmpty { watchURL = listingsURL }
        } else {
            watchThisCalendar = false     // nothing to propose, so nothing is ticked
        }
    }

    var startedAt: Date? {
        if case .working(let at) = phase { return at }
        return nil
    }

    // Real "N of M" from the run's own progress file, so the sheet counts rather than spins.
    var progressDetail: String? {
        ScoutExtractProgressDecoder.label(from: ScoutExtractProgressDecoder.loadCurrent())
    }

    // The months of a calendar this lead actually read, in Dan's words rather than "2026-07".
    //
    // Silent on a page that was never a calendar (a single show page, an org homepage): a note that
    // fires on every lead is a note nobody reads, and then the one that matters gets skipped too.
    static func monthsNote(read: [String], unread: [String], unreachable: [String] = []) -> String? {
        guard read.count > 1 || !unread.isEmpty || !unreachable.isEmpty else { return nil }

        var parts: [String] = []
        if let first = read.first, let last = read.last, read.count > 1 {
            parts.append("I read \(read.count) months of that calendar (\(name(first)) to \(name(last))).")
        }
        if !unread.isEmpty {
            // Named, not merely missing. Three months back instead of four looks exactly like a venue
            // with a quiet autumn, and Dan would never know to look again.
            parts.append("I couldn't read \(list(unread.map(name))), so anything on in "
                         + "\(unread.count == 1 ? "that month" : "those months") isn't here.")
        }
        if !unreachable.isEmpty {
            // #900, and the difference from the sentence above is the whole point. That one is a month
            // whose page we asked for and did not get. This one is a month we never had a link to at all:
            // the calendar names it, but pages by a route this app cannot follow, so nothing failed
            // anywhere and Dan was handed one month of a season.
            //
            // Which is why this sentence ends with something he can DO. A 404 is a dead end, but this
            // month's page is right there on the site, and pasting it is a lead like any other.
            let one = unreachable.count == 1
            parts.append("That calendar has more months on it (\(list(unreachable.map(name)))), but it "
                         + "moves between them in a way I can't follow yet, so I only read the month it "
                         + "opened on. Paste \(one ? "that month's" : "a month's") own link and I'll "
                         + "read it.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // "2026-10" -> "October 2026"
    private static func name(_ label: String) -> String {
        let bits = label.split(separator: "-")
        guard bits.count == 2, let year = Int(bits[0]), let month = Int(bits[1]),
              (1...12).contains(month) else { return label }
        let months = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        return "\(months[month - 1]) \(year)"
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    func reset() {
        phase = .idle
        urlText = ""
        followedFromNote = nil
        monthsNote = nil
        onlyForOrg = nil
        watchThisCalendar = true
        watchOrgName = ""
        watchURL = ""
        watchVerdict = nil
        readEvents = []
        readPageURL = nil
        readVerdict = nil
    }

    // #859: `into` and `today` are here because the run now LANDS the shows itself. Dan does not pick
    // them: the sheet used to show every show with a checkbox and make him choose, and those same shows
    // then arrived in the scout queue for him to keep or dismiss. Two triage passes over one set of
    // shows, on the flow whose whole point is to be quick. The queue is already the triage surface, and
    // it is where he already is. His words: "I'm scouting it twice technically."
    func start(into context: ModelContext, now: Date,
               today: String = QueueModel.easternToday(),
               pollEvery: TimeInterval = 2, giveUpAfter: TimeInterval = RunTimeouts.scoutExtract,
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
            monthsNote = Self.monthsNote(read: page.monthsRead, unread: page.monthsUnread,
                                         unreachable: page.monthsUnreachable)
            readPageURL = page.finalURL
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

        // #859: whatever it found is his, now. No checkboxes, no second pass.
        if case .review(let events, let note) = phase {
            importAll(events, note: note, into: context, today: today)
        }
    }

    private func waitForResults(sourceId: String, startedAt: Date, pollEvery: TimeInterval,
                                giveUpAfter: TimeInterval, sleep: (TimeInterval) async -> Void) async {
        var waited: TimeInterval = 0
        while waited <= giveUpAfter {
            // Results FIRST, always. #848: a run can write its results and exit between two polls, and
            // its answer is right there on disk. Checking liveness before reading would report a fast,
            // perfectly successful run as having produced nothing, which would be worse than the bug this
            // is fixing.
            if let results = readResults(sourceId), let verdict = results.verdict(for: sourceId) {
                readVerdict = verdict
                apply(LeadIntake.outcome(from: results, sourceId: sourceId, onlyForOrg: onlyForOrg))
                return
            }

            // #848: only now, and only if it is actually DEAD. The run's process has exited and it left
            // nothing for the source we asked about, so waiting is pointless and pretending otherwise is
            // a lie: Dan watched a live-looking counter tick to 2:59 on a run that had been over for
            // three minutes, and it would have counted to ten before blaming a timeout that never
            // happened. Still-alive and failed have to look different, and this is where they stopped to.
            if !isRunAlive() {
                let tail = RunLog.tail(8, from: RunLog.scoutExtractURL)
                phase = .problem(
                    "The reader finished without producing anything for that page, so nothing was read."
                    + " Try again, and if it keeps happening the page may be one it can't make sense of."
                    + (tail.isEmpty ? "" : "\n\nLast lines of the run log:\n\(tail)"))
                return
            }

            await sleep(pollEvery)
            waited += pollEvery
        }
        // Still beating, and out of patience. A DIFFERENT fault from the one above, with a different
        // fix, so it keeps its own sentence: this run really is hung.
        phase = .problem("The reader didn't finish in time. It may still be running; try again in a minute.")
    }

    private func apply(_ outcome: LeadIntake.Outcome) {
        switch outcome {
        case .found(let events, let note):
            phase = .review(events, note: [followedFromNote, monthsNote, note]
                .compactMap { $0 }.joined(separator: " "))
            readEvents = events
        case .foundButUnusable(let rejected, _):
            // NOT "no shows". The page had shows and none has a real venue, which means this source's
            // detail pages are not being read. Naming it is what makes it fixable.
            //
            // #995: except when it does NOT mean that. A page that publishes a city and no venue for
            // every show (Smoke Ring Quartet) loaded perfectly and is not hiding anything, so the
            // fetch diagnosis below would send Dan to debug something that is not broken. Two causes
            // that need two sentences, per the standing rule that a dead run and a working-but-empty
            // one must never read alike.
            // Whole sentences per case rather than assembled fragments: a lead is often ONE show, and
            // the joined version said "found 1 show, but none of them name a venue".
            switch (rejected.allSatisfy { $0.reason == .locationAsVenue }, rejected.count) {
            case (true, 1):
                phase = .problem("Found 1 show on that page, but it only gives the city it's in, never the venue, so I can't use it. Some pages never name a venue at all: that is the page being honest, not a fetch that failed.")
            case (true, let count):
                phase = .problem("Found \(count) shows on that page, but it only gives the city each one is in, never the venue, so I can't use them. Some pages never name a venue at all: that is the page being honest, not a fetch that failed.")
            case (false, 1):
                phase = .problem("Found 1 show on that page, but it doesn't name a venue, so I can't use it. That usually means the show's own page didn't load.")
            case (false, let count):
                phase = .problem("Found \(count) shows on that page, but none of them name a venue, so I can't use them. That usually means the show's own page didn't load.")
            }
        case .noUpcomingShows(let message), .notAnEventsPage(let message), .unreadable(let message),
             .incompleteExtraction(let message):
            phase = .problem(message)
        case .nothingCameBack:
            phase = .problem("The reader came back with nothing for that page. Try again, or paste the org's events page.")
        }
    }

    // Shows go in through the EXISTING classify/assemble/upsert chain, never a hand-built insert. That
    // is what keeps blocked dates, the #769 do-not-contact suppression, the #798 upcoming-only guard and
    // the #797 run identity applying to a hand-added lead exactly as they do to a scouted one. One
    // pipeline, not two, and a refused org cannot be smuggled in by hand. It matters more now that
    // nobody picks the shows (#859): whatever a page carries, the same gates decide what survives.
    //
    // With ONE stage held back (#826): no `feed:`, because a page Dan pasted is not a sweep of anybody's
    // calendar, so a stored show's absence from it is evidence of nothing. Before that guard, adding a
    // lead counted a miss against every upcoming Carnegie show, and two leads in a row marked his live
    // shows as disappeared and hid them from his queue.
    // #859: every show it found goes in. Dan does not pick them.
    //
    // The route is the SAME classify / assemble / upsert chain a scouted show takes, and that is what
    // makes auto-importing safe rather than reckless: blocked dates, the #769 do-not-contact suppression,
    // and the #798 upcoming-only guard all still apply. Nothing here can smuggle a refused org into his
    // queue, however many shows a page carries. `reconcilesFeed` stays off (#826): one pasted page is
    // not a sweep of anybody's calendar.
    @discardableResult
    private func importAll(_ events: [ExtractedEvent], note: String?, into context: ModelContext,
                           today: String) -> Int {
        guard !events.isEmpty else {
            phase = .added(0, note: note)
            return 0
        }
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let outcome = ScoutService.apply(events: events,
                                         clients: loaded.clients,
                                         history: LocalHistory.forMatching(existing: existing),
                                         // #901: the SAME calendar the scout uses, days off included. It
                                         // used to pass Downbeat's exported dates alone, so a lead Dan
                                         // pasted was judged against a different, smaller set of blocked
                                         // days than a scouted show was.
                                         blocked: ScoutService.blockedCalendar(
                                            export: (loaded.bookings, loaded.blockedDates), context: context),
                                         today: today, sourceIds: [WatchedSource.manualId],
                                         into: context)
        let added = outcome.inserted + outcome.updated

        // Recorded only now, not at submit: a link that failed to read is one he must be able to try
        // again. Only a link that actually produced something counts as handed over.
        if added > 0, let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            LeadSubmissions.record(url, in: defaults)
        }
        phase = .added(added, note: note)
        return added
    }

    // #859: the shows have already landed. This is the one decision left, and the only one the queue
    // cannot make for him: whether to keep watching this organization's calendar. Called from the screen
    // that tells him the shows arrived.
    func finishWatching(into context: ModelContext) {
        startWatchingIfConfirmed(in: context)
    }

    // #768: the calendar behind this lead joins the watchlist, so the next show these people put on is
    // found without Dan having to trip over it.
    //
    // The verdict is re-derived from the STORE here, not trusted from the sheet. That is deliberate: the
    // one mistake in this whole feature that cannot be taken back is re-adding an organization that asked
    // Dan to stop, and a pasted lead is exactly the route by which it would happen (he pastes a show he
    // liked, having forgotten they wrote to him last spring). A UI flag is not where that guarantee
    // belongs. If the fresh verdict is anything but "propose", nothing is written, whatever the sheet
    // said.
    private func startWatchingIfConfirmed(in context: ModelContext) {
        guard watchThisCalendar else { return }
        guard let pageURL = readPageURL, let pageVerdict = readVerdict else { return }

        let url = watchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = watchOrgName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !name.isEmpty, URL(string: url)?.host != nil else { return }

        let existing = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        // Checked against the page we READ, not against whatever Dan may have typed into the URL field:
        // the refusal and already-watching rules are about the organization, and a different spelling of
        // their address must not get past them.
        guard case .propose = WatchedSourceProposal.verdict(pageURL: pageURL, verdict: pageVerdict,
                                                            events: readEvents, existing: existing)
        else { return }
        // And once more against what he actually typed, so a hand-edited URL cannot land on an org that
        // is already watched or that refused him.
        guard case .propose = WatchedSourceProposal.verdict(pageURL: url, verdict: pageVerdict,
                                                            events: readEvents, existing: existing)
        else { return }

        context.insert(WatchedSource(sourceId: WatchedSource.newSourceId(for: url), orgName: name,
                                     listingsURL: url, kind: .html))
        try? context.save()
    }

    // #885: the sheet's confirmation line, out of AddLeadSheet's body and into the model that already
    // produced the count it is about.
    // #843: was two lines ("Added N shows to the queue." then "They're ranked and waiting with everything
    // else."), where "waiting … with everything else" only restated "to the queue". Now one line, which
    // also lets the zero case tell the truth: with nothing added, there is nothing to be "ranked and
    // waiting", so it says what actually happened instead of describing shows that are not there.
    static func addedNote(count: Int) -> String {
        guard count > 0 else { return "No new shows landed in the queue from that page." }
        return "Added \(Plural.count(count, "show")), ranked into your queue with everything else."
    }

    static func alreadyWatchingNote(orgName: String) -> String {
        "Already watching \(orgName)'s calendar, so their shows turn up on their own."
    }

    // A stable, safe id for the pinned page and the work-list. Derived from the URL so re-pasting the
    // same link reuses the same pin rather than littering the handoff folder.
    static func sourceId(for url: URL) -> String {
        ScoutPagePin.safeName("lead-" + (url.host ?? "page") + "-" + url.path)
    }
}
