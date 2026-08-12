import Foundation

// The "reached out" pipeline (#217, per-recipient since #652): contacted RECIPIENTS Dan is still
// working, ordered by when he should next reach out to that specific contact. Combines the silent
// follow-up sequence (FollowUp) and the conversation reminder track (ConversationReminder), taking
// whichever is sooner. Returns nil: the recipient drops off the list, once outreach to them should
// stop: booked, lost, bounced, or nothing left scheduled.
enum ReachedOutQueue {
    // The soonest moment Dan should next reach out to this recipient, or nil if outreach to them has
    // stopped. A past date (overdue) is returned as-is so it sorts to the top of the list.
    //
    // #2118: answered through NextReachOut, the one rule a direct hire inquiry answers it through too.
    // The three tracks below are this entity's own; the fold, the out-of-play guard, and the dating of
    // work that has already arrived are shared, so the two kinds of row sharing one set of date headings
    // cannot drift apart again.
    static func nextReachOut(for r: Recipient, of p: Prospect, now: Date,
                             followUpConfig: FollowUpConfig = .init()) -> Date? {
        NextReachOut.date(isInPlay: isInPlay(r, of: p), now: now) {
            // #2397: the post-event prompt, which is all that is left of the conversation track. Its
            // trigger is the show's DATE, so it never depended on the state that used to key this.
            let promptDate = PostEventPrompt.nextPromptDate(for: r, of: p, now: now)
            // All three are `.scheduled`: each track has already decided which moment it is asking for.
            // #2118: a reply that has ARRIVED and not been answered is dated through the shared rule, the
            // same one a direct hire inquiry's reply gets, so both kinds of row sit under the same headings.
            return [.scheduled(nextFollowUp(for: r, now: now, config: followUpConfig)),
                    .scheduled(nextFormDecision(for: r, of: p, config: followUpConfig)),
                    .scheduled(promptDate),
                    r.hasUnhandledReply ? .waiting(since: r.replyArrivedAt) : .scheduled(nil),
                    // #2397: the FLOOR. A pitch that went out and has no recorded ending stays on this
                    // stage whatever else is or is not scheduled, because Dan's rule is that nothing is
                    // closed unless he closed it.
                    //
                    // Without this the row vanished in the gap between answering a reply (which used to be
                    // held open by the two-day "where does this stand" chase, retired with the states) and
                    // the show's own date. #2170's decision was explicit that answering clears the pressure
                    // WITHOUT removing the row, and a live pitch disappearing from the only surface that
                    // tracks it is the worse half of that pair.
                    //
                    // Dated at the show, which is the next moment anything actually happens for it, so an
                    // open pitch sorts among the rest by when it matters rather than by when it was sent.
                    .scheduled(EasternDate.date(from: p.performanceDate ?? ""))]
        }
    }

    // Is there anything left to reach out about on this contact at all? The inquiry side asks the same
    // question of itself in its own vocabulary; both hand the answer to the shared rule.
    static func isInPlay(_ r: Recipient, of p: Prospect) -> Bool {
        guard r.sentAt != nil else { return false }                 // only contacted recipients
        // #331 and #378, now asked through the one shared definition (Recipient.hasProvenOutreach).
        // Both guards said the same thing in two halves: a sent timestamp is not proof of anything, so
        // an emailed contact must carry a real address AND the Gmail message id every genuine send
        // stamps, or it is a staged/corrupt record that was never actually emailed.
        //
        // #1630 widened WHAT counts as proof, not how much is demanded: a form outreach Dan recorded by
        // hand has neither an address nor a message id and is still a real pitch. Spelled out here as
        // two literal guards it could only ever have meant email, and a show pitched through a form
        // would have matched no stage at all and vanished from the queue with the pitch still live.
        guard r.hasProvenOutreach else { return false }
        // #2225: the SHOW booked, so there is nothing left to reach out about on any of its contacts.
        // Both booking paths freeze only the contacts that were never emailed, so an already-emailed
        // contact kept its nil resolution, stayed in play, and the row went on counting down to a nudge
        // on a show that had already landed. FollowUp and ConversationReminder both skip a booked show
        // when building their own due lists, so the two surfaces disagreed about the same show on the
        // same night.
        //
        // Asked through `isBooked`, which folds the show's own outcome together with a booking recorded
        // on any one contact, because Dan records his by hand on the contact (L83).
        guard !p.isBooked else { return false }
        // #2396: the SHOW carries how it ended (#2394), and an ended show has nothing left to reach out
        // about whatever its contacts still say. This is what lets the contact-level mirror #2395 left in
        // `recordOutcome` come out: the row leaves because the one field says the show is over, rather than
        // because a resolution was copied onto every contact to make the old readers agree.
        guard p.showOutcome == nil else { return false }
        return r.standing.isInPlay
    }

