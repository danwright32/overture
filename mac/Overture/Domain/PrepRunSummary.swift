import Foundation

// What a finished Prep run TELLS Dan, derived purely from its outcome.
//
// Extracted from RootView.ingestPrep (#876). It lived inside the SwiftUI body, which is precisely the
// shape #863 warns about: a rule computed in a view is a rule no test can reach, and two of those have
// already drifted here under a green suite. The sentences Dan actually reads are worth testing, so they
// live where a test can read them too.
enum PrepRunSummary {

    // In the order Dan should hear them: what he GOT, then what he KEPT, then what went wrong. A run's
    // good news first, so a summary is not read as a failure when it mostly worked.
    static func notes(for outcome: PrepImporter.Outcome) -> [String] {
        routineNotes(for: outcome) + concernNotes(for: outcome)
    }

    // The good-news tally: nothing for Dan to act on, and already visible in the queue itself (a drafted
    // show reads as drafted there too). Split out so a "does something need me" slot (the toolbar status
    // line) can drop this half and keep only concernNotes below.
    private static func routineNotes(for outcome: PrepImporter.Outcome) -> [String] {
        var notes: [String] = []
        if outcome.drafted > 0 { notes.append("\(outcome.drafted) drafted") }
        if outcome.skippedEdited > 0 { notes.append("\(outcome.skippedEdited) kept your edits") }
        // #2007: a show Dan prepped by hand. The run left it alone, and this says WHICH text it left
        // alone. "Kept your edits" would be a false description of an email no model ever wrote.
        if outcome.skippedHandWritten > 0 {
            notes.append("\(outcome.skippedHandWritten) left as you wrote them")
        }
        return notes
    }

    // What the run is telling him went differently than it should have.
    //
    // #1769: a reachability check shares this runner, this results file and this Outcome, so it shares
    // these sentences too rather than growing a second near-identical set that would drift. It opts OUT of
    // one of them: `includeRetryNote`. The shortfall sentence below promises an automatic retry, which is
    // TRUE for a Prep run (PrepQueueBuilder re-queues an undrafted prospect) and FALSE for a check
    // (nothing re-checks reachability by itself; Dan has to pick those dates again). Same fact, different
    // promise, so the check states it its own way in ReachabilityRunSummary and suppresses this one.
    // #2362: one refusal in this many attempts is where the refused-web-calls sentence starts speaking.
    // Named rather than inlined so the rule can be read as "a quarter" instead of as arithmetic.
    private static let refusalShareFloor = 4

