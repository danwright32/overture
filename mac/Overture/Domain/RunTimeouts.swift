import Foundation

// #436: one documented home for every long action's "this has been going too long → stalled" window.
// The values legitimately differ by how long each run actually takes; they live together so the
// differences are deliberate and visible rather than scattered as magic numbers across services.
// Each surface routes its start time + the matching window through RunProgress.liveness.
enum RunTimeouts {
    // Prep: a detached Claude Code run that touches its marker ~every 60s; three missed touches reads
    // as dead. Matches the marker-stale guard that frees the run.
    static let prep: TimeInterval = 3 * 60

    // Reading show pages (#1824): the app's own render of each kept show's listing page, in process, before
    // the Prep run launches. Sized from the work rather than guessed: one page is at most a 25s WebKit load
    // plus its 2.5s settle (RenderedPage), four render at once (ShowListingReader.concurrency), so a batch
    // of twenty dead pages is about 140s of legitimate waiting. Three minutes leaves headroom for a bigger
    // launch without letting a genuinely wedged read sit there looking healthy.
    static let showListingRead: TimeInterval = 3 * 60

    // Reply classify / drafter handoff: the heaviest detached run (reads a thread, classifies, drafts),
    // so it gets the longest leash before the marker is considered stale.
    static let replyClassify: TimeInterval = 10 * 60

    // Reachability check (#1597): a DETACHED run that researches a contact for every show on the dates
    // Dan picked, following each organisation's own site until it finds an address or gives up. The first
    // real one took 7m51s for THREE shows, and because it shared `prep` above it was reported on screen as
    // stuck at 3:38 while working normally. Sized with the other heavy detached runs (replyClassify,
    // scoutExtract) rather than with Prep, whose ceiling was drawn for a different shape of work.
    //
    // This is the visible stall WARNING only. PrepQueueService.markerStaleAfter, which frees the
    // double-run guard, deliberately stays at `prep`: the runner touches its marker every 60s while alive,
    // so a long batch never goes stale, and lengthening that would only make a DEAD run look alive longer.
    static let reachabilityProbe: TimeInterval = 10 * 60

    // #1684: how long a run Dan STOPPED may stay on screen before the app calls it over.
    //
    // Sized from the runner's own behaviour, not guessed. `prep-run.sh` touches its marker every 60s
    // while working, and its heartbeat loop exits the moment it reads the cancel sentinel, so after a stop
    // nothing touches the marker again. 90 seconds is therefore one certain missed beat plus a margin: a
    // runner that has not yet noticed the sentinel keeps the run alive by touching the marker as usual,
    // and one that has stopped is recognised in a minute and a half rather than three minutes.
    //
    // Deliberately shorter than `prep` and deliberately NOT applied to a run nobody stopped, where the
    // silence carries no such promise and the longer window is what stops a slow batch being called dead.
    static let stoppedRunGrace: TimeInterval = 90

    // Reply drafter, per recipient: from "Draft a reply" stamped to a draft landing. Shorter than the
    // classify marker because Dan is watching this one and a stranded request should surface sooner.
    static let replyDraft: TimeInterval = 5 * 60

    // Scout: an in-process run. This is no longer the whole answer, and on its own it was WRONG: it was
    // sized when a manual sweep fetched at most 20 sources, and #1518 sent it through all 62, so a healthy
    // run passes three minutes routinely and every single scout ended by warning "looks stuck" moments
    // before it finished (#1530). It survives as the ceiling for a sweep that has not landed one source
    // yet (nothing has published a heartbeat, so elapsed time is all there is to go on); once sources are
    // landing, `scoutSourceStep` below is what judges the run.
    static let scout: TimeInterval = 3 * 60

    // Scout sweep, PER SOURCE (#1530): how long the sweep may go without landing a source before it reads
    // as wedged rather than merely long. Sized from the worst legitimate single source: a 30s HTTP fetch
    // (SourceFetcher), or a 25s WebKit render plus its 2.5s settle (RenderedPage) followed by an embed
    // hop's own request. That is about 90s of real work, so 120s leaves headroom without letting a truly
    // stuck sweep hide for long. Deliberately a per-source window and not a bigger total: a total goes
    // stale every time the watchlist grows, which is exactly how the old ceiling broke.
    static let scoutSourceStep: TimeInterval = 120

    // Scout extract (#799): a DETACHED run that reads several pinned listings pages and follows each
    // event's own detail page for the venue and exact date. Nothing like the in-process scout above,
    // whose comment ("an in-process run") is exactly why it must not reuse that ceiling: a legitimate
    // mid-batch run would be declared stalled and its marker freed, letting a second run start and
    // clobber the shared results file. Matched to replyClassify, the other heavy detached run.
    static let scoutExtract: TimeInterval = 10 * 60

    // Gmail OAuth connect: the visible "looks stuck" warning, set below GmailAuthManager's hard 90s
    // internal give-up (#1163) so Dan gets a heads-up to check the browser sign-in window before connect()
    // self-aborts and surfaces its actionable, retryable failure alert. The common dead-handoff case now
    // fails in ~2s via the pre-browser listener health check, so this only paces the rarer case that check
    // can't catch.
    static let gmailConnect: TimeInterval = 60

    // Outbound / reply send: a token refresh plus a single Gmail API call, both bounded at 30s
    // each by GmailNetworking's timeout (#468), so 60s covers the real worst case of a
    // well-behaved failure surfacing on its own. Past this, something is genuinely wedged (not
    // just slow), so it should offer a retry rather than an open-ended "Sending…".
    static let send: TimeInterval = 60

    // OmniFocus sync (#469): a handful of AppleScript Apple events, normally done in well under a
    // second. Generous leash since a slow OmniFocus launch or a stalled Automation permission
    // prompt can legitimately take a while, but a run past this reads as stuck.
    static let omniFocusSync: TimeInterval = 60
}