    // Contacted recipients with outreach still active, each paired with its own next-reach-out date,
    // soonest first. The view formats the date with timingLabel.
    static func activeWithDates(from prospects: [Prospect], now: Date,
                                followUpConfig: FollowUpConfig = .init()) -> [(prospect: Prospect, recipient: Recipient, next: Date)] {
        prospects
            .compactMap { p -> (prospect: Prospect, recipient: Recipient, next: Date)? in
                // #2126: built from the contacts that still have a reach-out date, so a resolved first
                // contact cannot take a live colleague's whole row down with it.
                let live = p.recipients.compactMap { r -> (recipient: Recipient, next: Date)? in
                    nextReachOut(for: r, of: p, now: now, followUpConfig: followUpConfig)
                        .map { (recipient: r, next: $0) }
                }
                guard !live.isEmpty else { return nil }
                // #2396: ONE row per SHOW. Dan judges shows, not contacts: "I really don't care about
                // contact level outcomes. All I care about is the event level." It used to be one row per
                // EMAIL (#2033), which was already a fold, and this finishes it: several emails about one
                // event are still one decision.
                //
                // The row still speaks for a PERSON, because answering has to go back to somebody. Whoever
                // replied wins, since that is the person Dan is answering and the row names them; with
                // nobody having replied there is no such person, so it speaks for the contact due soonest,
                // which is the one the row's own action is about.
                let representative = live.first(where: { $0.recipient.replied }) ?? live.min { $0.next < $1.next }
                guard let representative else { return nil }
                // The DATE is the soonest across the whole show, not the representative's own, so a show
                // cannot sit lower in the list than its most urgent contact deserves.
                guard let soonest = live.map(\.next).min() else { return nil }
                return (prospect: p, recipient: representative.recipient, next: soonest)
            }
            .sorted { $0.next < $1.next }
    }

    // Contacted recipients with outreach still active, soonest next-reach-out first.
    static func active(from prospects: [Prospect], now: Date,
                       followUpConfig: FollowUpConfig = .init()) -> [(prospect: Prospect, recipient: Recipient)] {
        activeWithDates(from: prospects, now: now, followUpConfig: followUpConfig)
            .map { (prospect: $0.prospect, recipient: $0.recipient) }
    }

    // #1194: how many SHOWS Dan has active outreach on, counting each show once no matter how many of
    // its contacts he has pitched. #2396: the list under the pill counts shows too now, so this and the row
    // count are the same quantity rather than two that needed reconciling (#1232's note, now removed).
    static func showCount(from prospects: [Prospect], now: Date,
                          followUpConfig: FollowUpConfig = .init()) -> Int {
        Set(activeWithDates(from: prospects, now: now, followUpConfig: followUpConfig)
            .map { $0.prospect.naturalKey }).count
    }

    // #2550: the moment something is actually OWED on this row, which is not what the row sorts by.
    //
    // `nextReachOut` above folds in #2397's floor, and the floor is a sorting anchor: it exists so a live
    // pitch never falls off the stage, and it asserts nothing about anything being due. Read as a due date
    // it told Dan to reach out on every show's own night, beside a row with no send control on it at all.
    //
    // The three clocks here are the same three, minus the floor, and each is asked through the SAME
    // predicate the row's control is asked through, so the text and the button cannot disagree (L16):
    // `FollowUp.nextDue` with `isAwaitingNudge` is what `ReachedOutAction` reads for the nudge, and
    // `PostEventPrompt.nextPromptDate` is what it reads for the post-event track.
    //
    // Nil means nothing is owed. That is a real state, not a missing answer: a spent pitch on a show that
    // has not happened yet is held on the stage by the floor alone, with nothing left to count down to.
    static func nextActionableMoment(for r: Recipient, of p: Prospect, now: Date,
                                     followUpConfig: FollowUpConfig = .init()) -> Date? {
        let nudge = FollowUp.nextDue(eligible: FollowUp.isAwaitingNudge(r, in: p), sentAt: r.sentAt,
                                     lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                     remindedAt: r.nudgeRemindedAt, config: followUpConfig)
        let candidates = [nudge,
                          nextFormDecision(for: r, of: p, config: followUpConfig),
                          PostEventPrompt.nextPromptDate(for: r, of: p, now: now),
                          r.hasUnhandledReply ? r.replyArrivedAt : nil]
        return candidates.compactMap { $0 }.min()
    }