    static func concernNotes(for outcome: PrepImporter.Outcome, includeRetryNote: Bool = true) -> [String] {
        var notes: [String] = []
        // #1721: a run that reached the web far more than expected. Said in WEB CALLS and shows, never in
        // dollars: Dan is on a Max plan and a dollar figure there is both meaningless and alarming.
        //
        // #2616: "web calls", not "web lookups", and the word matters more than a rename usually does. A
        // LOOKUP is one show's research, which is the unit the allowance is sized in, the unit the run
        // file stores as `lookups`, and the unit the "Check again" button prices at one. Calling these
        // "web lookups" put both units under one word on two screens Dan reads back to back, so a button
        // promising one lookup was followed three minutes later by a summary saying eighteen (L118). The
        // code has always called them `webCalls`; only the copy was out of step.
        //
        // Speaks ONLY when the count is complete AND over the allowance. An incomplete count makes no
        // claim in either direction, because a partial figure cannot show a run was fine and must not be
        // reported as its total. Silence on an ordinary run is the point: his measured normal is 5 to 9
        // lookups per show against a cap of 15, and an alert that fires on a routine run gets ignored
        // (L36).
        // #1864: when the shows named more people than there were shows, the sentence says how many. The
        // allowance is sized by the PARTIES a run pursued, and a cabaret room booking five-handers is two
        // shows and six people; reporting "more than expected" against a figure explained by the shows
        // alone reads as a run that spent three times what it should. Added only when the two differ, so
        // an ordinary run keeps the shorter sentence rather than growing a clause every time.
        if let web = outcome.webCalls, web.recorded, web.overCap == true, let total = web.total {
            let shows = web.items == 1 ? "1 show" : "\(web.items) shows"
            let parties = web.parties ?? web.items
            let people = parties > web.items ? ", \(parties) people to find" : ""
            // Always plural, deliberately: this line only speaks when the run went OVER its allowance,
            // and the smallest allowance is 15, so "1 web call" here is a branch nothing can reach. A
            // singular that cannot happen is a second spelling of the sentence for no reader (L90).
            notes.append("\(total) web calls for \(shows)\(people), more than expected")
        }
        // #1835: web calls the run asked for and was refused. Said separately from the count above because
        // they are the opposite fact: those calls reached nothing, so whatever the run reported about
        // those shows it found without them. Silent at zero and silent when the figure is absent (an old
        // results file, or an incomplete count), because absent means nobody looked, not none.
        //
        // #2362: it speaks only when the refusals are a MEANINGFUL SHARE of what the run reached for, and
        // it joins its two sentences with a colon.
        //
        // The share, because measured against Dan's own run (2026-08-09) the sentence was firing on a run
        // that worked: 338 web calls got through and 2 were refused, both of them a browser this runner is
        // deliberately never given. Neyla Pekarek got 13 allowed lookups and Danny Decker 10, and both
        // ended with a contact found. "That research never happened" was not true of that run, and a line
        // that fires on a run that went fine is one he learns to scroll past by the time one has not (L36).
        // A quarter is the bar: below it the refusals are noise beside what the run did reach, and at or
        // above it the sentence is describing the run rather than a footnote to it. A run refused at EVERY
        // attempt (no successful calls at all) is the case #1835 exists for and always clears the bar.
        //
        // The colon, because those are two complete sentences and a comma between them was the punctuation
        // Dan read on screen. The style rules forbid the dash that would otherwise do this job.
        //
        // It carries no ACTION, deliberately, and that is the answer to #2362's other half rather than an
        // omission: the browser is outside PREP_ALLOWED_TOOLS under a fail-closed mode, so the refusal is
        // `claude-run-scope.sh` doing its job and there is nothing for Dan to grant. Wording it as though
        // there were would name a step that changes nothing (L111).
        //
        // Needs a COMPLETE count, like the over-cap sentence above: a share cannot be computed from a
        // partial figure, and the incomplete path publishes `partialDenied` rather than `denied` anyway, so
        // nothing real is lost by requiring one.
        if let web = outcome.webCalls, web.recorded, let denied = web.denied, denied > 0,
           let total = web.total, denied * refusalShareFloor >= denied + total {
            let calls = denied == 1 ? "1 web call" : "\(denied) web calls"
            notes.append("\(calls) refused: that research never happened")
        }
        if !outcome.unmatchedKeys.isEmpty { notes.append("\(outcome.unmatchedKeys.count) didn't match") }
        // #876: shows the run was GIVEN and never answered. Left silent, they sit in "ready to prep" run
        // after run with no explanation, and a show the model chokes on every time is retried forever
        // with no symptom but a Prep count that never quite goes down.
        //
        // The promise is a real one, not a reassurance: an un-drafted prospect is re-queued by
        // PrepQueueBuilder, so "they'll be retried" states what the app will actually do next.
        if includeRetryNote, !outcome.missingKeys.isEmpty {
            notes.append(HandoffShortfall.retryNote(count: outcome.missingKeys.count))
        }
        if outcome.saveFailed { notes.append("couldn't save, try again") }
        // #754: the performer matcher ran against missing or unreadable reference data, so a past client
        // may have read as a cold lead. Silent here means invisible forever.
        if let matchDataWarning = outcome.matchDataWarning { notes.append(matchDataWarning) }
        return notes
    }

    // The two facts auditing the voice guidance file afterwards can add, shared by both callers below so
    // the two sentences exist in exactly one place each.
    private static func voiceGuidanceNotes(voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> [String] {
        var notes: [String] = []
        // #249: the distiller put a real name into the voice guidance, and that section is quarantined
        // so it can never feed a future draft. Dan has to know it happened.
        if voiceGuidanceLeaked { notes.append("voice guidance leaked a name, quarantined") }
        // #251: the run altered or dropped Dan's hand-written notes and they were restored from the
        // pre-run backup.
        if guidanceNotesRestored { notes.append("restored your guidance notes") }
        return notes
    }

    // #885: the rest of it. #876 extracted `notes(for:)` and left two more conditional notes, the
    // "Prep: " prefix and the join in RootView's body, so a test of this type could pass while the
    // sentence Dan actually reads was assembled somewhere it could not see.
    //
    // The two extra facts are not part of the run's Outcome (they come from auditing the voice guidance
    // file afterwards), so they are passed in rather than reached for.
    static func notes(for outcome: PrepImporter.Outcome,
                      voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> [String] {
        self.notes(for: outcome) + voiceGuidanceNotes(voiceGuidanceLeaked: voiceGuidanceLeaked,
                                                       guidanceNotesRestored: guidanceNotesRestored)
    }

    // Dan (2026-07-18): what belongs in the toolbar's shared status slot, which also carries an unattended scout's
    // warning. That slot is for "does something need me", not a running tally, so this drops
    // routineNotes ("N drafted", "N kept your edits": already visible in the queue, nothing to act on)
    // and keeps only concernNotes plus the two voice-guidance facts, every one of them the run telling
    // Dan something didn't go as expected. A run with nothing to report says nothing at all, rather than
    // showing an empty "Prep:" with a blank after it.
    static func attentionMessage(for outcome: PrepImporter.Outcome,
                                 voiceGuidanceLeaked: Bool, guidanceNotesRestored: Bool) -> String? {
        let notes = concernNotes(for: outcome)
            + voiceGuidanceNotes(voiceGuidanceLeaked: voiceGuidanceLeaked,
                                 guidanceNotesRestored: guidanceNotesRestored)
        guard !notes.isEmpty else { return nil }
        return "Prep: " + notes.joined(separator: " · ")
    }
}