    // What the row's timing slot says, decided from what is OWED rather than from the sort key (#2550).
    // One entry point, so a caller cannot reassemble the pieces into the disagreement this replaces.
    static func timingLabel(for r: Recipient, of p: Prospect, now: Date, today: String,
                            followUpConfig: FollowUpConfig = .init()) -> String {
        // #2169: a dated form pitch names the NIGHT, whatever its clock says, because there is no send to
        // count down to. Unchanged, and asked first so the rule stays in one place.
        if r.outreachChannel == .contactForm, let day = p.performanceDate,
           EasternDate.date(from: day) != nil {
            return formNightLabel(eventDay: day, today: today)
        }
        guard let next = nextActionableMoment(for: r, of: p, now: now, followUpConfig: followUpConfig) else {
            return heldOpenLabel
        }
        return timingLabel(next: next, now: now, channel: r.outreachChannel,
                           eventDay: p.performanceDate, today: today)
    }

    // #2550: the row is open, nothing is owed, and the floor is what is keeping it on the stage. Says what
    // it is waiting on rather than counting down to a moment nothing happens at, and deliberately does not
    // name the date: the row carries the show's own date beside the group name (#2551), and a slot that
    // repeated it would be two lines saying one thing (#843).
    //
    // Only reachable BEFORE the show: once it has been and gone the post-event prompt is owed, so this
    // never has to describe a night already past.
    static let heldOpenLabel = "Nothing due before the show"

    // Plain-language "when to next reach out", shown on each reached-out row (#223). Anything due
    // now or overdue reads "Reach out now"; future dates read "in N day(s)" (whole days, rounded up).
    // #1630: a form pitch's due label asks for a DECISION, because there is nothing left to send. Same
    // slot, same threshold, one honest difference at the moment it comes due; the waiting text is
    // identical either way, since a wait is a wait.
    //
    // #2169: a DATED form pitch answers from the night instead, through formNightLabel below. Kept as one
    // entry point rather than letting the view choose, so the row cannot end up asking two different
    // questions about the same clock. The old wording survives only for a form pitch on an undated show,
    // which is the one case with no night to name.
    static func timingLabel(next: Date, now: Date, channel: OutreachChannel = .email,
                            eventDay: String? = nil, today: String = EasternDate.today()) -> String {
        if channel == .contactForm, let eventDay, EasternDate.date(from: eventDay) != nil {
            return formNightLabel(eventDay: eventDay, today: today)
        }
        let seconds = next.timeIntervalSince(now)
        if seconds <= 0 { return channel == .contactForm ? "Say what happened" : "Reach out now" }
        return daysAhead(Int((seconds / 86_400).rounded(.up)))
    }

    // #2169: a form row's timing slot names the NIGHT, because that is what its clock is now set to.
    //
    // Dan's rule, 2026-08-06: "The due date should actually just be the date of the event since I won't
    // send a follow up if it's a form." Which also makes the question answerable exactly when it is
    // asked: before the night he has nothing to report, and after it he knows.
    //
    // It deliberately does NOT say "Say what happened", even when due. The state control sitting beside
    // it already reads "Set a state", and one instruction printed twice is the defect #2168 guards
    // against. The slot says WHEN, the control says WHAT TO DO, and the control carries the urgency.
    //
    // Counted in whole Eastern calendar days through the one shared helper rather than by dividing an
    // interval by 24 hours: on the two clock-change days a day is 23 or 25 hours long, so raw division
    // is a day out twice a year in the one line whose whole job is saying when (L39).
    static func formNightLabel(eventDay: String?, today: String) -> String {
        guard let eventDay, let days = EasternDate.daysUntil(from: today, to: eventDay) else {
            // Never invented. "Date to be confirmed" is a normal listing state, and a fabricated night
            // would send Dan looking for a show on a date nobody published.
            return "date unknown"
        }
        switch days {
        case 0: return "tonight"
        case -1: return "yesterday"
        case let ahead where ahead > 0: return daysAhead(ahead)
        default: return "\(-days) days ago"
        }
    }

    // "in 1 day" / "in N days", in one place. Both the email countdown and the form row's night say it,
    // and two copies of a sentence drift (#843): the copy inventory flagged the second one the moment it
    // appeared, which is exactly what that inventory is for.
    private static func daysAhead(_ days: Int) -> String {
        days == 1 ? "in 1 day" : "in \(days) days"
    }

    // #2169: when a form pitch comes due, which is the night itself.
    //
    // From the night's Eastern midnight rather than the morning after, so the row is asking on the day
    // Dan is there. Nil for an undated show, and the caller must then keep its old clock rather than
    // dropping the row: a record that matches no view is gone from the product while still in the data
    // (L45).
    static func formDecisionDate(eventDay: String?) -> Date? {
        guard let eventDay, !eventDay.isEmpty else { return nil }
        return EasternDate.date(from: eventDay)
    }

    // The same "overdue or now" threshold timingLabel's "Reach out now" case uses (#661), so a row's
    // "Send a follow-up" action and its timing text can never disagree about whether it's due yet.
    static func isDueNow(next: Date, now: Date) -> Bool {
        next <= now
    }

    // #2550: whether the ROW is urgent, which is the same question the slot's own text answers. The row
    // paints its timing text rust and fills its Answer button on this, and while it was asked of the sort
    // key every open pitch went rust on its own night with nothing owed on it. Nothing owed is not urgent.
    static func isDueNow(for r: Recipient, of p: Prospect, now: Date,
                         followUpConfig: FollowUpConfig = .init()) -> Bool {
        guard let next = nextActionableMoment(for: r, of: p, now: now, followUpConfig: followUpConfig)
        else { return false }
        return isDueNow(next: next, now: now)
    }

    // The next silent nudge for a still-silent recipient, mirroring FollowUp.dueRecipients' own
    // eligibility check (r.isAwaitingFollowUp) rather than reimplementing it: paced by gapDays from
    // the last touch, up to maxFollowUps; nothing once this recipient replied/resolved or the cap is
    // reached. Closed recipients are already excluded by the standing.isInPlay guard in isInPlay above.
    // #1630: a form outreach's own clock. It is a DECIDE date, not a nudge date: Overture cannot email
    // this contact and cannot see a reply to them, so the only thing left that moves the show forward is
    // Dan saying what happened. Paced by the same gap as a first email follow-up (his call, 2026-07-28)
    // so the product holds one pacing number rather than two. Unlike the nudge track there is no cap: a
    // capped decide clock would simply stop asking and leave the show sitting in Reached out forever.
    // #2169: the clock is the NIGHT. Dan, 2026-08-06: "The due date should actually just be the date of
    // the event since I won't send a follow up if it's a form." Which is also when the question becomes
    // answerable, rather than an arbitrary gap after a pitch he cannot chase.
    //
    // The pitched-plus-gap clock survives ONLY for a show with no date. Returning nil there would drop the
    // row out of the reached-out queue entirely, and a record that matches no view is gone from the
    // product while still sitting in the data (L45).
    private static func nextFormDecision(for r: Recipient, of p: Prospect,
                                         config: FollowUpConfig) -> Date? {
        guard r.outreachChannel == .contactForm, let recordedAt = r.formOutreachRecordedAt else { return nil }
        if let night = formDecisionDate(eventDay: p.performanceDate) { return night }
        return recordedAt.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
    }

    private static func nextFollowUp(for r: Recipient, now: Date, config: FollowUpConfig) -> Date? {
        guard let sentAt = r.sentAt else { return nil }
        guard r.isAwaitingFollowUp else { return nil }
        guard r.followUpCount < config.maxFollowUps else { return nil }
        let lastTouch = r.lastFollowUpAt ?? sentAt
        return lastTouch.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
    }
}
