# Copy inventory

Every sentence Overture can say to Dan: **1482 sentences**.

Generated, do not edit by hand. The test suite regenerates it (`mac/scripts/run-tests-locked.sh`)
and fails if it is stale, so a PR that changes what the app says shows the change here, in the
words Dan will read rather than as a line of Swift.

What is in it: a string literal carrying two or more words, from anywhere in `mac/Overture`.
What is not, and why:

- **One-word labels** (`Text("Sources")`). At this altitude a single word cannot be told apart
  from an SF Symbol, a defaults key or an identifier, and letting those in would bury the
  sentences under tokens nobody reads.
- **Nothing, if it is written as two literals joined with `+`.** Those ARE joined here, into the
  one sentence the running app says (#3155). What is still only part of what Dan reads is a
  sentence carrying a VALUE: 539 of the 1482 below hold a
  `\(...)` where a number or a name goes, so what is printed is the template. They are counted
  here rather than listed again, because the hole is visible in the line itself; what was missing
  was any statement of how much of this document is templates.
- **DEBUG-only copy**, which is compiled out of the app Dan runs.
- **Marked regions**, listed below with the reason, at the source.

## Excluded at the source

- `App/PrepRunArchive.swift`: archive.log is a diagnostic record, not the app's voice on screen
- `App/PrepRunArchive.swift`: archive.log is a diagnostic record, not the app's voice on screen
- `App/StoreBackup.swift`: backup.log is a diagnostic record, not the app's voice on screen
- `App/StoreSchemaGuard.swift`: sqlite's own error text, for backup.log, never shown on screen
- `App/StoreShrinkCheck.swift`: SQL, not a sentence Overture says to Dan
- `App/UpdateCommandFile.swift`: a shell script for Terminal, not Overture's voice to Dan (#915)
- `Domain/CatchAllFitReasonMigration.swift`: the retired sentence, named only so this pass can find and clear it
- `Domain/DebugStaging.swift`: a debug-only stand-in draft body (contact-facing email copy, not app voice)
- `Domain/DebugStaging.swift`: a debug-only stand-in draft body (contact-facing email copy, not app voice)
- `Domain/DraftCheck.swift`: draft lint needles: phrases the linter HUNTS FOR, never words it says (#915)
- `Domain/DraftCheck.swift`: cadence lint needles: connector and subordinator words MATCHED in a draft, never words Overture says (#2807)
- `Domain/DraftCheck.swift`: Words MATCHED in a draft, never shown to Dan (#1887)
- `Domain/DriftedRunMerge.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/EventDateInDraft.swift`: date-shape patterns: what the check HUNTS FOR, never words it says
- `Domain/EventLocationFill.swift`: A location VALUE written into a data field, never a sentence Dan reads (#2378)
- `Domain/EventPlace.swift`: Place names the resolver MATCHES against, never says: Dan reads a verdict, not this data (#970)
- `Domain/EventPlace.swift`: A location VALUE written into a data field, never a sentence Dan reads (#2378)
- `Domain/FeedMovementLog.swift`: a machine-parsed diagnostic log line for #913, never shown to Dan
- `Domain/FollowUp.swift`: outbound-email: a recipient reads this, not Dan (#915, #2650)
- `Domain/LaunchMigrations.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/ListingOrganiser.swift`: parser tokens matched against ticketing pages, never Overture's voice
- `Domain/NaturalKeyVenueMigration.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/OmniFocusFailureKind.swift`: the enum case's own name, as `"\(error)"` renders it. Read, never said.
- `Domain/OmniFocusFailureKind.swift`: AppleScript's own wordings, kept only for failures RECORDED BEFORE
- `Domain/OrgReachabilityAnswer.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Domain/OutboundSignature.swift`: outbound-email: the sign-off a recipient reads, not Overture's own voice to Dan (#915, #2650)
- `Domain/ProducerGate.swift`: Words matched inside an organisation's own name, never said to Dan (#1749)
- `Domain/ProducerShapedName.swift`: parser tokens matched against a ticketing feed, never Overture's voice
- `Domain/ProducerShapedName.swift`: parser tokens matched against a listing page, never Overture's voice
- `Domain/ProducerShapedName.swift`: parser tokens matched against a listing page, never Overture's voice
- `Domain/ReplyCandidateMatch.swift`: the reasons behind a score, for diagnosing a wrong proposal.
- `Domain/RunBoundaryViolations.swift`: a filename and a phrase MATCHED in a log, not sentences Overture says
- `Domain/SameNightTitleVariantMerge.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/SendIdentity.swift`: an RFC822 sender identity (name + address), not the app's own voice
- `Domain/ShowOutcomeBackfill.swift`: agent log, not a sentence Overture says to Dan (#915)
- `Domain/StageOverlap.swift`: test failure text, read by whoever broke a rule, never said to Dan (#915)
- `Domain/VenuePlaces.swift`: Venue and place names this table MATCHES and stores, not the app's voice: 79 city strings would bury the inventory a person reads cold (#1744)
- `Domain/VenueShootHistory.swift`: A venue name looked UP in the table, never shown to Dan (#1887)
- `Domain/VenueShootHistory.swift`: Words MATCHED in Dan's own calendar titles, never shown to him (#1887)
- `Integration/AppleScriptOmniFocusClient.swift`: AppleScript source and OmniFocus tag names: OmniFocus reads these, not Dan (#915)
- `Integration/ConfirmProposedConversation.swift`: Google API URLs and an HTTP header, not sentences Overture says (#915)
- `Integration/ConfirmProposedConversation.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/ConfirmProposedConversation.swift`: an HTTP header, not a sentence (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log to a file, not the app's own voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic + a system activity reason, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailAuthManager.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/GmailMessage.swift`: a light card surface for the outbound email's own HTML, not Overture's voice (#1203)
- `Integration/GmailMessage.swift`: RFC822 headers: a mail server reads these, not Dan (#915)
- `Integration/GmailReplyChecker.swift`: the HTTP Authorization header Google reads, not a sentence
- `Integration/GmailReplySearch.swift`: a Gmail search query, not a sentence Overture says (#915)
- `Integration/GmailReplySearch.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailReplySearch.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailReplySearch.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailReplySearch.swift`: Google API URLs and an HTTP header, not sentences Overture says (#915)
- `Integration/GmailSender.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSender.swift`: the HTTP Authorization header Google reads, not a sentence
- `Integration/GmailSender.swift`: a Google API URL and developer diagnostic reasons, not the app's own voice (#915)
- `Integration/GmailSignatureHealth.swift`: developer diagnostic reason (log/badge detail), not the app's own voice (#915)
- `Integration/GmailSignatureHealth.swift`: developer diagnostic reason (log/badge detail), not the app's own voice (#915)
- `Integration/GmailSignatureService.swift`: the HTTP Authorization header Google reads, not a sentence
- `Integration/GmailSignatureService.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSignatureService.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSignatureStore.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailThreadHeaders.swift`: RFC822 header names in a Google API URL, not sentences Overture says (#915)
- `Integration/GmailThreadingRepair.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailThreadingRepair.swift`: a Google API URL and an HTTP header, not sentences Overture says (#915)
- `Integration/InquiryConversationAttach.swift`: an HTTP header, not a sentence (#915)
- `Integration/LoopbackListener.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/LoopbackListener.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/OperaAmericaCalendar.swift`: synthesized source HTML the
- `Integration/OperaAmericaCalendar.swift`: an outbound API request body, not the app's voice (#915)
- `Integration/OvationTixCalendar.swift`: synthesized source HTML the extractor reads, not the app's voice (#915)
- `Integration/OvationTixCalendar.swift`: an outbound API request scoped by a header, not the app's voice (#915)
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/ReplyProposalSweep.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/TicketTailor.swift`: an outbound API request's headers, not the app's voice (#915)
- `Integration/TicketTailorCalendar.swift`: an outbound fetch's headers for the venue page hop, not the app's voice (#915)
- `Integration/TicketTailorCalendar.swift`: a search marker for the widget's JS assignment, not the app's voice (#915)
- `Integration/VenueTixCalendar.swift`: synthesized source HTML the extractor reads, not the app's voice (#915)
- `Integration/VenueTixCalendar.swift`: an outbound API request scoped by Origin, not the app's voice (#915)
- `UI/DraftSignaturePreview.swift`: renders the outbound email's own HTML (body + Gmail signature), not Overture's voice (#1203)
- `UI/DraftSignaturePreview.swift`: browser-side measuring script, not a sentence Overture says to Dan (#915)

## The same sentence, said in more than one place (55)

Two copies of a sentence will drift. #843 owns fixing these.

- " Confirm you've checked it and it's fine to send as-is."
  - `Domain/DraftReviewNotes.swift`
  - `Domain/DraftReviewNotes.swift`
- " a one-off hunt."
  - `Domain/ProbeSelection.swift`
  - `Domain/ProbeSelection.swift`
- "## Observed tendencies"
  - `Domain/VoiceGuidanceGuard.swift`
  - `Domain/VoiceNotesProtector.swift`
- "Block these days"
  - `UI/BlockDaysSheet.swift`
  - `UI/DaysOffView.swift`
  - `UI/DaysOffView.swift`
- "Carnegie Hall"
  - `Domain/WatchedSourceBackfill.swift`
  - `Integration/ScoutService.swift`
  - `UI/FollowUpsView.swift`
- "Closed (not interested)"
  - `Domain/PerformanceStatus.swift`
  - `UI/QueueView+Model.swift`
- "Closed (not now)"
  - `Domain/PerformanceStatus.swift`
  - `UI/QueueView+Model.swift`
- "Confirm booking"
  - `UI/ProspectRowView.swift`
  - `UI/ProspectRowView.swift`
- "Connect Gmail"
  - `App/RootView.swift`
  - `Domain/GmailReconnectCopy.swift`
  - `UI/OnboardingView.swift`
- "Contact form"
  - `Domain/Inquiry.swift`
  - `UI/DraftReviewView.swift`
- "Date to be confirmed"
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
- "Days off"
  - `Domain/DaysOffAttention.swift`
  - `UI/DaysOffView.swift`
- "Delivery delayed"
  - `UI/DraftReviewView.swift`
  - `UI/QueueView.swift`
- "Find contacts only"
  - `App/RootView.swift`
  - `UI/DraftReviewView.swift`
- "Gmail access expired or was revoked. Click Connect Gmail to reconnect."
  - `Integration/GmailAuthManager.swift`
  - `Integration/GmailSender.swift`
- "I turned them down"
  - `Domain/ShowOutcome.swift`
  - `Domain/ShowOutcome.swift`
- "It leaves your queue, filed as \(reason.label)."
  - `Domain/BulkDismiss.swift`
  - `Domain/BulkDismiss.swift`
- "Never heard back"
  - `Domain/ShowOutcome.swift`
  - `UI/QueueView+Model.swift`
- "Not a booking"
  - `UI/ProspectRowView.swift`
  - `UI/ProspectRowView.swift`
- "Not a real reply"
  - `UI/DraftReviewView.swift`
  - `UI/DraftReviewView.swift`
- "Not happening"
  - `Domain/CancelledShootCopy.swift`
  - `Domain/CancelledShootCopy.swift`
- "Not now"
  - `Domain/BuildFreshnessPanel.swift`
  - `UI/BlockDaysSheet.swift`
- "Nothing matches this filter"
  - `Domain/EmptyState.swift`
  - `Domain/EmptyState.swift`
- "Reached out"
  - `App/ActionFeedback.swift`
  - `Domain/AgentRoster.swift`
- "Redraft and find contacts"
  - `App/RootView.swift`
  - `UI/DraftReviewView.swift`
- "Redraft only"
  - `App/RootView.swift`
  - `UI/DraftReviewView.swift`
- "Review and send"
  - `UI/FollowUpsView.swift`
  - `UI/SendConfirmSheet.swift`
- "Send Anyway"
  - `UI/DraftReviewView.swift`
  - `UI/DraftReviewView.swift`
- "Send anyway?"
  - `UI/DraftReviewView.swift`
  - `UI/DraftReviewView.swift`
- "Send issues"
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
- "Set up Overture"
  - `App/AppDelegate.swift`
  - `UI/OnboardingView.swift`
- "Skipped towns"
  - `App/RootView.swift`
  - `UI/ExcludedTownsView.swift`
- "Source listing"
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
- "Sync now"
  - `App/RootView.swift`
  - `Domain/AppNotice.swift`
- "Their events or season page"
  - `UI/SourceFixConfirmActions.swift`
  - `UI/SourcesView.swift`
- "They all leave your queue, filed as \(reason.label)."
  - `Domain/BulkDismiss.swift`
  - `Domain/BulkDismiss.swift`
- "This show"
  - `Domain/PrepLaunchCopy.swift`
  - `Domain/SelfBookingConflict.swift`
- "Try again"
  - `App/RootView.swift`
  - `Domain/ProposedConversation.swift`
  - `Domain/Reachability.swift`
- "View in Archive"
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
- "Voice guidance"
  - `App/RootView.swift`
  - `UI/VoiceGuidanceView.swift`
- "Went by"
  - `Domain/ArchiveStatus.swift`
  - `Domain/ShowOutcome.swift`
  - `UI/ProspectRowView.swift`
- "What converts"
  - `App/RootView.swift`
  - `UI/OutcomePatternsView.swift`
- "Written by you"
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
- "\(city), \(state)"
  - `Domain/EventLocationFill.swift`
  - `Domain/EventLocationFill.swift`
- "\(explanation)\n\n\(detail)"
  - `Domain/AppNotice.swift`
  - `Domain/AppNotice.swift`
  - `Domain/AppNotice.swift`
- "\(min(progress.completed, progress.total)) of \(progress.total)"
  - `Domain/ReplyClassifyProgress.swift`
  - `Domain/ScoutExtractProgress.swift`
- "\(placed) shows"
  - `UI/SourcesView.swift`
  - `UI/SourcesView.swift`
- "\(s.dateCount) dates"
  - `Domain/ProbeSelection.swift`
  - `Domain/ProbeSelection.swift`
- "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
- "\n\nLast lines of the run log:\n\(tail)"
  - `Domain/DetachedRunOutcome.swift`
  - `UI/LeadIntakeModel.swift`
- "another show"
  - `Domain/SelfBookingConflict.swift`
  - `Domain/SelfBookingConflict.swift`
  - `Domain/SelfBookingConflict.swift`
- "no contact"
  - `Domain/FollowUp.swift`
  - `Domain/ReplyIdentity.swift`
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
- "show is"
  - `Domain/ProbeSelection.swift`
  - `Domain/ProbeSelection.swift`
- "shows are"
  - `Domain/ProbeSelection.swift`
  - `Domain/ProbeSelection.swift`
- "the contact"
  - `App/ActionFeedback.swift`
  - `App/ActionFeedback.swift`
  - `App/ActionFeedback.swift`
  - `Domain/OmniFocusSync.swift`

## Every sentence

" (\(skippedCount) skipped: already pending or re-prepped recently)"
    `App/ActionFeedback.swift`
" Confirm you've checked it and it's fine to send as-is."
    `Domain/DraftReviewNotes.swift`
" It has about \(PrepStatus.duration(seconds: remaining)) left. Press Run scout again once it finishes."
    `Domain/ScoutStartGate.swift`
" Left \(handWrittenSpared) emails you wrote yourself alone; re-prep those shows on their own cards if you want them replaced."
    `App/ActionFeedback.swift`
" Left the email you wrote yourself alone; re-prep that show on its own card if you want it replaced."
    `App/ActionFeedback.swift`
" One other match is flagged the same way."
    `Domain/PossibleMatchFanOut.swift`
" Press Run scout again once the reading finishes."
    `Domain/ScoutStartGate.swift`
" Their email matches the address on file."
    `Domain/HistoryMatch.swift`
" \(others) other matches are flagged the same way."
    `Domain/PossibleMatchFanOut.swift`
" a one-off hunt."
    `Domain/ProbeSelection.swift`
" and find new contacts"
    `App/ActionFeedback.swift`
" checked recently and are not looked up again."
    `Domain/ProbeSelection.swift`
" you picked."
    `Domain/ProbeSelection.swift`
" · \(tally.booked) booked"
    `Domain/SourceYield.swift`
" · \(tally.sent) sent"
    `Domain/SourceYield.swift`
"## Dan's notes"
    `Domain/VoiceNotesProtector.swift`
"## Dan's notes (authoritative, never auto-edited)\n\nWrite any voice guidance you want every draft to follow. This section is yours; Prep runs never change it.\n\n## Observed tendencies (auto-generated; regenerated each run)\n\n_Nothing learned yet. This fills in after you've edited and sent some drafts._"
    `Domain/VoiceGuidanceStore.swift`
"## Observed tendencies"
    `Domain/VoiceGuidanceGuard.swift`
    `Domain/VoiceNotesProtector.swift`
"'\(scriptPath)' >/dev/null 2>&1 &"
    `Integration/DetachedRunner.swift`
", \(parties) people to find"
    `Domain/PrepRunSummary.swift`
", so a performer who is a past client may have read as cold"
    `Persistence/PrepImporter.swift`
"1 client set aside"
    `Domain/ClientCoverage.swift`
"1 contact named a way in and gave none, and the run never once said it found no route"
    `Domain/RunInstructionCompliance.swift`
"1 later night"
    `App/ActionFeedback.swift`
"1 more show stored a reason like these, but its own answer says it can be reached, so its card never says it."
    `UI/EmptyAnswerSection.swift`
"1 named producer answers for several of them; \(s.performerHuntCount) "
    `Domain/ProbeSelection.swift`
"1 new show waiting for you"
    `Domain/SourceYield.swift`
"1 of \(requested) shows never got an answer and is still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"1 of them is a run whose other nights already have their own cards, so it is closed as a duplicate"
    `App/ActionFeedback.swift`
"1 of them went through an earlier check and never got an answer."
    `Domain/ProbeSelection.swift`
"1 of those is a show that names its producing organisation."
    `UI/EmptyAnswerSection.swift`
"1 run was left alone: Overture could not check whether its next night is free"
    `App/ActionFeedback.swift`
"1 show has been checked and left with nobody to write to. What the check claimed:"
    `UI/EmptyAnswerSection.swift`
"1 show on \(dateLabel) has no genre read. Set it before dismissing the night."
    `Domain/GenreGate.swift`
"1 show stored a reason with no answer recorded beside it at all, which is a fault in the check rather than a finding about the show."
    `UI/EmptyAnswerSection.swift`
"1 show was recorded as having no email to write to while it held a way in. Overture has since corrected it:"
    `UI/WrittenOffBacklogSection.swift`
"1 source needs"
    `Domain/SourceAttention.swift`
"1 venue is still waiting to be checked."
    `UI/ScoutSummaryView.swift`
"1 web call"
    `Domain/PrepRunSummary.swift`
"1px solid rgba(0,0,0,0.12)"
    `Domain/PreviewBackground.swift`
"1px solid rgba(255,255,255,0.18)"
    `Domain/PreviewBackground.swift`
"A Gmail connection is already in progress. Finish it in the browser."
    `Integration/GmailAuthManager.swift`
"A Prep run is already in progress. \(org) is queued to re-prep on the next run"
    `App/ActionFeedback.swift`
"A booking was detected that needs your confirmation. Tap to confirm or dismiss."
    `UI/ProspectRowView.swift`
"A check found a profile carrying the right name and nothing in its bio or recent posts tying it to this show, so who is on the end of it is not settled. If you recognise the handle below, the DM is yours to send."
    `Domain/Reachability.swift`
"A check has already run over this show once and never got an answer for it."
    `Domain/ProbeSelection.swift`
"A check missed this show"
    `Domain/Reachability.swift`
"A check ran and got no further than this act's social profile, which needs a login. Their own site may still publish an address, so of all the shows with no contact this is the one most likely to give one up on another check."
    `Domain/Reachability.swift`
"A check said there was a way to reach these people and then did not give one, so there was nothing to keep. That is the check falling short rather than the show being hard to reach, so another check is worth more here than a search by hand."
    `Domain/Reachability.swift`
"A check worked out who is putting this on and found no way to reach any of them, so it kept none of them. The listing still names them, and a search by name often turns up an address the check missed."
    `Domain/Reachability.swift`
"A contact on this show is held back by a check (a venue guess, a press address, a duplicate, the salutation, or the draft lint). Look at it below: dismissing the check releases the email."
    `UI/DraftReviewView.swift`
"A hard bounce means the mail was rejected outright, so the show has stopped being chased and nobody has seen the pitch. Open the show to fix the address and pitch again. If the address is fine and the bounce was wrong, Not really bounced on the contact clears it."
    `Domain/AppNotice.swift`
"A later night of this run is out: you blocked \(day) (\(name))."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you blocked \(day)."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you're already shooting \(name) on \(day)."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you're already shooting on \(day)."
    `Domain/BlockedCalendar.swift`
"A message bounced in the conversation you linked for \(p.replyWatchDisplayName). Overture didn't send that message, so it cannot tell which address failed. Check it in Gmail"
    `Integration/BounceService.swift`
"A nudge will arrive as a new email"
    `Domain/InquiryCopy.swift`
"A previous run was still reading pages, so the pages this run found were not handed over. Nothing was lost: press Run scout again once the reading finishes and they will be read."
    `Integration/ScoutService.swift`
"A reachability check couldn't find an email for this show. You can still keep it and add a contact by hand."
    `Domain/Reachability.swift`
"A reachability check found a contact you can email for this show."
    `Domain/Reachability.swift`
"A reachability check found an address for this show, but only a press or PR desk, which is the wrong department to pitch photography to. You can still keep it and add a contact by hand."
    `Domain/Reachability.swift`
"A reachability check found an address for this show, but only the venue's own, and a venue's inbox is never who you're pitching. You can still keep it and add a contact by hand."
    `Domain/Reachability.swift`
"A reachability check found only a venue or press address for this show, not the presenter's own. You can still keep it and add a stronger contact by hand."
    `Domain/Reachability.swift`
"A reachability check on another \(organisation) show found this contact, so this show didn't need checking again."
    `Domain/Reachability.swift`
"A reply draft that stalls before it arrives appears here too."
    `Domain/StalledReplyDraft.swift`
"A reply drafting run finished, but Overture couldn't read what it wrote, so no draft was saved (\(reason)). The file it wrote is still on disk, as overture-reply-classify-results.json."
    `Domain/ReplyClassifyRunSummary.swift`
"A reply-classify run is already in progress. Wait for it to finish."
    `Integration/ReplyClassifyService.swift`
"A run wrote into another run's results file, so answers you already paid for may have been overwritten."
    `Domain/RunBoundaryViolations.swift`
"A scout-extract run is already in progress. Wait for it to finish."
    `Integration/ScoutExtractService.swift`
"A sentence says the same thing twice"
    `Domain/DraftCheck.swift`
"A separate email each"
    `UI/SendConfirmSheet.swift`
"A show was left out this run because the local store stopped answering. Run the scout again."
    `Domain/ScoutWarnings.swift`
"A source \"\(sourceName)\" may be them: check its name, or tag it a returning client."
    `Domain/ClientCoverage.swift`
"A source couldn't be checked. Open Sources to fix or confirm it."
    `Domain/ScoutWarnings.swift`
"A sync may clear it. If it does not, the stored reason is: \(reason)"
    `Domain/OmniFocusFailureKind.swift`
"A test tried to launch a real Claude run. Inject the launch seam instead."
    `Integration/ScoutExtractService.swift`
"A venue's own calendar is answering, but not in a way Overture understands, so its shows may be missing from a scout."
    `Domain/AppNotice.swift`
"AI read: \(hint.replacingOccurrences(of: "_", with: " "))"
    `UI/QueueView+Model.swift`
"Add a Lead..."
    `App/OvertureApp.swift`
"Add a contact"
    `UI/DraftReviewView.swift`
"Add a lead"
    `UI/AddLeadSheet.swift`
"Add a lead..."
    `App/RootView.swift`
"Add a subject line"
    `App/ActionFeedback.swift`
"Add a subject line. Nothing was saved"
    `App/ActionFeedback.swift`
"Add address"
    `UI/SourcesView.swift`
"Add an address to send to"
    `App/ActionFeedback.swift`
"Add an address to send to. Nothing was saved"
    `App/ActionFeedback.swift`
"Add an email address, or a link to a contact form or profile. No contact was added"
    `App/ActionFeedback.swift`
"Add another"
    `UI/AddLeadSheet.swift`
"Add contact"
    `UI/DraftReviewView.swift`
"Add one address at a time. No contact was added"
    `App/ActionFeedback.swift`
"Add the name of whoever got in touch"
    `Domain/Inquiry.swift`
"Add this address to this show so a reply from it is recognised. It won't be pitched."
    `Domain/ReplyPanel.swift`
"Add this venue's address so its shows count as in your area."
    `UI/SourcesView.swift`
"Added \(Plural.count(count, "show")), ranked into your queue with everything else."
    `UI/LeadIntakeModel.swift`
"Added \(who). \(totalCount) recipient\(totalCount == 1 ? "" : "s") on \(org) now."
    `App/ActionFeedback.swift`
"After the show"
    `UI/FollowUpsView.swift`
"Agency-routed showcase rental, the dead zone that rarely converts."
    `Domain/EventClassifier.swift`
"Agent logged a problem: open agent logs"
    `App/MenuBarStatus.swift`
"All caught up"
    `Domain/PrepStatus.swift`
"All of these are included. Uncheck any you would rather not prep in this run."
    `Domain/PrepSelectionCopy.swift`
"All set"
    `UI/OnboardingView.swift`
"Allow OmniFocus control"
    `UI/OnboardingView.swift`
"Allow Overture to control OmniFocus in System Settings, Privacy and Security, Automation. Then sync again."
    `Domain/OmniFocusFailureKind.swift`
"Allow contact again"
    `UI/ProspectRowView.swift`
"Allow notifications"
    `UI/OnboardingView.swift`
"Allowed back in"
    `UI/ExcludedTownsView.swift`
"Already watching \(orgName)'s calendar, so their shows turn up on their own."
    `UI/LeadIntakeModel.swift`
"Already watching \(orgName)'s calendar."
    `Domain/WatchlistEditing.swift`
"Also goes to \(Plural.list(others))"
    `UI/QueueView+Model.swift`
"Also pitching \(name) at \(times)"
    `Domain/SelfBookingConflict.swift`
"Also pitching \(name) at \(times) and \(rest) other\(rest == 1 ? "" : "s")"
    `Domain/SelfBookingConflict.swift`
"Also pitching \(name) at \(times), \(hours) hour\(plural) \(side) this one"
    `Domain/SelfBookingConflict.swift`
"Also pitching \(others) on \(label)"
    `Domain/SelfBookingConflict.swift`
"Also pitching \(others) on a later night of this run"
    `Domain/SelfBookingConflict.swift`
"Also pitching \(others) on this date"
    `Domain/SelfBookingConflict.swift`
"Always a returning client"
    `Domain/ClientTagCopy.swift`
"Always skipped"
    `UI/ExcludedTownsView.swift`
"An AI draft came back while you were writing."
    `Domain/ReplyPanel.swift`
"An earlier check included this show and didn't settle it, so it's still unchecked. Nothing re-checks it on its own."
    `Domain/Reachability.swift`
"An email to \(p.replyWatchDisplayName) bounced, and it went to more than one person (\(addresses)), so Overture cannot tell which address failed. Check the bounce in Gmail and fix or remove the dead address"
    `Integration/BounceService.swift`
"An email to \(p.replyWatchDisplayName) bounced, and they have replied on that thread, so Overture has not written the address off. Check the bounce in Gmail before you write back"
    `Integration/BounceService.swift`
"An organization that asked"
    `Domain/SuppressionReport.swift`
"Another copy of Overture is already using its data."
    `App/OvertureApp.swift`
"Another inquiry is already logged for this event. You can still save this one."
    `Domain/InquiryCopy.swift`
"Another pitch is already in progress on a night one of these runs plays"
    `Domain/SelfBookingConflict.swift`
"Another pitch is already in progress on this date"
    `Domain/SelfBookingConflict.swift`
"Another run is going. This can start once that finishes."
    `Domain/Reachability.swift`
"Ask Claude to reinstall Overture."
    `Domain/BuildFreshnessPanel.swift`
"Asking macOS for OmniFocus permission…"
    `UI/OnboardingView.swift`
"Asks for nothing: no request about their photography plans"
    `Domain/DraftCheck.swift`
"Asks for the date or venue Overture already knows"
    `Domain/DraftCheck.swift`
"Authorize your photography Gmail so you can send approved emails"
    `Domain/DraftReviewNotes.swift`
"Auto-detected booking, confirm?"
    `UI/ProspectRowView.swift`
"Auto-detected bookings"
    `UI/OutcomePatternsView.swift`
"Auto-scout daily"
    `App/RootView.swift`
"Auto-sync to OmniFocus"
    `App/RootView.swift`
"Automatic (match Downbeat)"
    `Domain/ClientTagCopy.swift`
"Automatic sync pushes due follow-ups into the OmniFocus Outreach project. \"Sync now\" force-runs it immediately; the first time, macOS will ask permission to control OmniFocus."
    `App/RootView.swift`
"Awaiting reply"
    `UI/QueueView+Model.swift`
"Awaiting your first reply"
    `Domain/InquiryCopy.swift`
"Back to deciding \(organisation) automatically"
    `App/ActionFeedback.swift`
"Block days off"
    `UI/BlockDaysSheet.swift`
"Block some days"
    `Domain/DayOff.swift`
"Block these days"
    `UI/BlockDaysSheet.swift`
    `UI/DaysOffView.swift`
"Booked shoots"
    `UI/DaysOffView.swift`
"Booking and response rates by production, discipline, and fit tier"
    `App/RootView.swift`
"Both days are included, so a Friday to Sunday trip is three blocked days."
    `UI/DayOffRangeFields.swift`
"Built-in towns you took back onto the queue. Skip again to undo."
    `UI/ExcludedTownsView.swift`
"Calendar page"
    `UI/AddLeadSheet.swift`
"Came back empty \(runs) \(runWord) in a row, and hasn't listed a show for \(days) \(dayWord). Check the link."
    `Domain/SourceAttention.swift`
"Came back empty \(runs) \(runWord) in a row. Check the link."
    `Domain/SourceAttention.swift`
"Cancel prep"
    `Domain/RunKind.swift`
"Cancel reachability check"
    `Domain/RunKind.swift`
"Carnegie Hall"
    `Domain/WatchedSourceBackfill.swift`
    `Integration/ScoutService.swift`
    `UI/FollowUpsView.swift`
"Carnegie Hall is added the first time Overture opens your store."
    `UI/SourcesView.swift`
"Change the page link"
    `UI/SourceFixConfirmActions.swift`
"Check again"
    `Domain/Reachability.swift`
"Check named a route it never found"
    `Domain/Reachability.swift`
"Check reachability"
    `Domain/Reachability.swift`
"Check reachability for these \(count) shows?"
    `Domain/Reachability.swift`
"Check reachability for this show?"
    `Domain/Reachability.swift`
"Check the rest"
    `Domain/AppNotice.swift`
"Checked \(ago)"
    `Domain/SourceReadState.swift`
"Checking reachability"
    `UI/RunProgressView.swift`
"Checking what it found against your bookings"
    `Domain/ScoutSweepStep.swift`
"Checks that came home empty"
    `UI/EmptyAnswerSection.swift`
"City not known"
    `Domain/VenueDisplay.swift`
"Clear the search"
    `Domain/SourceSearch.swift`
"Cleared the flag on \(org), but read it once so a quiet page can stay quiet."
    `UI/SourceFixConfirmActions.swift`
"Clearing out shows in towns you blocked"
    `Domain/ScoutSweepStep.swift`
"Clears when: you answer them in Overture, or stand this contact down. Ticking this off here counts too: Overture reads it back and marks their reply answered."
    `Domain/OmniFocusSync.swift`
"Clears when: you record how the show ended in Overture. Ticking this off here only stops OmniFocus asking; Overture still needs the ending from you."
    `Domain/OmniFocusSync.swift`
"Close this and show only \(name)'s shows in the queue"
    `Domain/OrganisationsCopy.swift`
"Close this out"
    `Domain/ReachedOutClose.swift`
"Close this out without sending"
    `Domain/FollowUp.swift`
"Closed (not interested)"
    `Domain/PerformanceStatus.swift`
    `UI/QueueView+Model.swift`
"Closed (not now)"
    `Domain/PerformanceStatus.swift`
    `UI/QueueView+Model.swift`
"Cold-contacted before, no booking"
    `UI/QueueView+Model.swift`
"Confirm booking"
    `UI/ProspectRowView.swift`
"Connect Gmail"
    `App/RootView.swift`
    `Domain/GmailReconnectCopy.swift`
    `UI/OnboardingView.swift`
"Connect Gmail first"
    `Domain/DraftReviewNotes.swift`
"Consider closing"
    `UI/InquiryRowView.swift`
"Contact form"
    `Domain/Inquiry.swift`
    `UI/DraftReviewView.swift`
"Contact form only"
    `Domain/Reachability.swift`
"Contains an em dash"
    `Domain/DraftCheck.swift`
"Contains an unfilled placeholder like [VENUE]"
    `Domain/DraftCheck.swift`
"Continue anyway"
    `UI/StoreShrinkNoticeSheet.swift`
"Conversations to confirm"
    `Domain/ProposedConversation.swift`
"Copied. Paste it into Gmail, then say you sent it."
    `Domain/ReplyPanel.swift`
"Copy pitch and open form"
    `Domain/FormOutreach.swift`
"Copy pitch and open profile"
    `Domain/FormOutreach.swift`
"Copy the draft to paste into Gmail yourself. Nothing is recorded until you say you sent it."
    `Domain/ReplyPanel.swift`
"Couldn't block \(range)"
    `UI/ProspectMutations.swift`
"Couldn't connect Gmail"
    `App/RootView.swift`
"Couldn't connect Gmail: \(reason)"
    `Domain/OnboardingState.swift`
"Couldn't find the \(name) runner. The stored setting \(runner.defaultsKey) is not set, and the checkout this build came from has no runnable script at \(derivedPath). Reinstall Overture from the checkout (cd mac && ./build-install.sh)."
    `Domain/RunnerScripts.swift`
"Couldn't find the \(name) runner. The stored setting \(runner.defaultsKey) is not set, and this copy of Overture has no record of which checkout it was built from, so there is nowhere else to look. Install Overture from the checkout (cd mac && ./build-install.sh)."
    `Domain/RunnerScripts.swift`
"Couldn't find the \(name) runner. The stored setting \(runner.defaultsKey) points at \(configuredPath), and there is no runnable script there. If the checkout moved, reinstall Overture from where it is now (cd mac && ./build-install.sh) and that setting is rewritten for you."
    `Domain/RunnerScripts.swift`
"Couldn't open Overture's data: \(error.localizedDescription)"
    `App/OvertureApp.swift`
"Couldn't open the local login listener (timed out)."
    `Integration/LoopbackListener.swift`
"Couldn't open the local login listener."
    `Integration/GmailAuthManager.swift`
"Couldn't reach that page."
    `Integration/SourceFetcher.swift`
"Couldn't read that page."
    `UI/LeadIntakeModel.swift`
"Couldn't read that page: \(error.localizedDescription)"
    `UI/LeadIntakeModel.swift`
"Couldn't save the Gmail credentials to disk. Check available storage and try Connect Gmail again."
    `Integration/GmailAuthManager.swift`
"Couldn't save the change for \(org)"
    `App/ActionFeedback.swift`
"Couldn't save what happened sending to \(org): check Gmail to see if it went out."
    `App/ActionFeedback.swift`
"Couldn't send the follow-up to \(org)"
    `App/ActionFeedback.swift`
"Couldn't start the reader."
    `UI/LeadIntakeModel.swift`
"Couldn't start the reader: \(error.localizedDescription)"
    `UI/LeadIntakeModel.swift`
"Couldn't work out who to write to"
    `Domain/EmptyAnswerReport.swift`
"Coverage can't be checked: the Downbeat client export couldn't be read. Re-export it from Downbeat."
    `Domain/ClientCoverage.swift`
"Coverage can't be checked: there's no Downbeat client export. Export your client list from Downbeat."
    `Domain/ClientCoverage.swift`
"Dan Wright"
    `Integration/GmailSender.swift`
"Date TBD"
    `UI/QueueView+Model.swift`
"Date conflict"
    `Domain/ShowOutcome.swift`
"Date to be confirmed"
    `UI/QueueView+Model.swift`
"Days off"
    `Domain/DaysOffAttention.swift`
    `UI/DaysOffView.swift`
"Days you blocked"
    `UI/DaysOffView.swift`
"Delivery delayed"
    `UI/DraftReviewView.swift`
    `UI/QueueView.swift`
"Did they mean this show, or the whole organisation?"
    `UI/DraftReviewView.swift`
"Did you send it?"
    `Domain/FormOutreach.swift`
"Didn't send"
    `Domain/FormOutreach.swift`
"Direct email"
    `Domain/Inquiry.swift`
"Discard them"
    `UI/DaysOffView.swift`
"Dismiss all \(Plural.count(count, "show")) on \(dateLabel)"
    `Domain/BulkDismiss.swift`
"Dismiss all \(count)"
    `Domain/BulkDismiss.swift`
"Dismiss it"
    `Domain/BulkDismiss.swift`
"Dismiss only that one"
    `Domain/BulkDismiss.swift`
"Dismiss only the \(count)"
    `Domain/BulkDismiss.swift`
"Dismiss the show on \(dateLabel)"
    `Domain/BulkDismiss.swift`
"Dismiss them"
    `Domain/BulkDismiss.swift`
"Do not contact"
    `UI/ProspectRowView.swift`
"Don't learn from this email"
    `UI/ProspectRowFactory.swift`
"Don't want to shoot this"
    `Domain/ShowOutcome.swift`
"Downbeat clients no watched source treats as a returning client, so their next season would not surface a year ahead. Add a source for them, or tag an existing one below."
    `Domain/ClientCoverage.swift`
"Downbeat's export carries no shoots at all, though \(vanished.bookingCount) have come through it before, "
    `Domain/AppNotice.swift`
"Draft a reply"
    `UI/ReplyConversationView.swift`
"Draft it again"
    `Domain/StalledReplyDraft.swift`
"Draft with AI"
    `Domain/ReplyPanel.swift`
"Drafted by \(name)"
    `Domain/DraftTrace.swift`
"Drafted, and there's nobody to send it to. Add a contact and this draft is ready to go."
    `Domain/DraftedDeadEnd.swift`
"Drafting a reply"
    `Domain/ReplyPanel.swift`
"Drafting replies"
    `UI/RunProgressView.swift`
"Drafting replies \(count)"
    `Domain/ReplyClassifyProgress.swift`
"Drafts waiting for you to read, edit, and send."
    `Domain/AgentRoster.swift`
"Due (\(count))"
    `Domain/DueWork.swift`
"Each pair counts as two organisations, so nothing found for one is ever reused for the other. Some are real typos and some are simply different names."
    `UI/OrganisationsView.swift`
"Edit details..."
    `UI/InquiryRowView.swift`
"Edit inquiry"
    `Domain/InquiryCopy.swift`
"Email found"
    `Domain/Reachability.swift`
"Email or link"
    `UI/DraftReviewView.swift`
"Emails are held at send unless the body opens with a greeting"
    `App/ActionFeedback.swift`
"End this experiment"
    `UI/ExperimentReportView.swift`
"Event (optional)"
    `UI/InquiryIntakeSheet.swift`
"Event passed, nobody replied, say how it ended"
    `Domain/PostEventPrompt.swift`
"Event passed, they replied, say how it ended"
    `Domain/PostEventPrompt.swift`
"Every one is a one-off hunt, so none of them share an answer."
    `Domain/ProbeSelection.swift`
"Every one of the \(Plural.count(vanished.bookingCount, "shoot")) Downbeat was exporting has gone at once, "
    `Domain/AppNotice.swift`
"Every returning client is covered by a watched source, or set aside below."
    `Domain/ClientCoverage.swift`
"Every scout re-checks it, so their next show turns up on its own. Untick it for a touring act: an itinerary is mostly not in New York, and re-reading it buys nothing."
    `UI/AddLeadSheet.swift`
"Every show Overture has ever tracked: past its window, booked, closed, or dismissed"
    `App/RootView.swift`
"Every show here is already in the \(runNoun) that is running. Wait for it to finish and try again."
    `Integration/PrepQueueService.swift`
"Everyone found here is on the show without running it: a co-performer, a music director or a guest. Nobody with a say over the booking was found. The listing's credits are usually where the producer is named, and you can add them by hand."
    `Domain/Reachability.swift`
"Everything found here represents them rather than runs the show: a manager, an agent, a publicist or a booking agency. That may still get you an answer, but nobody who owns the show was found. The listing's credits are usually where the producer is named."
    `Domain/Reachability.swift`
"Failed to read \(runs) \(runWord) in a row, and hasn't been read for \(days) \(dayWord). Check the link."
    `Domain/SourceAttention.swift`
"Failed to read \(runs) \(runWord) in a row. Check the link."
    `Domain/SourceAttention.swift`
"Far towns skipped from the start. Allow one back if you now want its shows."
    `UI/ExcludedTownsView.swift`
"Filed as \(reason.label) either way."
    `Domain/BulkDismiss.swift`
"Find contacts only"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Finds a contact and drafts an email for shows you've kept."
    `Domain/AgentRoster.swift`
"Finishing up (\(elapsed))"
    `Domain/RunProgress.swift`
"First day"
    `UI/DayOffRangeFields.swift`
"Fit tier"
    `Domain/OutcomePatterns.swift`
"Follow up"
    `UI/InquiryRowView.swift`
"Follow-up sent to \(org)"
    `App/ActionFeedback.swift`
"Follow-up tasks aren't being created. Open Overture and allow it to control OmniFocus."
    `Integration/OmniFocusUserNotifier.swift`
"Follow-ups and active conversations due for a touch"
    `App/RootView.swift`
"Found 1 show on that page, but it doesn't name a venue, so I can't use it. That usually means the show's own page didn't load."
    `UI/LeadIntakeModel.swift`
"Found 1 show on that page, but it only gives the city it's in, never the venue, so I can't use it. Some pages never name a venue at all: that is the page being honest, not a fetch that failed."
    `UI/LeadIntakeModel.swift`
"Found \(count) shows on that page, but it only gives the city each one is in, never the venue, so I can't use them. Some pages never name a venue at all: that is the page being honest, not a fetch that failed."
    `UI/LeadIntakeModel.swift`
"Found \(count) shows on that page, but none of them name a venue, so I can't use them. That usually means the show's own page didn't load."
    `UI/LeadIntakeModel.swift`
"Found by Overture for this show, never written to"
    `Domain/ManualPrepPrefill.swift`
"Found in Gmail"
    `Domain/InquiryCopy.swift`
"Found the people, no way to reach any of them"
    `Domain/EmptyAnswerReport.swift`
"Freshly found events waiting for you to keep or dismiss."
    `Domain/AgentRoster.swift`
"From Downbeat"
    `UI/DaysOffView.swift`
"From your booking sheet, which often holds an agent's address rather than theirs"
    `Domain/ManualPrepPrefill.swift`
"Genre: \(read.label). Change it."
    `UI/QueueView+Model.swift`
"Getting your reply ready"
    `Domain/ReplyPanel.swift`
"Give the organization a name so you can recognize it here."
    `Domain/WatchlistEditing.swift`
"Gmail access expired or was revoked. Click Connect Gmail to reconnect."
    `Integration/GmailAuthManager.swift`
    `Integration/GmailSender.swift`
"Gmail client config is missing. Re-run the Google setup."
    `Integration/GmailAuthManager.swift`
"Gmail connected."
    `UI/OnboardingView.swift`
"Gmail connected. You can now send approved emails."
    `App/RootView.swift`
"Gmail couldn't refresh right now (temporary): \(m)"
    `Integration/GmailAuthManager.swift`
"Gmail is answering, but not in a way Overture understands, so replies and bounces may be going unnoticed."
    `Domain/AppNotice.swift`
"Gmail is connected for sending"
    `Domain/DraftReviewNotes.swift`
"Gmail isn't connected yet. Authorize the photography account to enable sending."
    `Integration/MailSender.swift`
"Gmail isn't connected, so Overture isn't checking for replies and can't tell whether anyone replied. Connect Gmail."
    `Domain/ReconcileSummary.swift`
"Gmail isn't connected. Use Connect Gmail first."
    `Integration/GmailAuthManager.swift`
"Go back to deciding \(organisation) automatically"
    `UI/QueueView+Model.swift`
"Google did not return a refresh token. Revoke prior access and retry."
    `Integration/GmailAuthManager.swift`
"Grant these once, here, so Overture can keep working while you're away from your desk."
    `UI/OnboardingView.swift`
"Group by"
    `UI/OutcomePatternsView.swift`
"Grouped by when to reach out next"
    `UI/QueueView.swift`
"HIGH FIT"
    `UI/QueueView+Model.swift`
"Handing the changed pages over to be read"
    `Domain/ScoutSweepStep.swift`
"Hard to reach"
    `Domain/Reachability.swift`
"Heads up: looks like the venue's own domain."
    `UI/ProspectMutations.swift`
"Heads up: shares a domain with another contact already on this show."
    `UI/ProspectMutations.swift`
"Hedges like a cold pitch at a warm client"
    `Domain/DraftCheck.swift`
"Hedges the claim that the audience doesn't notice Dan"
    `Domain/DraftCheck.swift`
"Held as a duplicate"
    `Domain/Reachability.swift`
"Held, address in another name"
    `Domain/Reachability.swift`
"Held, not sending"
    `UI/SendConfirmSheet.swift`
"Here early: returning clients are shown further ahead"
    `UI/QueueView+Model.swift`
"Hi \(firstName(name)),"
    `Domain/Salutation.swift`
"Hidden for a week. Overture still can't keep clear of shoots it doesn't know about."
    `App/ActionFeedback.swift`
"Hide this for a week"
    `Domain/DaysOffAttention.swift`
"How Overture drafts in your voice. Your notes are yours and are never auto-edited; the observed tendencies are learned from your edits after each Prep run."
    `UI/VoiceGuidanceView.swift`
"How they reached you"
    `UI/InquiryIntakeSheet.swift`
"How this goes out"
    `UI/SendConfirmSheet.swift`
"I can shoot this anyway"
    `UI/ProspectRowView.swift`
"I can't read that page: the site builds its calendar with JavaScript, so the shows aren't in what I download. Nothing's wrong with your link. Try the venue's page for the show, or a ticket link (Eventbrite and the like) if there is one."
    `Domain/LeadIntake.swift`
"I can't read that: it's behind a login, so I only get the sign-in page. Paste the org's own site or the venue's event page instead."
    `Domain/LeadIntake.swift`
"I couldn't read \(list(unread.map(name))), so anything on in \(unread.count == 1 ? "that month" : "those months") isn't here."
    `UI/LeadIntakeModel.swift`
"I couldn't read that page, so I followed its ticket link and read \(host) instead."
    `UI/LeadIntakeModel.swift`
"I had paid work"
    `Domain/ShowOutcome.swift`
"I read \(read.count) months of that calendar (\(name(first)) to \(name(last)))."
    `UI/LeadIntakeModel.swift`
"I read your shoot history again. It's current now."
    `App/ActionFeedback.swift`
"I read your shoot history again. The warning still stands."
    `App/ActionFeedback.swift`
"I sent it"
    `Domain/FormOutreach.swift`
"I turned them down"
    `Domain/ShowOutcome.swift`
"I'll read the ones you fix."
    `UI/ScoutSummaryView.swift`
"I've run the import"
    `Domain/AppNotice.swift`
"If Overture linked the wrong conversation, unlinking takes back what it recorded from it."
    `Domain/DetachConversation.swift`
"If another Overture window is open, use that one. Otherwise quit and reopen Overture."
    `App/StoreUnavailableView.swift`
"If they asked you to stop emailing them, Overture will keep every future show from this org out of your queue. You can undo it from the row."
    `UI/DraftReviewView.swift`
"In \(days) day\(days == 1 ? "" : "s"), likely too close to book"
    `UI/QueueView+Model.swift`
"In \(days) days, good to send"
    `UI/QueueView+Model.swift`
"In \(days) days, reach out now"
    `UI/QueueView+Model.swift`
"In \(days) days, send ~3 weeks out"
    `UI/QueueView+Model.swift`
"In conversation"
    `UI/QueueView+Model.swift`
"Include this date in one reachability check"
    `UI/ProbeSelectionBar.swift`
"Is this their reply?"
    `Domain/ProposedConversation.swift`
"It could not update "
    `Domain/OmniFocusSync.swift`
"It fetches the page, then follows each show's own link to get the venue and date."
    `UI/AddLeadSheet.swift`
"It is not what has shipped, and it is working on your real data."
    `Domain/BuildFreshnessPanel.swift`
"It leaves your queue, filed as \(reason.label)."
    `Domain/BulkDismiss.swift`
"It loses \(dateLabel), filed as \(reason.label), and turns up again under its next night."
    `Domain/BulkDismiss.swift`
"It reaches them"
    `UI/DraftReviewView.swift`
"It was installed before Overture started recording which code went into a build. The next install will settle it."
    `Domain/BuildFreshnessPanel.swift`
"It's their address"
    `UI/DraftReviewView.swift`
"Its listing page couldn't be read"
    `Domain/ShowSummary.swift`
"Its listing publishes no description"
    `Domain/ShowSummary.swift`
"Its most recent backup (\(folder)) could not be read. Nothing has been changed. Check that backup before working."
    `App/StoreShrinkCheck.swift`
"Its shows are sold through a ticketing feed that names no room, so they stay out of the queue."
    `UI/SourcesView.swift`
"Its start-up tidy-up didn't save, so the queue may still be showing duplicates it meant to merge, or shows that have already gone by. Quit and reopen Overture to try again."
    `Domain/LaunchMigrations.swift`
"Just this show"
    `UI/DraftReviewView.swift`
"Keep 1 show"
    `Domain/CancelledReadDisposition.swift`
"Keep \(n) shows"
    `Domain/CancelledReadDisposition.swift`
"Keep a show first, then prep it"
    `Domain/PrepQueueButton.swift`
"Keep a show from Scout and it lands here to prep."
    `Domain/StageEmptyState.swift`
"Keep editing"
    `UI/DaysOffView.swift`
"Keep this night clear for this shoot again."
    `Domain/CancelledShootCopy.swift`
"Keep this page but stop flagging it, until its contents change"
    `UI/SourceFixConfirmActions.swift`
"Keep this show to pitch it"
    `UI/ProspectRowView.swift`
"Keep watching this calendar"
    `UI/AddLeadSheet.swift`
"Keeps Overture resident in the menu bar so the syncs run unattended."
    `UI/OnboardingView.swift`
"Kept as companies"
    `UI/OrganisationsView.swift`
"LONG SHOT"
    `UI/QueueView+Model.swift`
"Last checked \(formatter.string(from: last))"
    `App/MenuBarStatus.swift`
"Last day"
    `UI/DayOffRangeFields.swift`
"Last failure"
    `Domain/OmniFocusFailureSection.swift`
"Last lines of the run log:"
    `Domain/SourceNote.swift`
"Learn from this email again"
    `UI/ProspectRowFactory.swift`
"Learning from \(org)'s email again"
    `App/ActionFeedback.swift`
"Left out of your last contact check: a prep run was already working on this one."
    `UI/QueueView+Model.swift`
"Left out of your last prep run: a contact check was already working on this one."
    `UI/QueueView+Model.swift`
"Left out of your last run: another run was already working on this one."
    `UI/QueueView+Model.swift`
"Lets Overture alert you when something needs you."
    `UI/OnboardingView.swift`
"Lets Overture create your follow-up tasks."
    `UI/OnboardingView.swift`
"Lets Overture send approved emails and notice replies."
    `UI/OnboardingView.swift`
"Likely covered"
    `UI/QueueView+Model.swift`
"Likely uncovered"
    `UI/QueueView+Model.swift`
"Link their reply"
    `Domain/ProposedConversation.swift`
"Linked. Overture is watching that conversation now."
    `Domain/ProposedConversation.swift`
"Linking this saves \(address) on the contact. Overture will watch the conversation, and any email it sends on this show from now on goes to that address."
    `Domain/ProposedConversation.swift`
"Links a site that is not danwrightphotography.com"
    `Domain/DraftCheck.swift`
"Links one gallery instead of the portfolio itself"
    `Domain/DraftCheck.swift`
"Local login listener couldn't get a port after \(LoopbackListener.bindAttempts) tries: \(m). Connecting again usually works."
    `Integration/LoopbackListener.swift`
"Local login listener failed: \(m)"
    `Integration/LoopbackListener.swift`
"Local login listener never reported a port."
    `Integration/LoopbackListener.swift`
"Log an inquiry"
    `Domain/InquiryCopy.swift`
"Log an inquiry..."
    `App/RootView.swift`
"Log inquiry"
    `Domain/InquiryCopy.swift`
"Login agent is installed."
    `UI/OnboardingView.swift`
"Login failed: \(m)"
    `Integration/GmailAuthManager.swift`
"Login response didn't match the request. Try again."
    `Integration/GmailAuthManager.swift`
"Look in Archive (\(archiveMatches))"
    `Domain/ShowSearch.swift`
"Look-ahead window"
    `UI/OmniFocusSettingsView.swift`
"Looks booked?"
    `UI/InquiryRowView.swift`
"Looks right"
    `UI/ProspectRowView.swift`
"Lookups already under way will finish and still count as spent, so stopping now only saves the ones that haven't started."
    `Domain/Reachability.swift`
"Lost (keep in mind)"
    `Domain/ReviewStatus.swift`
"Lost (not interested)"
    `Domain/ReviewStatus.swift`
"Lost before, not interested"
    `UI/QueueView+Model.swift`
"Lost before, open to the future"
    `UI/QueueView+Model.swift`
"Mark booked"
    `UI/InquiryRowView.swift`
"Mark lost"
    `UI/InquiryRowView.swift`
"Marked \(org)'s page as right. It won't be flagged again until it changes."
    `UI/SourceFixConfirmActions.swift`
"Matched performer '\(performerName)' to Downbeat client \(client.displayName)."
    `Domain/HistoryMatch.swift`
"Matched performer '\(performerName)' to Downbeat client \(client.displayName). Their email matches the address on file."
    `Domain/HistoryMatch.swift`
"Matched performer '\(performerName)' to a past booking-history record."
    `Domain/HistoryMatch.swift`
"Matches a Downbeat client: shows surface up to a year ahead."
    `Domain/ClientTagCopy.swift`
"Music only travels to the five boroughs. As performing arts this would stay."
    `UI/QueueView+Model.swift`
"Name (optional)"
    `UI/DraftReviewView.swift`
"Name matches, nothing ties it to this show"
    `Domain/Reachability.swift`
"Name the venue"
    `UI/SourcesView.swift`
"Needs a look"
    `Domain/SourceAttention.swift`
"Never a returning client"
    `Domain/ClientTagCopy.swift`
"Never checked"
    `Domain/SourceReadState.swift`
"Never contact \(groupName) again"
    `Domain/DraftReviewNotes.swift`
"Never heard back"
    `Domain/ShowOutcome.swift`
    `UI/QueueView+Model.swift`
"Never show me shows in \(town)"
    `UI/QueueView+Model.swift`
"New finds land here to keep or dismiss."
    `Domain/StageEmptyState.swift`
"New listings, not read yet. Run a scout to read them."
    `Domain/SourceReadState.swift`
"New listings. The scout is reading them now."
    `Domain/SourceReadState.swift`
"No Downbeat client export was found, so the scout treated every prospect as a cold lead. Open Downbeat to export your client list, then run the scout again."
    `Domain/DownbeatExport.swift`
"No Prep run or other check can start until it finishes."
    `Domain/ProbeSelection.swift`
"No address and no form on their own site, but they take messages on the profile linked here. You'd send the pitch as a DM yourself; Overture can't send it for you."
    `Domain/Reachability.swift`
"No address to fill in. Checked past emails to this organisation and the booking sheet."
    `Domain/ManualPrepPrefill.swift`
"No address to reply to"
    `Domain/ReplyPanel.swift`
"No address yet, so its shows are not placed in your area."
    `UI/SourcesView.swift`
"No check has come home without a contact. When one does, what it claimed appears here."
    `UI/EmptyAnswerSection.swift`
"No contact found"
    `UI/DraftReviewView.swift`
"No contacts yet."
    `UI/DraftReviewView.swift`
"No date for this show appears in the subject or the body. The show is \(show)."
    `Domain/EventDateInDraft.swift`
"No drafted or approved prospects to re-prep"
    `App/ActionFeedback.swift`
"No email address for this contact"
    `Domain/SendGate.swift`
"No email found"
    `Domain/Reachability.swift`
"No email to send to. Add a contact by hand, by address or by link."
    `Domain/DraftReviewNotes.swift`
"No email yet"
    `UI/QueueView+Model.swift`
"No experiment running. Start one to test two opener styles against each other and see which earns more replies. Nothing changes until you start it."
    `UI/ExperimentReportView.swift`
"No genre corrections recorded yet, so there is nothing to learn from."
    `Domain/GenreCorrection.swift`
"No genre read"
    `Domain/Ranker.swift`
"No kept prospects need prepping. Keep some prospects first."
    `Integration/PrepQueueService.swift`
"No listing page for this show"
    `Domain/ShowSummary.swift`
"No longer in the feed, may be cancelled"
    `UI/ProspectRowView.swift`
"No matches for \"\(query)\""
    `Domain/ShowSearch.swift`
"No name for this contact"
    `UI/DraftReviewView.swift`
"No names look duplicated right now."
    `UI/OrganisationsView.swift`
"No new shoots have come through from Downbeat in the last four weeks. If you simply haven't booked, nothing is wrong; if you have, check that Downbeat is still exporting to Overture."
    `Domain/DaysOffAttention.swift`
"No new shoots have come through from Downbeat in the last four weeks. If you've booked one, check that Downbeat is still exporting to Overture."
    `Domain/DaysOffAttention.swift`
"No new shows landed in the queue from that page."
    `UI/LeadIntakeModel.swift`
"No one to follow up with"
    `UI/QueueView.swift`
"No outcomes yet. Once you've sent and recorded results, booking and response rates show up here."
    `UI/OutcomePatternsView.swift`
"No past email to this organisation, and the booking sheet could not be read."
    `Domain/ManualPrepPrefill.swift`
"No replies need classifying right now."
    `Integration/ReplyClassifyService.swift`
"No response"
    `Domain/ReviewStatus.swift`
"No shoot history has been imported, so pitches can't mention rooms you've photographed before. Export your Shoots calendar and run the shoot-history import."
    `Domain/ShootHistory.swift`
"No source matches that name."
    `Domain/SourceSearch.swift`
"No sources need re-reading right now."
    `Integration/ScoutExtractService.swift`
"No sources yet."
    `UI/SourcesView.swift`
"No subject"
    `Domain/ProposedConversation.swift`
"No subject line. Edit the draft to add one."
    `Domain/DraftReviewNotes.swift`
"No upcoming shows on that page. That's normal off-season: the organization may not have announced its next season yet."
    `Domain/LeadIntake.swift`
"No venue"
    `Domain/OutcomePatterns.swift`
"No way to reach them"
    `Domain/ShowOutcome.swift`
"Nobody found to write to"
    `Domain/Reachability.swift`
"Nobody on this show publishes an address"
    `Domain/EmptyAnswerReport.swift`
"Nobody who can hire you"
    `Domain/Reachability.swift`
"None due"
    `Domain/AgentRoster.swift`
"None yet. Refuse a town from a show and it lands here, where you can take it back."
    `UI/ExcludedTownsView.swift`
"Not a booking"
    `UI/ProspectRowView.swift`
"Not a duplicate"
    `UI/DraftReviewView.swift`
"Not a fit"
    `Domain/ShowOutcome.swift`
"Not a live performance"
    `Domain/Ranker.swift`
"Not a real reply"
    `UI/DraftReviewView.swift`
"Not actually covered"
    `UI/ProspectRowView.swift`
"Not allowed. Enable Overture in System Settings ▸ Notifications."
    `Domain/OnboardingState.swift`
"Not checked yet"
    `Domain/SourceGrade.swift`
"Not happening"
    `Domain/CancelledShootCopy.swift`
"Not installed yet. Run your Overture build once to install it."
    `UI/OnboardingView.swift`
"Not now"
    `Domain/BuildFreshnessPanel.swift`
    `UI/BlockDaysSheet.swift`
"Not press/media"
    `UI/DraftReviewView.swift`
"Not read yet"
    `Domain/SourceReadState.swift`
"Not really bounced"
    `UI/DraftReviewView.swift`
"Not scouted yet"
    `Domain/ScoutStatus.swift`
"Not sent yet"
    `UI/QueueView+Model.swift`
"Not the venue"
    `UI/DraftReviewView.swift`
"Not them"
    `Domain/ProposedConversation.swift`
"Not this one"
    `Domain/FollowUp.swift`
"Not treated as a returning client."
    `Domain/ClientTagCopy.swift`
"Not yet synced"
    `Domain/OmniFocusSyncStatus.swift`
"Notes (optional)"
    `UI/InquiryIntakeSheet.swift`
"Nothing blocked. Add a vacation and Overture will stop pitching you for those nights."
    `UI/DaysOffView.swift`
"Nothing changed on \(org): Overture could not check whether that night is free. Try again."
    `App/ActionFeedback.swift`
"Nothing due before the show"
    `Domain/ReachedOutQueue.swift`
"Nothing found here was verified as belonging to this act. Only an address read off a page naming them counts; a generic inbox or an inferred address doesn't. It may still be right, so it's worth a look before you write."
    `Domain/Reachability.swift`
"Nothing has recorded a merge on this Mac, so there is nothing to compare this copy against."
    `Domain/BuildFreshnessPanel.swift`
"Nothing here right now"
    `Domain/StageEmptyState.swift`
"Nothing in the queue matches \"\(query)\""
    `Domain/ShowSearch.swift`
"Nothing is drafted for you and no Prep run is started."
    `UI/ManualPrepSheet.swift`
"Nothing is recorded until you confirm you sent it."
    `UI/DraftReviewView.swift`
"Nothing looks odd right now."
    `UI/OrganisationsView.swift`
"Nothing matches this filter"
    `Domain/EmptyState.swift`
"Nothing more will be sent about this \(org) show. No email went out"
    `App/ActionFeedback.swift`
"Nothing more will be sent to this contact at \(org). No email went out"
    `App/ActionFeedback.swift`
"Nothing new"
    `Domain/AgentRoster.swift`
"Nothing new on the watched calendars"
    `Domain/ScoutRunSummary.swift`
"Nothing new to triage"
    `Domain/StageEmptyState.swift`
"Nothing on this date still needs a reachability check."
    `Integration/PrepQueueService.swift`
"Nothing on this feed names a room, so its shows are filed under \(org)."
    `UI/SourcesView.swift`
"Nothing on this show connects \(name) to the address found for them, and no page was recorded; blocked from sending."
    `Domain/DraftReviewNotes.swift`
"Nothing recorded which page \(name)'s address was read off, so it isn't counted as verified."
    `Domain/DraftReviewNotes.swift`
"Nothing scouted yet"
    `Domain/EmptyState.swift`
"Nothing to act on. Shows you've pitched appear here for a gentle follow-up, again once the date has passed so you can close them out, and whenever a conversation turns up that might be their reply; they drop off the moment you act on one."
    `Domain/EmptyState.swift`
"Nothing to prep yet"
    `Domain/StageEmptyState.swift`
"Nothing to review"
    `Domain/AgentRoster.swift`
"Nothing to review yet"
    `Domain/StageEmptyState.swift`
"Nothing to send"
    `Domain/AgentRoster.swift`
"Nothing tracked yet"
    `Domain/EmptyState.swift`
"Nothing upcoming for \(org) on that page. The other shows there belong to the venue's own programme, not to them, so I've left them out."
    `Domain/LeadIntake.swift`
"Nothing waiting"
    `Domain/AgentRoster.swift`
"Nothing was ever sent for \(org), so \"\(outcome.label)\" doesn't apply to it. Nothing changed."
    `Domain/ShowOutcome.swift`
"Notifications allowed."
    `Domain/OnboardingState.swift`
"Offers a discount or free/complimentary work"
    `Domain/DraftCheck.swift`
"OmniFocus is syncing due follow-ups. It only fires while Overture is open, so it looks ahead by:"
    `UI/OmniFocusSettingsView.swift`
"OmniFocus needs Automation permission"
    `Domain/OmniFocusSyncStatus.swift`
"OmniFocus permission granted."
    `Domain/OnboardingState.swift`
"OmniFocus refused those shows, and it will refuse them the same way next time. The stored reason is: \(reason)"
    `Domain/OmniFocusFailureKind.swift`
"OmniFocus sync"
    `UI/OmniFocusSettingsView.swift`
"OmniFocus sync failed"
    `Domain/OmniFocusSyncStatus.swift`
"OmniFocus sync failed and recorded no reason, which is itself worth reporting."
    `Domain/OmniFocusFailureSection.swift`
"OmniFocus sync failed: \(reason)"
    `Domain/OmniFocusSync.swift`
"OmniFocus sync is failing because OmniFocus is not open, so follow-up tasks are not being created."
    `Domain/OmniFocusFailureKind.swift`
"OmniFocus sync is failing because Overture is not allowed to control OmniFocus, so follow-up tasks are not being created."
    `Domain/OmniFocusFailureKind.swift`
"OmniFocus sync is failing, so follow-up tasks may not be getting created."
    `Domain/OmniFocusFailureKind.swift`
"OmniFocus sync needs attention"
    `App/MenuBarStatus.swift`
"OmniFocus updated \(updated) of \(attempted) reminders. \(couldNotUpdatePhrase)\(named)."
    `Domain/OmniFocusSync.swift`
"On this email"
    `UI/SendConfirmSheet.swift`
"Once you have sent a pitch, the shows you are waiting to hear back about show up here, soonest follow-up first. A show drops off when you close it out, or when its follow-ups run out."
    `UI/QueueView.swift`
"One email to everyone"
    `UI/SendConfirmSheet.swift`
"One of the addresses is blank"
    `App/ActionFeedback.swift`
"One of the addresses is blank. No contact was added"
    `App/ActionFeedback.swift`
"One of the addresses is blank. Nothing was saved"
    `App/ActionFeedback.swift`
"One show was left out of this run. The local store stopped answering, so Overture could not tell whether it was a new show or a card you have already decided on, and it would rather skip it than write over one. Run the scout again to pick it up."
    `Domain/ScoutWarningCopy.swift`
"One source couldn't be checked."
    `UI/ScoutSummaryView.swift`
"One source couldn't be checked. \(lines[0])"
    `Integration/ScoutService.swift`
"One source went quiet."
    `UI/ScoutSummaryView.swift`
"One word is doing the same job in too many sentences"
    `Domain/DraftCheck.swift`
"Only a press address"
    `Domain/Reachability.swift`
"Only a press or PR desk"
    `Domain/EmptyAnswerReport.swift`
"Only a profile with the right name on it"
    `Domain/EmptyAnswerReport.swift`
"Only a social profile"
    `Domain/Reachability.swift`
"Only a social profile, not opened"
    `Domain/EmptyAnswerReport.swift`
"Only counts corrections made since this started recording them. Earlier ones were never kept, and re-reading those rows now would answer with today's rules rather than the ones that got them wrong."
    `Domain/GenreCorrection.swift`
"Only names, no way to reach them"
    `Domain/Reachability.swift`
"Only the room's own inbox"
    `Domain/EmptyAnswerReport.swift`
"Only the venue's address"
    `Domain/Reachability.swift`
"Open OmniFocus, then sync again."
    `Domain/OmniFocusFailureKind.swift`
"Open Overture"
    `App/MenuBarContent.swift`
"Open Settings"
    `Integration/NotificationService.swift`
"Open agent logs"
    `App/MenuBarStatus.swift`
"Open in Overture: \(link)"
    `Domain/OmniFocusSync.swift`
"Open logs folder (nothing logged yet)"
    `App/MenuBarStatus.swift`
"Opening Google sign-in…"
    `UI/OnboardingView.swift`
"Organisations Overture may have read wrongly. Everything else it decided is on the show itself."
    `UI/OrganisationsView.swift`
"Organizations that asked"
    `Domain/SuppressionReport.swift`
"Outside New York, New Jersey and Connecticut."
    `UI/QueueView+Model.swift`
"Overture can't read your Downbeat export, so it doesn't know which nights you're already shooting."
    `Domain/AppNotice.swift`
"Overture cannot reach its data, so there is nowhere to add a lead"
    `UI/AddLeadPresenter.swift`
"Overture cannot tell how old this copy is"
    `Domain/BuildFreshnessPanel.swift`
"Overture cannot tell where this copy came from"
    `Domain/BuildFreshnessPanel.swift`
"Overture cannot tell whether anything is missing"
    `App/StoreShrinkCheck.swift`
"Overture cannot tell which shows the \(runNoun) is working on, so it will not start a run that might take the same ones. Wait for that run to finish and try again."
    `Integration/PrepQueueService.swift`
"Overture contact: "
    `Domain/OmniFocusSync.swift`
"Overture could not open its backup folder, so there is nothing to compare against. Nothing has been changed. Check that folder before working."
    `App/StoreShrinkCheck.swift`
"Overture could not open its data file to check it at \(path). Nothing has been opened or changed. The file may be in use by another program, or its permissions may have changed. Check that file before reopening Overture."
    `App/StoreSchemaGuard.swift`
"Overture could not save the record of what this run searched for, so it will be lost when the next run starts: \(reason)"
    `App/PrepRunArchive.swift`
"Overture could not save the records of what this run searched for on each show, so they will be lost when the next run starts: \(reason)"
    `App/PrepRunArchive.swift`
"Overture could not update"
    `Domain/UpdateAttempt.swift`
"Overture couldn't finish starting up"
    `Domain/LaunchMigrations.swift`
"Overture couldn't get this reply ready to send."
    `Domain/ReplyPanel.swift`
"Overture couldn't move its data to \(newStoreURL.path): \(error.localizedDescription). Your data is safe and unchanged at \(legacyStoreURL.path)."
    `App/StoreRelocation.swift`
"Overture couldn't reach Gmail while looking for replies to the pitches you sent through a form or a DM."
    `Integration/GmailReplySearch.swift`
"Overture couldn't read Gmail while looking for replies to the pitches you sent through a form or a DM. Gmail refused the request (HTTP \(status))."
    `Integration/GmailReplySearch.swift`
"Overture couldn't read \(failures.count) of the files it works from, so whatever they held has not been used."
    `Domain/AppNotice.swift`
"Overture couldn't read \(first.file), so whatever it held has not been used."
    `Domain/AppNotice.swift`
"Overture couldn't read this message, which usually means it's an image or an attachment. Open it in Gmail."
    `Domain/ReplyPanel.swift`
"Overture couldn't refresh your Gmail sign-in, so it stopped checking for replies and can't tell whether anyone replied. Reconnect Gmail."
    `Domain/ReconcileSummary.swift`
"Overture couldn't save the link. Try again; if this keeps happening, something's wrong with the local store."
    `Domain/ProposedConversation.swift`
"Overture couldn't start the Gmail sign-in on this Mac, so it didn't open your browser."
    `Integration/GmailAuthManager.swift`
"Overture couldn't tell which conversation to link, so it linked nothing."
    `Domain/AttachConversation.swift`
"Overture couldn't update OmniFocus"
    `Integration/OmniFocusUserNotifier.swift`
"Overture decided: \(what)"
    `UI/QueueView+Model.swift`
"Overture didn't capture what they wrote. Their message is in Gmail."
    `Domain/ReplyPanel.swift`
"Overture didn't email \(groupName), so it can't add a message to the conversation you linked. Write to them in Gmail instead."
    `Domain/AttachedConversation.swift`
"Overture doesn't record whether a check was told the organisation's name, so this counts every show carrying one, not only the ones where the name went unsearched."
    `Domain/EmptyAnswerReport.swift`
"Overture found this conversation in your Gmail, from the address you logged, and is watching it for replies."
    `Domain/InquiryCopy.swift`
"Overture gave up waiting for Gmail while looking for replies to the pitches you sent through a form or a DM."
    `Integration/GmailReplySearch.swift`
"Overture has no Downbeat export, so it doesn't know which nights you're already shooting."
    `Domain/AppNotice.swift`
"Overture has not checked for replies or bookings in \(PrepStatus.duration(seconds: seconds))"
    `Domain/WatchGap.swift`
"Overture has stopped looking for a reply to this one. If they did write, link it by hand."
    `Domain/ProposedConversation.swift`
"Overture hasn't read your inbox for a reply to this one yet."
    `Domain/ProposedConversation.swift`
"Overture is out of date"
    `Domain/BuildFreshnessPanel.swift`
"Overture is reading your inbox for a reply to this one and hasn't found a likely match yet."
    `Domain/ProposedConversation.swift`
"Overture is still reading a previous page. Give it a moment and try again."
    `UI/LeadIntakeModel.swift`
"Overture is still reading the pages the last scout found, so a new scout could fetch but not read anything."
    `Domain/ScoutStartGate.swift`
"Overture isn't connected to Gmail, so it can't read your inbox. Connect it in Settings and try again."
    `Domain/ProposedConversation.swift`
"Overture knows of no upcoming shoots from Downbeat, so it can't keep clear of them. Block those days here."
    `Domain/DaysOffAttention.swift`
"Overture knows of no upcoming shoots from Downbeat, so the only days it keeps clear are the ones you add here."
    `Domain/DaysOffAttention.swift`
"Overture lead: "
    `Domain/OmniFocusSync.swift`
"Overture needs OmniFocus permission"
    `Integration/OmniFocusUserNotifier.swift`
"Overture only links a conversation to a pitch you sent through a form or a DM. It already watches the ones it emailed itself."
    `Domain/AttachConversation.swift`
"Overture opened with \(live) \(live == 1 ? "show" : "shows"). Its most recent backup holds \(previous). Nothing has been changed. If that drop is a surprise, quit Overture and restore a backup before working: every launch takes another backup, and only the last ten are kept."
    `App/StoreShrinkCheck.swift`
"Overture put this show back the way it was, but it can't reach outside the app: "
    `Domain/DetachConversation.swift`
"Overture read your inbox and found nothing from around this pitch that could be their reply."
    `Domain/ProposedConversation.swift`
"Overture recorded those before it kept their dates, so it can't say which have already happened. What it can say is that a new shoot came through as recently as \(arrived), and the export now holds none at all. Re-export it from Downbeat, then re-read it here."
    `Domain/AppNotice.swift`
"Overture was not checking for replies or bookings for \(PrepStatus.duration(seconds: seconds)), and resumed \(PrepStatus.relative(from: endedAt, to: now))"
    `Domain/WatchGap.swift`
"Overture was not running for \(PrepStatus.duration(seconds: seconds)), and started again \(PrepStatus.relative(from: endedAt, to: now))"
    `Domain/WatchGap.swift`
"Overture's data file doesn't look like Overture's own database. Another app may have written to \(path). Nothing has been opened or changed. Check that file before reopening Overture."
    `App/StoreSchemaGuard.swift`
"Overture's data is unavailable"
    `App/StoreUnavailableView.swift`
"Overture's data is unavailable."
    `App/StoreLaunchOutcome.swift`
"Overture, \(Plural.count(count, "thing")) due"
    `Domain/DueBadge.swift`
"Paste a link to the show, or to the organization's events page."
    `UI/AddLeadSheet.swift`
"Paused (booked elsewhere)"
    `UI/QueueView+Model.swift`
"Paused (show declined)"
    `UI/QueueView+Model.swift`
"Performance passed"
    `UI/QueueView+Model.swift`
"Performance: \(d)"
    `Domain/OmniFocusSync.swift`
"Performative enthusiasm or an exclamation point"
    `Domain/DraftCheck.swift`
"Performing Arts"
    `Domain/Ranker.swift`
"Performs \(QueueModel.runDateLabel(start: performanceDate, end: runEndDate))"
    `UI/ReachedOutRowChrome.swift`
"Performs today, too close to book"
    `UI/QueueView+Model.swift`
"Pick two different styles to compare."
    `UI/ExperimentReportView.swift`
"Pitch copied for \(org)"
    `App/ActionFeedback.swift`
"Pitching other shows that night"
    `Domain/ShowOutcome.swift`
"Point this source at a different page, then read it to check"
    `UI/SourceFixConfirmActions.swift`
"Possible booking, confirm?"
    `UI/ProspectRowView.swift`
"Possible match to \(possibleMatchOrigin(item.possibleMatchSource)): \(name)?"
    `UI/QueueView+Model.swift`
"Possible profile, not confirmed"
    `Domain/Reachability.swift`
"Possibly one name twice"
    `UI/OrganisationsView.swift`
"Prep \(Plural.count(count, "show"))"
    `Domain/PrepSelectionCopy.swift`
"Prep \(groupName) by hand"
    `Domain/ManualPrepPrefill.swift`
"Prep a show on a date you're already pitching?"
    `Domain/PrepLaunchCopy.swift`
"Prep a show on a night that's already spoken for?"
    `Domain/PrepLaunchCopy.swift`
"Prep a show on a night you're not free?"
    `Domain/PrepLaunchCopy.swift`
"Prep anyway"
    `Domain/PrepLaunchCopy.swift`
"Prep kept"
    `App/RootView.swift`
"Prep manually"
    `UI/ProspectRowView.swift`
"Prep matched this show's performer to a past client, which raised the fit score. The draft won't treat them as a returning client until you confirm it."
    `UI/QueueView+Model.swift`
"Prep queued"
    `Domain/ReprepRequest.swift`
"Prep these \(count) shows"
    `Domain/PrepQueueButton.swift`
"Prep this 1 show"
    `Domain/PrepQueueButton.swift`
"Prep this show?"
    `Domain/ReprepRequest.swift`
"Prep's research found this show may already have its own photographer. Tap if that's wrong."
    `UI/ProspectRowView.swift`
"Prepped drafts land here to read and send."
    `Domain/StageEmptyState.swift`
"Prepping \(org) to find new contacts"
    `App/ActionFeedback.swift`
"Prepping \(org) to redraft"
    `App/ActionFeedback.swift`
"Prepping \(org) to redraft and find new contacts"
    `App/ActionFeedback.swift`
"Presumes the booking instead of handing back the decision"
    `Domain/DraftCheck.swift`
"Put back"
    `Domain/ClientCoverage.swift`
"Put it back"
    `Domain/CancelledShootCopy.swift`
"Put this prospect back in the queue as undecided"
    `UI/ProspectRowView.swift`
"Queued \(draftGrantedCount) of \(total) \(prospectWord) to \(base); \(narrowedCount) already sent, so \(narrowedCount == 1 ? "it" : "they") only got new contacts"
    `App/ActionFeedback.swift`
"Queued \(total) \(prospectWord) to find new contacts"
    `App/ActionFeedback.swift`
"Queued \(total) \(prospectWord) to redraft"
    `App/ActionFeedback.swift`
"Quit Overture"
    `App/MenuBarContent.swift`
"Re-prep kept"
    `App/RootView.swift`
"Re-prep queued"
    `Domain/ReprepRequest.swift`
"Re-prep this show?"
    `Domain/ReprepRequest.swift`
"Re-prepping \(org) to find new contacts"
    `App/ActionFeedback.swift`
"Re-prepping \(org) to redraft"
    `App/ActionFeedback.swift`
"Re-prepping \(org) to redraft and find new contacts"
    `App/ActionFeedback.swift`
"Re-read the export"
    `Domain/AppNotice.swift`
"Re: your inquiry"
    `Domain/InquiryCopy.swift`
"Reach out now"
    `Domain/ReachedOutQueue.swift`
"Reachability checked"
    `Domain/Reachability.swift`
"Reachability may be out of date"
    `Domain/Reachability.swift`
"Reached out"
    `App/ActionFeedback.swift`
    `Domain/AgentRoster.swift`
"Read 1 show before you cancelled."
    `Domain/CancelledReadDisposition.swift`
"Read \(askAbove) now"
    `Domain/ScoutReadBudget.swift`
"Read \(checks) times and has never listed a show. Check the link."
    `Domain/SourceAttention.swift`
"Read \(n) shows before you cancelled."
    `Domain/CancelledReadDisposition.swift`
"Read \(reads) times but never turned up a show. It may be pointed at the wrong page."
    `Domain/SourceYield.swift`
"Read \(relative(at, now: now))"
    `Domain/SourceReadState.swift`
"Read all \(pending)"
    `Domain/ScoutReadBudget.swift`
"Read and edit how Overture drafts in your voice. Your notes stay yours; tendencies are learned from your edits."
    `App/RootView.swift`
"Read none"
    `Domain/ScoutReadBudget.swift`
"Read over an unencrypted connection, because this site's secure one is broken."
    `Domain/WatchedSource.swift`
"Read the \(count) I fixed"
    `UI/ScoutSummaryView.swift`
"Read the email one last time, then send it"
    `UI/DraftReviewView.swift`
"Read the one I fixed"
    `UI/ScoutSummaryView.swift`
"Read this one now"
    `Domain/WatchlistEditing.swift`
"Read this page"
    `UI/AddLeadSheet.swift`
"Read this source's listings now, without scouting the rest of the list"
    `Domain/WatchlistEditing.swift`
"Reading calendars"
    `UI/RunProgressView.swift`
"Reading show pages"
    `UI/RunProgressView.swift`
"Reading them all takes a few minutes. A smaller batch leaves \(them) first in line next time."
    `Domain/ScoutReadBudget.swift`
"Reading your inbox..."
    `Domain/ProposedConversation.swift`
"Reconcile complete: "
    `Domain/ReconcileSummary.swift`
"Reconcile complete: nothing was due."
    `Domain/ReconcileSummary.swift`
"Reconcile ran but Gmail refused every hire inquiry conversation it tried to read, so it can't tell whether anyone answered them. Try again shortly."
    `Domain/ReconcileSummary.swift`
"Reconcile ran but couldn't reach Gmail for the hire inquiries it watches, so it can't tell whether anyone answered them. Check the Gmail connection."
    `Domain/ReconcileSummary.swift`
"Reconcile ran but couldn't read Gmail for any of the conversations it watches, so it can't tell whether anyone replied. Check the Gmail connection."
    `Domain/ReconcileSummary.swift`
"Reconcile ran but couldn't save its results. Try again; if this keeps happening, something's wrong with the local store."
    `Domain/ReconcileSummary.swift`
"Reconnect Gmail"
    `Domain/GmailReconnectCopy.swift`
"Record this reply as answered. Nothing was recorded when you copied it."
    `Domain/ReplyPanel.swift`
"Recorded. \(org) is now in Reached out."
    `App/ActionFeedback.swift`
"Redo it anyway?"
    `Domain/ReprepRequest.swift`
"Redraft and find contacts"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Redraft only"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Remind me in \(config.gapDays) days"
    `Domain/FollowUp.swift`
"Remove \(email)"
    `Domain/Reachability.swift`
"Remove this address. Prep won't research it or write to it, and later checks won't put it back."
    `Domain/Reachability.swift`
"Remove this contact"
    `UI/DraftReviewView.swift`
"Removed \(email) from \(org). Overture won't offer it on their other shows."
    `App/ActionFeedback.swift`
"Removed \(who) from \(org)."
    `App/ActionFeedback.swift`
"Rename show"
    `UI/ProspectRowView.swift`
"Rename this show"
    `UI/ProspectRowView.swift`
"Renamed to \(name)"
    `App/ActionFeedback.swift`
"Reopen this show"
    `Domain/ShowOutcome.swift`
"Replace what you've written here with the AI's draft"
    `Domain/ReplyPanel.swift`
"Replaces the scout's name on this row. Your name stays put across future scouts."
    `UI/ProspectRowView.swift`
"Replied \(theirs), you answered \(his)"
    `Domain/AnsweredReplyNote.swift`
"Replied \(theirs), you answered that day"
    `Domain/AnsweredReplyNote.swift`
"Replies can't be tracked"
    `Domain/InquiryCopy.swift`
"Reply to \(inquirerName)"
    `Domain/InquiryCopy.swift`
"Reply-classify results couldn't save. Try again."
    `App/RootView.swift`
"Requesting notification permission…"
    `UI/OnboardingView.swift`
"Research this show's contacts again now, instead of keeping this answer until it's 90 days old. It costs one lookup, and you'll see what it will spend before it starts."
    `Domain/Reachability.swift`
"Researching this show again"
    `Domain/Reachability.swift`
"Reset to scout name"
    `UI/ProspectRowView.swift`
"Resnick Education Wing"
    `Domain/VenueParser.swift`
"Restored \(org) to the queue"
    `App/ActionFeedback.swift`
"Restored the scout's name: \(name)"
    `App/ActionFeedback.swift`
"Resumed pursuing \(who) on \(org)."
    `App/ActionFeedback.swift`
"Retry sync"
    `Integration/NotificationService.swift`
"Returning client"
    `Domain/ClientTagCopy.swift`
"Returning clients not covered"
    `Domain/ClientCoverage.swift`
"Review and send"
    `UI/FollowUpsView.swift`
    `UI/SendConfirmSheet.swift`
"Rooms Overture can't place"
    `UI/SourcesView.swift`
"Run reconcile now"
    `App/MenuBarContent.swift`
"Run scout again"
    `UI/ScoutSummaryView.swift`
"Run scout now"
    `App/RootView.swift`
"Run the scout to comb the venue calendars. Ranked candidates land here for review."
    `Domain/EmptyState.swift`
"Run underway"
    `UI/QueueView+Model.swift`
"Running now…"
    `Domain/AgentRoster.swift`
"Save changes"
    `Domain/InquiryCopy.swift`
"Save draft"
    `UI/ManualPrepSheet.swift`
"Save or cancel the location you're editing first."
    `Domain/SourcesSheetClose.swift`
"Save or cancel the room you're placing first."
    `Domain/SourcesSheetClose.swift`
"Save or cancel the venue name you're editing first."
    `Domain/SourcesSheetClose.swift`
"Save this address"
    `Domain/ReplyPanel.swift`
"Saved \(address) to this show. Replies from it are recognised now, and it won't be pitched."
    `Domain/ReplyPanel.swift`
"Saved \(org)'s address, and gave it to \(shows) already in the queue."
    `UI/SourcesView.swift`
"Saved \(org)'s address. No show in the queue was waiting on it."
    `UI/SourcesView.swift`
"Saved \(org)'s venue. Its shows are read again on the next scout."
    `UI/SourcesView.swift`
"Saved where \(room) is, and gave it to \(shows) already in the queue."
    `UI/SourcesView.swift`
"Saved where \(room) is. No show in the queue was waiting on it."
    `UI/SourcesView.swift`
"Saving what this run found"
    `Domain/ScoutSweepStep.swift`
"Say how it ended"
    `Domain/ReachedOutQueue.swift`
"Say what happened"
    `Domain/ReachedOutQueue.swift`
"Say where \(room) is"
    `UI/SourcesView.swift`
"Say where it is"
    `UI/SourcesView.swift`
"Says how many times Dan has shot the venue"
    `Domain/DraftCheck.swift`
"Scout & Prep"
    `App/RootView.swift`
"Scout progress"
    `App/RootView.swift`
"Scout results"
    `UI/ScoutSummaryView.swift`
"Scout stopped"
    `Domain/CancelledReadDisposition.swift`
"Scout the venue calendars for new performances (⌘R), then find contacts and draft emails for the ones you keep (⌘P). Auto-scouts about daily."
    `App/RootView.swift`
"Scouted \(PrepStatus.relative(from: last, to: now))"
    `Domain/ScoutStatus.swift`
"Search by name"
    `Domain/SourceSearch.swift`
"Search shows, venues, contacts"
    `UI/ShowSearchField.swift`
"Search the queue"
    `UI/QueueSearchBar.swift`
"Self-produced\(genre) group, a strong-fit target."
    `Domain/EventClassifier.swift`
"Self-produced\(genre); worth a look once the fit is confirmed."
    `Domain/EventClassifier.swift`
"Send Anyway"
    `UI/DraftReviewView.swift`
"Send a follow-up"
    `Domain/ReachedOutAction.swift`
"Send anyway?"
    `UI/DraftReviewView.swift`
"Send failed: \(raw)"
    `Domain/SendFailureLine.swift`
"Send issues"
    `Domain/AgentRoster.swift`
"Send reply"
    `UI/ReplyConversationView.swift`
"Send this email now?"
    `UI/SendConfirmSheet.swift`
"Send this follow-up now?"
    `UI/SendConfirmSheet.swift`
"Send this reply now?"
    `UI/SendConfirmSheet.swift`
"Send this reply on the contact's thread"
    `UI/ReplyConversationView.swift`
"Send to"
    `UI/ManualPrepSheet.swift`
"Sending despite the draft warning you confirmed."
    `Domain/DraftReviewNotes.swift`
"Sending despite the greeting warning you confirmed."
    `Domain/DraftReviewNotes.swift`
"Sending reply"
    `UI/ReplyConversationView.swift`
"Sending to this one"
    `UI/SendConfirmSheet.swift`
"Sent as a DM."
    `Domain/FormOutreach.swift`
"Sent as a DM. Overture is watching the email conversation you linked."
    `Domain/FormOutreach.swift`
"Sent as a DM. You told Overture they replied."
    `Domain/FormOutreach.swift`
"Sent emails that hit a problem, or approved ones you can't send yet."
    `Domain/AgentRoster.swift`
"Sent through their form."
    `Domain/FormOutreach.swift`
"Sent through their form. Overture is watching the email conversation you linked."
    `Domain/FormOutreach.swift`
"Sent through their form. You told Overture they replied."
    `Domain/FormOutreach.swift`
"Sent, waiting to hear back"
    `Domain/InquiryCopy.swift`
"Separate several addresses with commas to email more than one person."
    `Domain/ManualPrepPrefill.swift`
"Set aside"
    `Domain/ClientCoverage.swift`
"Set aside \(name). It will not show as a coverage gap."
    `Domain/ClientCoverage.swift`
"Set this show's genre"
    `UI/QueueView+Model.swift`
"Set this show's genre before you keep or dismiss it."
    `Domain/GenreGate.swift`
"Set up Overture"
    `App/AppDelegate.swift`
    `UI/OnboardingView.swift`
"Set up Overture…"
    `App/MenuBarContent.swift`
"Shoots leave the export one at a time, as their dates pass, and the furthest of these was not until \(furthest), so all of them going together reads as a broken export rather than an empty diary. Re-export it from Downbeat, then re-read it here."
    `Domain/AppNotice.swift`
"Show date to be confirmed"
    `UI/ReachedOutRowChrome.swift`
"Show in Finder"
    `App/StoreUnavailableView.swift`
"Show me the backups"
    `UI/StoreShrinkNoticeSheet.swift`
"Show name"
    `UI/ProspectRowView.swift`
"Show the scout that's running. Hiding its window doesn't stop it."
    `App/RootView.swift`
"Show the whole \(what), then send it"
    `UI/SendConfirmSheet.swift`
"Show this email the way a recipient reading in light or dark mode sees it."
    `Domain/DraftReviewNotes.swift`
"Show which bookings were auto-detected"
    `UI/OutcomePatternsView.swift`
"Shows in \(town) can appear again"
    `App/ActionFeedback.swift`
"Shows land here once Overture has tracked at least one."
    `Domain/EmptyState.swift`
"Shows written off that could be reached"
    `UI/WrittenOffBacklogSection.swift`
"Shows you've pitched and are waiting to hear back on."
    `Domain/AgentRoster.swift`
"Shows you've pitched that need something from you: a nudge, a possible reply to check, or how it ended."
    `Domain/AgentRoster.swift`
"Silent follow-ups"
    `UI/FollowUpsView.swift`
"Skip again"
    `UI/ExcludedTownsView.swift`
"Skipped towns"
    `App/RootView.swift`
    `UI/ExcludedTownsView.swift`
"Snoozed \(org). I'll remind you later."
    `App/ActionFeedback.swift`
"Social DM only"
    `Domain/Reachability.swift`
"Some changed calendars couldn't be read this run."
    `Domain/ScoutWarnings.swift`
"Some of your shows may be missing"
    `App/StoreShrinkCheck.swift`
"Some results came back under an unknown source and were ignored this run."
    `Domain/ScoutWarnings.swift`
"Someone reaching out to hire you. You write the first reply yourself."
    `UI/InquiryIntakeSheet.swift`
"Something went wrong"
    `App/RootView.swift`
"Source listing"
    `UI/QueueView+Model.swift`
"Sources (\(count))"
    `Domain/SourceAttention.swift`
"Sources you stopped watching."
    `Domain/SourceGrade.swift`
"Stalled reply drafts"
    `Domain/StalledReplyDraft.swift`
"Start a new experiment"
    `UI/ExperimentReportView.swift`
"Start at login"
    `UI/OnboardingView.swift`
"Start experiment"
    `UI/ExperimentReportView.swift`
"States a rate other than $250 an hour plus tax"
    `Domain/DraftCheck.swift`
"Stern Auditorium / Perelman Stage"
    `Domain/VenueParser.swift`
"Still blocked by \(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])."
    `Domain/CancelledShootCopy.swift`
"Still blocked by \(names[0])."
    `Domain/CancelledShootCopy.swift`
"Still not granted. Allow Overture in the prompt, or in System Settings ▸ Privacy & Security ▸ Automation."
    `Domain/OnboardingState.swift`
"Still watched and still checked. Overture will keep reporting these every run rather than quietly giving up on them."
    `Domain/SourceGrade.swift`
"Stop keeping this night clear for this shoot. It stays in Downbeat; Overture just stops protecting it."
    `Domain/CancelledShootCopy.swift`
"Stop sending to this contact"
    `Domain/FollowUp.swift`
"Stop the reply drafting run"
    `UI/ReplyConversationView.swift`
"Stop watching"
    `UI/SourceFixConfirmActions.swift`
"Stopped at their request"
    `Domain/SourceGrade.swift`
"Stopped watching \(org). Overture keeps what it found, and you can watch them again any time."
    `App/ActionFeedback.swift`
"Stopped working"
    `Domain/ArchiveStatus.swift`
"Stopped working this"
    `Domain/PerformanceStatus.swift`
"Stopping the run (\(elapsed))"
    `Domain/RunProgress.swift`
"Street, city, state"
    `UI/SourcesView.swift`
"Sync is off. Turn it on from the OmniFocus menu in the toolbar, and the look-ahead window appears here."
    `UI/OmniFocusSettingsView.swift`
"Sync now"
    `App/RootView.swift`
    `Domain/AppNotice.swift`
"Sync window…"
    `App/RootView.swift`
"Synced \(PrepStatus.relative(from: lastSuccessAt, to: now))"
    `Domain/OmniFocusSyncStatus.swift`
"Tagged a returning client: shows surface up to a year ahead."
    `Domain/ClientTagCopy.swift`
"Tagged as returning client \(namedClient): shows surface up to a year ahead."
    `Domain/ClientTagCopy.swift`
"Take \(address) off this reply and stop this show emailing it"
    `Domain/ReplyPanel.swift`
"Take this source off the watchlist. You can put it back any time"
    `UI/SourceFixConfirmActions.swift`
"Thalia Spanish Theatre"
    `Domain/VenueParser.swift`
"That address is missing the part Overture needs to read this venue's calendar."
    `Integration/SourceFetcher.swift`
"That calendar has more months on it (\(list(unreachable.map(name)))), but it moves between them in a way I can't follow yet, so I only read the month it opened on. Paste \(one ? "that month's" : "a month's") own link and I'll read it."
    `UI/LeadIntakeModel.swift`
"That calendar was drawn by JavaScript, so there was nothing to read in the page the last scout fetched."
    `Domain/WatchedSource.swift`
"That calendar's feed answered but nothing could be read from it, so its format has probably changed."
    `Integration/SourceFetcher.swift`
"That contact"
    `App/ActionFeedback.swift`
"That didn't send. You can try again."
    `Domain/ReplyPanel.swift`
"That doesn't look like a link. Paste the web address of the show or the org's events page."
    `UI/LeadIntakeModel.swift`
"That doesn't look like a web address."
    `Domain/WatchlistEditing.swift`
"That isn't a date Overture can read."
    `Domain/DayOff.swift`
"That link redirected to a different site (\(h)). Check the address."
    `Integration/SourceFetcher.swift`
"That link wasn't a web page (it served \(type ?? "an unknown type"))."
    `Integration/SourceFetcher.swift`
"That page couldn't be read."
    `Domain/WatchedSource.swift`
"That page doesn't list any dated events. It may not be their events page: try the link that shows their season or calendar."
    `Domain/LeadIntake.swift`
"That page had no dated listings on it when the last scout read it. It may be the wrong page for this org."
    `Domain/WatchedSource.swift`
"That page has more on it than I could read in one pass, and I didn't find a show in the part I did read. Try again, or paste a narrower link (a specific month or season) if it keeps happening."
    `Domain/LeadIntake.swift`
"That page has not been read. The next scout will try it again."
    `Domain/WatchedSource.swift`
"That show had already moved on, so there was nothing to undo"
    `App/ActionFeedback.swift`
"That site answered, but its secure connection was broken, so the page couldn't be read. A re-check won't clear this."
    `Integration/SourceFetcher.swift`
"That was \(named[0])."
    `Domain/SourceReadability.swift`
"That's longer than a year. Block a shorter stretch."
    `Domain/DayOff.swift`
"The Downbeat client export couldn't be read (it may be corrupted, or not the shape Overture expects), so the scout treated every prospect as cold. Re-export it from Downbeat."
    `Domain/DownbeatExport.swift`
"The Prep run finished but didn't produce any results. It may have hit an error or found no contacts."
    `Domain/DetachedRunOutcome.swift`
"The act takes messages through the form on their own site. You'd fill that in yourself; Overture can't send it for you."
    `Domain/Reachability.swift`
"The address found here is in a different name from the contact on this show, and no page was recorded showing it reaches them. A pitch would greet one person and arrive with another, so Overture is holding it. If it does reach them, clear the flag on the contact and it is sendable again."
    `Domain/Reachability.swift`
"The calendar reader ran but produced nothing this run."
    `Domain/ScoutWarnings.swift`
"The calendars Overture re-checks on every scout, and how each one is doing"
    `Domain/SourceAttention.swift`
"The calendars Overture re-checks on every scout."
    `UI/SourcesView.swift`
"The check couldn't name anyone to research for this show, so it never got as far as looking for an address. If you know who puts this on, add a contact by hand and it's back in play."
    `Domain/Reachability.swift`
"The check named a way in and gave none"
    `Domain/EmptyAnswerReport.swift`
"The check named the page it read this address off, but that page doesn't tie this person to this performance, so Overture isn't treating it as verified. If you know it's them, say so on the review panel and it stops being called unverified."
    `Domain/Reachability.swift`
"The check said it had verified the address here but never named the page it read it off, so Overture isn't treating it as verified. It may well be right: if you recognise it, say so on the review panel and it stops being called unverified."
    `Domain/Reachability.swift`
"The city and state it's in"
    `UI/SourcesView.swift`
"The contact check finished but didn't produce any results. It may have hit an error, so no show was marked as checked."
    `Domain/DetachedRunOutcome.swift`
"The date is known"
    `UI/InquiryIntakeSheet.swift`
"The days Overture won't pitch you for."
    `UI/DaysOffView.swift`
"The days Overture won't pitch you for: your booked shoots, and the days you block."
    `Domain/DaysOffAttention.swift`
"The details are in run-boundary-violation.log, in the same folder as the store."
    `Domain/RunBoundaryViolations.swift`
"The email that will send"
    `UI/SendConfirmSheet.swift`
"The email that will send, edit it here"
    `UI/SendConfirmSheet.swift`
"The file is there but Overture could not make sense of it, so nothing in the queue is known to be a free night and the scout cannot keep clear of your bookings. Re-export it from Downbeat, then re-read it here."
    `Domain/AppNotice.swift`
"The installer could not reach GitHub to check whether this build's code had been merged."
    `Domain/BuildFreshnessPanel.swift`
"The last day is before the first day."
    `Domain/DayOff.swift`
"The last follow-up sync failed. Tap Retry sync to try again."
    `Integration/OmniFocusUserNotifier.swift`
"The lookups already under way are finishing, so this takes a moment. Their answers will still be saved."
    `Domain/Reachability.swift`
"The only listing for this one is a social page, which sits behind a login, so there's no way in from there. You can still keep it and add a contact by hand. This is a heads up so you don't dismiss a reachable show in its place."
    `Domain/Reachability.swift`
"The other \(missed) had"
    `App/ActionFeedback.swift`
"The other one had"
    `App/ActionFeedback.swift`
"The page answered with HTTP \(code)."
    `Integration/SourceFetcher.swift`
"The page came back as \(v.rawValue)."
    `Domain/WatchedSource.swift`
"The page has changed since it was last read. Confirming now won't stick until you read it again."
    `UI/SourceFixConfirmActions.swift`
"The pages that changed couldn't be handed off to be read (\(error)). They'll be tried again on the next scout."
    `Integration/ScoutService.swift`
"The pitch to \(first.email) for \(first.show) bounced, so nobody ever read it."
    `Domain/AppNotice.swift`
"The reader came back with nothing for that page. Try again, or paste the org's events page."
    `UI/LeadIntakeModel.swift`
"The reader didn't finish in time. It may still be running; try again in a minute."
    `UI/LeadIntakeModel.swift`
"The reader finished without producing anything for that page, so nothing was read. Try again, and if it keeps happening the page may be one it can't make sense of."
    `UI/LeadIntakeModel.swift`
"The reader that pulls listings off a page isn't set up yet, so the pages that changed couldn't be read. See docs/scout-extract-runbook.md. Nothing was lost: they'll be read on the next scout once it's configured."
    `Integration/ScoutService.swift`
"The reply drafter finished but didn't produce a draft. It may have hit an error."
    `Domain/DetachedRunOutcome.swift`
"The room its shows play in"
    `UI/SourcesView.swift`
"The run returned results under \(ids.count) sources it was never asked about (\(list)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
    `Domain/ScoutWarningCopy.swift`
"The run returned results under a source it was never asked about (\(list)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
    `Domain/ScoutWarningCopy.swift`
"The run said every listing on this page was in the past but still returned \(shows(count)) from it."
    `Domain/ScoutResultAudit.swift`
"The run said it never read this page but still returned \(shows(count)) from it."
    `Domain/ScoutResultAudit.swift`
"The run said this page could not be read but still returned \(shows(count)) from it."
    `Domain/ScoutResultAudit.swift`
"The run said this page had no dated listings but still returned \(shows(count)) from it."
    `Domain/ScoutResultAudit.swift`
"The scheduled scout couldn't run. It'll try again later."
    `Domain/ScoutFailure.swift`
"The scout couldn't read \(labels.count) parts of its own store (\(list)), so this run judged against less than Overture actually holds. Nothing was lost. Run it again to get the full picture."
    `Domain/ScoutWarningCopy.swift`
"The scout couldn't read \(list), so this run judged against less than Overture actually holds. Nothing was lost. Run it again to get the full picture."
    `Domain/ScoutWarningCopy.swift`
"The scout couldn't run. This stopped the whole run, so no source was checked. Try again; if it keeps failing, something is wrong with the local store rather than with any one calendar.\n\nDetails: \(message)"
    `Domain/ScoutFailure.swift`
"The scout couldn't save its results. Run it again."
    `Domain/ScoutWarnings.swift`
"The scout ran but couldn't save its results. Run it again; if this keeps happening, something's wrong with the local store."
    `Domain/ScoutWarningCopy.swift`
"The scout started reading the calendars that changed, but the run finished without producing anything. Those pages have NOT been read, and it will try them again on the next scout."
    `Domain/DetachedRunOutcome.swift`
"The service replied, so this is not a connection problem: what came back was not what Overture expected. One bad answer is normal and says nothing here; this line appears only once several in a row have failed, and it clears as soon as one is readable again."
    `Domain/AppNotice.swift`
"The shoot history file couldn't be read (it may be corrupted or a newer format), so pitches can't mention rooms you've photographed before. Re-run the shoot-history import."
    `Domain/ShootHistory.swift`
"The show on \(dateLabel) is dismissed as \(reason.label)"
    `App/ActionFeedback.swift`
"The show's status, read from its contacts. Mark a contact below to change it."
    `UI/DraftReviewView.swift`
"The update never started. Ask Claude to look."
    `Domain/UpdateAttempt.swift`
"The update stopped without saying why. Ask Claude to look."
    `Domain/UpdateAttempt.swift`
"Their calendar, not one show: a single show's page never changes again, so watching it would watch nothing."
    `UI/SourcesView.swift`
"Their email (optional)"
    `UI/InquiryIntakeSheet.swift`
"Their events or season page"
    `UI/SourceFixConfirmActions.swift`
    `UI/SourcesView.swift`
"Their name"
    `UI/InquiryIntakeSheet.swift`
"Their reply is here and you've already answered it."
    `Domain/ProposedConversation.swift`
"Their reply is here and you've already answered it. Email goes to \(address) from now on."
    `Domain/ProposedConversation.swift`
"Their shows sit oddly for a company. Correct one from any of its shows if it looks wrong."
    `UI/OrganisationsView.swift`
"There's no linked conversation on this pitch to unlink."
    `Domain/DetachConversation.swift`
"These are files written by something outside the app, a detached run or an install script, and they're still on disk in Overture's own folder. Nothing here can repair one. A line clears as soon as its file reads cleanly again."
    `Domain/AppNotice.swift`
"These contacts have different drafts, so one shared email would send one of them to everyone. Send them separately, or make the drafts match"
    `App/ActionFeedback.swift`
"These leads are no longer in your queue."
    `UI/QueueView.swift`
"These organizations asked not to be contacted. Overture no longer watches them, and will not draft to them."
    `Domain/SourceGrade.swift`
"They all leave your queue, filed as \(reason.label)."
    `Domain/BulkDismiss.swift`
"They all lose \(dateLabel), filed as \(reason.label), and turn up again under their next night."
    `Domain/BulkDismiss.swift`
"They got back to me"
    `Domain/HandMarkedReply.swift`
"They include \(named.joined(separator: " and ")), and \(others) \(plural)."
    `Domain/SourceReadability.swift`
"They lose \(dateLabel), filed as \(reason.label). \(list(runs)) play on past \(dateLabel) and turn up again under their next night; the other one leaves your queue."
    `Domain/BulkDismiss.swift`
"They lose \(dateLabel), filed as \(reason.label). \(list(runs)) play on past \(dateLabel) and turn up again under their next night; the rest leave your queue."
    `Domain/BulkDismiss.swift`
"They lose \(dateLabel), filed as \(reason.label). \(runs[0]) plays on past \(dateLabel) and turns up again under its next night; the other one leaves your queue."
    `Domain/BulkDismiss.swift`
"They lose \(dateLabel), filed as \(reason.label). \(runs[0]) plays on past \(dateLabel) and turns up again under its next night; the rest leave your queue."
    `Domain/BulkDismiss.swift`
"They replied"
    `Domain/InquiryCopy.swift`
"They said no"
    `Domain/ShowOutcome.swift`
"They said not now"
    `Domain/ShowOutcome.swift`
"They said the price was too high"
    `Domain/ShowOutcome.swift`
"This address is already in play on another show at this venue within a few days, so Overture is holding it rather than writing to the same person twice. If they are different bookings, clear the duplicate flag on the contact and it is sendable again."
    `Domain/Reachability.swift`
"This adds \(addresses.count) contacts."
    `Domain/ManualPrepPrefill.swift`
"This booking was auto-detected from Downbeat. Confirm it (it then moves out of the reach-out list), or reject a wrong match to pull it back out."
    `UI/ProspectRowView.swift`
"This copy did not come from the installer, so there is no record of what went into it."
    `Domain/BuildFreshnessPanel.swift`
"This copy is \(behindBy(installedAt: installedAt, shippedAt: shippedAt, now: now)) behind what has shipped, so anything fixed since then is not in front of you."
    `Domain/BuildFreshnessPanel.swift`
"This copy was built from unmerged code"
    `Domain/BuildFreshnessPanel.swift`
"This draft says \(named). The show is \(show)."
    `Domain/EventDateInDraft.swift`
"This draft won't send: \(what.isEmpty ? "a blocking issue" : what)."
    `Domain/DraftCheck.swift`
"This draft won't send: it doesn't open with a greeting. Edit it to add one."
    `Domain/DraftReviewNotes.swift`
"This draft won't send: it opens \"Hi \(greeted)\" but this contact is \(contact). Check who it is addressed to."
    `Domain/DraftReviewNotes.swift`
"This draft won't send: the greeting names one person but this email goes to \(audience). Open it \"Hello,\" instead."
    `Domain/DraftReviewNotes.swift`
"This group also performs at this venue on other dates"
    `UI/QueueView+Model.swift`
"This looks up a contact for the \(s.showCount) shows the last check never reached."
    `Domain/ProbeSelection.swift`
"This looks up a real contact for every still-open show on the "
    `Domain/ProbeSelection.swift`
"This looks up a real contact for the still-open show on \(dateLabel), so you can tell whether it's still emailable before you keep it. It spends a little on that lookup, only for the show you check here."
    `Domain/Reachability.swift`
"This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    `Domain/Reachability.swift`
"This looks up a real contact for this one show, even though it already has an answer."
    `Domain/ProbeSelection.swift`
"This looks up a real contact for this one show, which an earlier check never got an answer for."
    `Domain/ProbeSelection.swift`
"This opens Terminal and runs the install. Overture quits partway through and comes back on its own."
    `Domain/BuildFreshnessPanel.swift`
"This org asked not to be contacted, so none of their shows will be scouted or emailed. Tap to allow contact again."
    `UI/ProspectRowView.swift`
"This page is right"
    `UI/SourceFixConfirmActions.swift`
"This pitch already has a conversation linked. Detach that one first if you linked the wrong thread."
    `Domain/AttachConversation.swift`
"This production also plays \(list)."
    `UI/QueueView+Model.swift`
"This production also plays at \(venue) on \(dateLabel)."
    `UI/QueueView+Model.swift`
"This production also plays elsewhere on \(dateLabel)."
    `UI/QueueView+Model.swift`
"This replaces the email you wrote yourself with an AI draft. Replace it?"
    `Domain/ReprepRequest.swift`
"This run's results disagreed with themselves, so nothing from it was used."
    `Domain/WatchedSource.swift`
"This sends \(chosen) separate emails right now, one to each of these people. Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This sends one email right now, to \(who). Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This sends one email right now, to this recipient only. Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This sends one follow-up right now, to this recipient only. Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This should be their events or season page, not one show. A single show's page never changes again, so watching it would watch nothing."
    `UI/AddLeadSheet.swift`
"This show"
    `Domain/PrepLaunchCopy.swift`
    `Domain/SelfBookingConflict.swift`
"This show has been and gone."
    `Domain/ReachedOutClose.swift`
"This show names no organization, so there's nowhere to record that. Nothing was removed."
    `App/ActionFeedback.swift`
"This show opened before you triaged it, so it is no longer waiting on you"
    `UI/ProspectRowView.swift`
"This show was checked over 90 days ago, so that earlier result may have changed. Run Check reachability again to refresh it before you decide."
    `Domain/Reachability.swift`
"This show was in an earlier scout but has dropped out of the venue feed across the last two scouts, so it was likely cancelled or pulled. Your keep/dismiss history is preserved."
    `UI/ProspectRowView.swift`
"This town is on the skip list."
    `UI/QueueView+Model.swift`
"This was not a genuine reply (an auto-reply or out of office). Revert it; a new reply will still flag."
    `UI/DraftReviewView.swift`
"This was re-prepped \(PrepStatus.relative(from: lastServedAt, to: now)). Redo it anyway?"
    `Domain/ReprepRequest.swift`
"This wasn't a genuine bounce. Revert it; a new bounce still flags."
    `UI/DraftReviewView.swift`
"This wasn't a genuine reply (an auto-reply or out of office). Revert it; a new reply still flags."
    `UI/DraftReviewView.swift`
"Those \(count) shows had already moved on, so there was nothing to undo"
    `App/ActionFeedback.swift`
"Those were \(named[0]) and \(named[1])."
    `Domain/SourceReadability.swift`
"Timed out waiting for Google. Close any old browser tabs and try Connect Gmail again."
    `Integration/GmailAuthManager.swift`
"Times vary"
    `UI/QueueView+Model.swift`
"Too far"
    `Domain/ShowOutcome.swift`
"Too few sends to call anything yet. Both styles need at least \(experimentCallThreshold) sends before the reply rates mean much."
    `Domain/ExperimentReport.swift`
"Too soon"
    `Domain/ShowOutcome.swift`
"Took \(address) off this reply."
    `Domain/ReplyPanel.swift`
"Took \(address) off this reply. This show won't email them again."
    `Domain/ReplyPanel.swift`
"Towns Overture keeps out of your queue."
    `UI/ExcludedTownsView.swift`
"Towns you skipped"
    `UI/ExcludedTownsView.swift`
"Towns you've told Overture to skip. Take one back off the list here."
    `App/RootView.swift`
"Treat \(organisation) as the presenter instead"
    `UI/QueueView+Model.swift`
"Treat \(organisation) as the venue instead"
    `UI/QueueView+Model.swift`
"Treating \(organisation) as the presenter, so one contact can answer for all its shows"
    `App/ActionFeedback.swift`
"Treating \(organisation) as the venue, so its address won't answer for other people's shows"
    `App/ActionFeedback.swift`
"Tried \(ago)"
    `Domain/SourceReadState.swift`
"Try a different discipline, or clear the high-fit filter."
    `Domain/EmptyState.swift`
"Try a different status filter, or clear the search."
    `Domain/EmptyState.swift`
"Try again"
    `App/RootView.swift`
    `Domain/ProposedConversation.swift`
    `Domain/Reachability.swift`
"Try another link"
    `UI/AddLeadSheet.swift`
"Two sentences in a row are built the same way"
    `Domain/DraftCheck.swift`
"Undo \(actionLabel) and Days Off: \(subject)"
    `Domain/QueueUndoStack.swift`
"Undo \(actionLabel): \(subject)"
    `Domain/QueueUndoStack.swift`
"Undo that"
    `Domain/HandMarkedReply.swift`
"Unknown contact"
    `UI/QueueView+Model.swift`
"Unlink this conversation"
    `Domain/DetachConversation.swift`
"Until it can read one, nothing in the queue is known to be a free night, and the scout cannot keep clear of your bookings. Export your client list from Downbeat, then re-read it here."
    `Domain/AppNotice.swift`
"Unverified email found"
    `Domain/Reachability.swift`
"Update Overture"
    `Domain/BuildFreshnessPanel.swift`
"Updated \(org)'s address."
    `UI/SourceFixConfirmActions.swift`
"Updated \(org)'s classification"
    `App/ActionFeedback.swift`
"Use it instead"
    `Domain/ReplyPanel.swift`
"Venue (optional)"
    `UI/InquiryIntakeSheet.swift`
"Venue TBD"
    `Domain/VenueDisplay.swift`
"Venue calendar"
    `UI/QueueView+Model.swift`
"Venue: \(v)"
    `Domain/OmniFocusSync.swift`
"Venue: \(venue)"
    `UI/SourcesView.swift`
"View in Archive"
    `UI/FollowUpsView.swift`
"Voice guidance"
    `App/RootView.swift`
    `UI/VoiceGuidanceView.swift`
"Waiting for your answer (\(elapsed))"
    `Domain/RunProgress.swift`
"Waiting to be checked again."
    `Domain/Reachability.swift`
"Warm lead from a prior relationship"
    `UI/QueueView+Model.swift`
"Watch a calendar"
    `Domain/WatchlistEditing.swift`
"Watch again"
    `UI/SourcesView.swift`
"Watch it"
    `UI/SourcesView.swift`
"Watch the source you've typed, or clear it, before closing."
    `Domain/SourcesSheetClose.swift`
"Watched for \(days) \(dayWord) and has never read its calendar once. Check the link."
    `Domain/SourceAttention.swift`
"Watching \(org) again."
    `App/ActionFeedback.swift`
"Watching for replies and bookings"
    `App/MenuBarStatus.swift`
"Wave Hill"
    `Domain/VenueParser.swift`
"Weak contact only"
    `Domain/Reachability.swift`
"Weill Recital Hall"
    `Domain/VenueParser.swift`
"Went by"
    `Domain/ArchiveStatus.swift`
    `Domain/ShowOutcome.swift`
    `UI/ProspectRowView.swift`
"What converts"
    `App/RootView.swift`
    `UI/OutcomePatternsView.swift`
"What your genre corrections are teaching"
    `Domain/GenreCorrection.swift`
"When Overture reviewed every stored answer, no show turned out to have been recorded as unreachable while it held a way in."
    `UI/WrittenOffBacklogSection.swift`
"Which kept shows to prep?"
    `Domain/PrepSelectionCopy.swift`
"Which message is their reply?"
    `Domain/ProposedConversation.swift`
"Who Overture thinks puts each show on, and who it reads as the building."
    `App/RootView.swift`
"Who this goes to"
    `UI/SendConfirmSheet.swift`
"Why (optional): vacation, family, anything"
    `UI/DayOffRangeFields.swift`
"Why lost? (optional note)"
    `UI/DraftReviewView.swift`
"Will receive: \(body)"
    `Domain/DraftReviewNotes.swift`
"Without naming a client"
    `Domain/ClientTagCopy.swift`
"Won't learn from \(org)'s email"
    `App/ActionFeedback.swift`
"Won't show you shows in \(town) again"
    `App/ActionFeedback.swift`
"Worked together before"
    `UI/QueueView+Model.swift`
"Worked together before (\(name))"
    `UI/QueueView+Model.swift`
"Worth a look"
    `UI/OrganisationsView.swift`
"Write a first draft of this one reply, which you can then edit"
    `Domain/ReplyPanel.swift`
"Write the email before saving it"
    `App/ActionFeedback.swift`
"Write the email before saving it. Nothing was saved"
    `App/ActionFeedback.swift`
"Write this email yourself, with no Prep run and no AI draft"
    `UI/ProspectRowView.swift`
"Writes from here"
    `UI/QueueView+Model.swift`
"Written by AI"
    `Domain/ReplyPanel.swift`
"Written by you"
    `UI/QueueView+Model.swift`
"Wrong match"
    `UI/ProspectRowView.swift`
"Yes, link it"
    `Domain/ProposedConversation.swift`
"You already answered this one."
    `Domain/ReplyConversationMode.swift`
"You already answered this one. The draft below is kept as a record."
    `Domain/ReplyConversationMode.swift`
"You already have a pitch in progress for \(others) on \(label)."
    `Domain/SelfBookingConflict.swift`
"You already have a pitch in progress for \(others) on a later night of this run."
    `Domain/SelfBookingConflict.swift`
"You already have a pitch in progress for \(others) on this date."
    `Domain/SelfBookingConflict.swift`
"You already watch \(org) at that address."
    `UI/SourceFixConfirmActions.swift`
"You answered them"
    `UI/QueueView+Model.swift`
"You asked for this reply draft \(ago(requestedAt, now: now)) and it never arrived."
    `Domain/StalledReplyDraft.swift`
"You blocked \(day) (\(name))."
    `Domain/BlockedCalendar.swift`
"You blocked \(day)."
    `Domain/BlockedCalendar.swift`
"You confirmed this performer is a past client, so the fit score counts it and a draft can write to them as a returning client."
    `UI/QueueView+Model.swift`
"You dismissed \(org) because the dates don't work. Block the days you can't shoot, and Overture will stop pitching you for them."
    `Domain/DayOffOffer.swift`
"You emailed this address about \(outreach.showName) on \(when)."
    `Domain/ManualPrepPrefill.swift`
"You emailed this address on \(when)."
    `Domain/ManualPrepPrefill.swift`
"You entered days off but haven't blocked them yet."
    `UI/DaysOffView.swift`
"You have \(pointerPhrase(for: target, count: n)) next."
    `Domain/StageEmptyState.swift`
"You have already been in touch with them about this and answered their reply."
    `Domain/OmniFocusSync.swift`
"You linked their reply. It's waiting on you."
    `Domain/ProposedConversation.swift`
"You linked this conversation. Overture didn't email them."
    `Domain/AttachConversation.swift`
"You opened their form \(when). Did you send it?"
    `Domain/FormOutreach.swift`
"You opened their profile \(when). Did you send it?"
    `Domain/FormOutreach.swift`
"You said it isn't happening"
    `Domain/CancelledShootCopy.swift`
"You set this: \(what)"
    `UI/QueueView+Model.swift`
"You stopped sending to this contact \(ago(stoodDownAt, now: now))"
    `Domain/FollowUp.swift`
"You stopped working this"
    `UI/QueueView+Model.swift`
"You stopped working this show \(ago(stoodDownAt, now: now))"
    `Domain/FollowUp.swift`
"You struck \(address) off this show, so Overture won't link a conversation that would write it back onto the contact. Add the address back on the card first if you want to use it."
    `Domain/AttachConversation.swift`
"You struck this contact off the show, so Overture won't link a conversation to it. Add the contact back on the card first if you want to use it."
    `Domain/AttachConversation.swift`
"You told Overture they replied. Their message isn't here, because it didn't come by email."
    `Domain/ReplyPanel.swift`
"You told Overture to read \(name) as the building, not the presenter."
    `Domain/OrganisationListing.swift`
"You'll open a form or profile and write there by hand."
    `UI/DraftReviewView.swift`
"You'll see \(org) again in \(days) days. No email went out"
    `App/ActionFeedback.swift`
"You're already shooting \(name) on \(day)."
    `Domain/BlockedCalendar.swift`
"You're already shooting on \(day)."
    `Domain/BlockedCalendar.swift`
"You've already added that link. Its shows are in your queue, and once the watchlist is on, that organization gets re-checked on its own."
    `UI/LeadIntakeModel.swift`
"You've already answered on this conversation, so Overture can't unlink it. Your message is on their thread and unlinking wouldn't take it back."
    `Domain/DetachConversation.swift`
"You've already answered this one, so Overture can't take the reply back."
    `Domain/HandMarkedReply.swift`
"You've already logged an inquiry for this event. You can still add this one."
    `Domain/InquiryCopy.swift`
"You've said none of the messages Overture found are them. It'll keep looking while this pitch is open."
    `Domain/ProposedConversation.swift`
"Your Downbeat client export is \(days) days old, so a client booked since then may be missing from this list."
    `Domain/ClientCoverage.swift`
"Your Downbeat client export is \(days) days old. Recently booked clients may be missing, so some warm leads could look cold. Open Downbeat to refresh it."
    `Domain/DownbeatExport.swift`
"Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again."
    `Domain/GmailReconnectCopy.swift`
"Your Gmail access has expired or was revoked, so this conversation could not be linked. Nothing was sent and nothing changed. Click Connect Gmail to reconnect, then answer again."
    `Domain/GmailReconnectCopy.swift`
"Your Prep run is still going. Wait for it to finish before starting another."
    `Integration/PrepQueueService.swift`
"Your \(kind.runNoun) is still going"
    `Domain/PrepQueueButton.swift`
"Your contact check is still going. This will be available once it finishes."
    `Domain/Reachability.swift`
"Your contact check is still going. Wait for it to finish before starting another."
    `Integration/PrepQueueService.swift`
"Your reply goes to"
    `Domain/ReplyPanel.swift`
"Your reply went out and answers to it are still watched. What couldn't be read is the id a later message would quote, so a nudge on this inquiry will arrive as a separate email rather than under the same conversation."
    `Domain/InquiryCopy.swift`
"Your reply went out, but Gmail didn't tell Overture which conversation it landed in, so an answer to it won't be spotted automatically. Watch your inbox for this one and mark it here yourself."
    `Domain/InquiryCopy.swift`
"Your shoot history is \(days) days old, so rooms you've photographed since then won't be mentioned in a pitch. Re-export your Shoots calendar and run the import again."
    `Domain/ShootHistory.swift`
"Zankel Hall"
    `Domain/VenueParser.swift`
"\"\(outcome.label)\" isn't yours to set: Overture writes that one itself. \(org) is unchanged."
    `Domain/ShowOutcome.swift`
"\($0) (\(hall))"
    `Domain/VenueDisplay.swift`
"\($0.count) \($0.route)"
    `Domain/WebCallRefusals.swift`
"\($0.endpoint): \($0.failures) of \($0.attempts) unreadable, \($0.consecutiveFailures) in a row. \($0.lastReason ?? "no reason recorded")"
    `Domain/AppNotice.swift`
"\($0.file): \($0.reason)"
    `Domain/AppNotice.swift`
"\($0.orgName): \($0.state.failureMessage ?? "couldn't be checked")"
    `Integration/ScoutService.swift`
"\($0.show): \($0.email)"
    `Domain/AppNotice.swift`
"\(-days) days ago"
    `Domain/ReachedOutQueue.swift`
"\(Discipline.other.label). Set it."
    `UI/QueueView+Model.swift`
"\(Plural.count(count, "new lead")) while you were away"
    `UI/QueueView+Model.swift`
"\(Plural.count(count, "show")) \(Plural.word(count, "is", "are")) back in \(undoStageWord(for: priorStatuses))"
    `App/ActionFeedback.swift`
"\(Plural.count(count, "show")) on \(dateLabel)"
    `Domain/BulkDismiss.swift`
"\(Plural.count(count, "show")) on \(dateLabel) are dismissed as \(reason.label)"
    `App/ActionFeedback.swift`
"\(Plural.count(count, "show")) to prep"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) to review"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) to triage"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) you've pitched"
    `Domain/StageEmptyState.swift`
"\(a) vs \(b) "
    `UI/ExperimentReportView.swift`
"\(added) from watched calendars"
    `Domain/ScoutRunSummary.swift`
"\(address) isn't saved as a contact on this show."
    `Domain/ReplyPanel.swift`
"\(address), replied"
    `Domain/ReplyIdentity.swift`
"\(approved) approved"
    `Domain/PrepStatus.swift`
"\(arm.editedExcluded) edited (\(Int((rate * 100).rounded()))% of sends), excluded from the rate"
    `Domain/ExperimentReport.swift`
"\(arm.editedExcluded) edited, excluded from the rate"
    `Domain/ExperimentReport.swift`
"\(arm.tally.replied + arm.tally.booked) replied of \(arm.tally.contacted)"
    `Domain/ExperimentReport.swift`
"\(base) \($0)"
    `Domain/RunProgress.swift`
"\(base) looks stuck (\(elapsed))"
    `Domain/RunProgress.swift`
"\(bounced.count) pitches bounced, so nobody ever read them."
    `Domain/AppNotice.swift`
"\(calls) refused (\(list(named))): that research never happened"
    `Domain/WebCallRefusals.swift`
"\(calls) refused: that research never happened"
    `Domain/WebCallRefusals.swift`
"\(city), \(state)"
    `Domain/EventLocationFill.swift`
"\(clauses[cityIndex]), \(code)"
    `Domain/VenueDisplay.swift`
"\(closed) of them are runs whose other nights already have their own cards, so they are closed as duplicates"
    `App/ActionFeedback.swift`
"\(conceptSummary(for: focus)) \(detail)"
    `Domain/AgentRoster.swift`
"\(contacts.count) contacts"
    `UI/QueueView+Model.swift`
"\(contacts.count) found, \(reachable) reachable"
    `UI/QueueView+Model.swift`
"\(contacts.count) found, none reachable"
    `UI/QueueView+Model.swift`
"\(correctionsSeen) genre correction\(correctionsSeen == 1 ? "" : "s") recorded, and no word appears often enough yet to be worth adding to the classifier."
    `Domain/GenreCorrection.swift`
"\(count) \(count == 1 ? "contact" : "contacts") held for a check"
    `Domain/DraftReviewNotes.swift`
"\(count) \(outcome.countedPhrase ?? outcome.rawValue)"
    `Domain/OutcomePatterns.swift`
"\(count) \(prospectWord) already pending or re-prepped recently; nothing new queued"
    `App/ActionFeedback.swift`
"\(count) clients set aside"
    `Domain/ClientCoverage.swift`
"\(count) contacts named a way in and gave none, and the run never once said it found no route"
    `Domain/RunInstructionCompliance.swift`
"\(count) didn't come back, they'll be retried"
    `Domain/HandoffShortfall.swift`
"\(count) more shows stored a reason like these, but their own answers say they can be reached, so their cards never say it."
    `UI/EmptyAnswerSection.swift`
"\(count) of those are shows that name their producing organisation."
    `UI/EmptyAnswerSection.swift`
"\(count) shows have been checked and left with nobody to write to. What the checks claimed:"
    `UI/EmptyAnswerSection.swift`
"\(count) shows on \(dateLabel) have no genre read. Set them before dismissing the night."
    `Domain/GenreGate.swift`
"\(count) shows stored a reason with no answer recorded beside them at all, which is a fault in the check rather than a finding about those shows."
    `UI/EmptyAnswerSection.swift`
"\(count) shows were left out of this run. The local store stopped answering, so Overture could not tell whether they were new shows or cards you have already decided on, and it would rather skip them than write over one. Run the scout again to pick them up."
    `Domain/ScoutWarningCopy.swift`
"\(count) shows were left out this run because the local store stopped answering. Run the scout again."
    `Domain/ScoutWarnings.swift`
"\(count) shows were recorded as having no email to write to while they held a way in. Overture has since corrected them:"
    `UI/WrittenOffBacklogSection.swift`
"\(count) sources couldn't be checked."
    `UI/ScoutSummaryView.swift`
"\(count) sources need"
    `Domain/SourceAttention.swift`
"\(count) sources went quiet."
    `UI/ScoutSummaryView.swift`
"\(date) is dismissed as \(reason.label). Every other night of \(org) already has its own card, so this run card is closed as a duplicate."
    `App/ActionFeedback.swift`
"\(date) is dismissed as \(reason.label). \(nights) of \(org) already \(has), so this run \(gave) and now opens on \(next)."
    `App/ActionFeedback.swift`
"\(dates), \(shows)"
    `Domain/ProbeSelection.swift`
"\(deferredCount) venues are still waiting to be checked."
    `UI/ScoutSummaryView.swift`
"\(denied) web calls"
    `Domain/PrepRunSummary.swift`
"\(drafted) to review"
    `Domain/PrepStatus.swift`
"\(e) at \(v)"
    `Domain/InquiryCopy.swift`
"\(emails) emails sent. Nothing more until the show."
    `Domain/SpentNudges.swift`
"\(emails) emails sent. Nothing more until you close this out."
    `Domain/SpentNudges.swift`
"\(empties.count) established calendars came back empty this run."
    `Domain/ScoutWarnings.swift`
"\(empties[0].orgName) has listed shows before and came back empty this run."
    `Domain/ScoutWarnings.swift`
"\(endpoint) is answering, but not in a way Overture understands."
    `Domain/AppNotice.swift`
"\(entry.distinctShowCount) different titles"
    `Domain/OrganisationListing.swift`
"\(entry.rowCount) shows, \(titles), \(rooms)."
    `Domain/OrganisationListing.swift`
"\(event.title) \(presenter)"
    `Domain/EventClassifier.swift`
"\(explanation)\n\n\(detail)"
    `Domain/AppNotice.swift`
"\(f.count) sources couldn't be checked. Open Sources to fix or confirm them."
    `Domain/ScoutWarnings.swift`
"\(failed.count) sources couldn't be checked.\n\n"
    `Integration/ScoutService.swift`
"\(failing.count) of the services Overture reads are answering with something it can't read, so it's working from nothing there."
    `Domain/AppNotice.swift`
"\(filed) \(note)"
    `Domain/BulkDismiss.swift`
"\(first) and \(names[1])"
    `Domain/OmniFocusSync.swift`
"\(first) and \(rest) other\(rest == 1 ? "" : "s")"
    `Domain/SelfBookingConflict.swift`
"\(first), \(names[1]) and \(names.count - 2) more"
    `Domain/OmniFocusSync.swift`
"\(found) times"
    `Domain/RunBoundaryViolations.swift`
"\(i.followUpsDue) due"
    `Domain/AgentRoster.swift`
"\(i.followUpsDue) due, somebody may have answered"
    `Domain/AgentRoster.swift`
"\(i.keptToPrep) ready to prep"
    `Domain/AgentRoster.swift`
"\(i.reachedOutDue) due"
    `Domain/AgentRoster.swift`
"\(i.readyToSend) approved, connect Gmail to send"
    `Domain/AgentRoster.swift`
"\(i.sendErrors) failed to send"
    `Domain/AgentRoster.swift`
"\(i.toTriage) to triage"
    `Domain/AgentRoster.swift`
"\(kept) to prep"
    `Domain/PrepStatus.swift`
"\(label), \(calendar.component(.year, from: date))"
    `Domain/EasternDate.swift`
"\(label)… \(elapsed)"
    `Domain/RunProgress.swift`
"\(lead) It has happened \(howMany). \(evidence)"
    `Domain/RunBoundaryViolations.swift`
"\(list(runs)) run past \(dateLabel), so dismissing them takes their later nights too."
    `Domain/BulkDismiss.swift`
"\(list) has listed shows before and came back with nothing this run. Its page format may have changed."
    `Domain/ScoutWarningCopy.swift`
"\(live.name): \(live.detail)"
    `UI/QueueView.swift`
"\(longMonth(calendar.component(.month, from: d))) \(calendar.component(.day, from: d))"
    `Domain/EasternDate.swift`
"\(lookups), \(wait)."
    `Domain/ProbeSelection.swift`
"\(lookups), \(wait): shows by the same producer share one."
    `Domain/ProbeSelection.swift`
"\(min(completed, total)) of \(total) done"
    `UI/RunProgressView.swift`
"\(min(progress.completed, progress.total)) of \(progress.total)"
    `Domain/ReplyClassifyProgress.swift`
    `Domain/ScoutExtractProgress.swift`
"\(months[month - 1]) \(year)"
    `UI/LeadIntakeModel.swift`
"\(n) \(shows(n)) sent, but a later nudge will arrive as a new email, not a reply"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) sent, but replies can't be tracked: check Gmail"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) with a contact held for a check"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) with an unconfirmed send: check Gmail"
    `Domain/AgentRoster.swift`
"\(n) \(word(n, singular, plural))"
    `Domain/Plural.swift`
"\(n) new shows waiting for you"
    `Domain/SourceYield.swift`
"\(n) reply draft\(n == 1 ? "" : "s") stalled"
    `Domain/AgentRoster.swift`
"\(n) shows"
    `Domain/ScoutResultAudit.swift`
"\(name) (\(address))"
    `Domain/ProposedConversation.swift`
"\(name) is a room's name, so Overture reads it as the building, not the presenter."
    `Domain/OrganisationListing.swift`
"\(name) is holding that night again"
    `Domain/CancelledShootCopy.swift`
"\(name) may already be pitched for a nearby show; blocked from sending."
    `Domain/DraftReviewNotes.swift`
"\(name) may be a press/media contact, not the act; blocked from sending."
    `Domain/DraftReviewNotes.swift`
"\(name) may be the venue itself, not the act; blocked from sending."
    `Domain/DraftReviewNotes.swift`
"\(name) overlaps a room's name, so Overture reads it as the building, not the presenter."
    `Domain/OrganisationListing.swift`
"\(name) will instead receive:"
    `Domain/DraftReviewNotes.swift`
"\(name) won't hold that night any more"
    `Domain/CancelledShootCopy.swift`
"\(names.count) new booking\(names.count == 1 ? "" : "s") (\(names.joined(separator: ", ")))"
    `Domain/OutreachEventPhrasing.swift`
"\(names.count) new repl\(names.count == 1 ? "y" : "ies") (\(names.joined(separator: ", ")))"
    `Domain/OutreachEventPhrasing.swift`
"\(night) \($0)"
    `Integration/ScoutService.swift`
"\(nightDismissed(count: count, reason: reason, dateLabel: dateLabel)). \(tail)"
    `App/ActionFeedback.swift`
"\(omniFocusChanged) follow-up\(omniFocusChanged == 1 ? "" : "s") updated"
    `Domain/ReconcileSummary.swift`
"\(opening) to \(closing)"
    `Domain/EventDateInDraft.swift`
"\(org) already moved on, so there was nothing to undo"
    `App/ActionFeedback.swift`
"\(org) can be drafted despite the clash"
    `App/ActionFeedback.swift`
"\(org) closed out: never heard back."
    `Domain/ShowOutcome.swift`
"\(org) closed out: they said no."
    `Domain/ShowOutcome.swift`
"\(org) closed out: they said not now."
    `Domain/ShowOutcome.swift`
"\(org) closed out: they said the price was too high."
    `Domain/ShowOutcome.swift`
"\(org) closed out: you turned them down."
    `Domain/ShowOutcome.swift`
"\(org) dismissed as a duplicate."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: date conflict."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: no way to reach them."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: not a fit."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: pitching other shows that night."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: too soon to pitch it."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: you don't want to shoot this."
    `Domain/ShowOutcome.swift`
"\(org) dismissed: you had paid work."
    `Domain/ShowOutcome.swift`
"\(org) has already been sent to, so there's nothing to redraft"
    `App/ActionFeedback.swift`
"\(org) has already been sent to; re-prepping to find new contacts only"
    `App/ActionFeedback.swift`
"\(org) is back in \(undoStageWord(for: priorStatus))"
    `App/ActionFeedback.swift`
"\(org) is drafted and ready for you to review"
    `App/ActionFeedback.swift`
"\(org) is in a town you asked not to see."
    `Domain/ShowOutcome.swift`
"\(org) is open again. \"\(outcome.label)\" is no longer recorded against it."
    `Domain/ShowOutcome.swift`
"\(org) recorded as booked."
    `Domain/ShowOutcome.swift`
"\(org) was already pitched, so \"\(outcome.label)\" doesn't apply to it. Nothing changed."
    `Domain/ShowOutcome.swift`
"\(org) went by before it was triaged."
    `Domain/ShowOutcome.swift`
"\(org.orgName) (\(Plural.count(org.showCount, "show")))"
    `Domain/SuppressionReport.swift`
"\(orgName) asked not to be contacted, so Overture won't watch their calendar."
    `Domain/WatchlistEditing.swift`
"\(orgName) asked not to be contacted, so Overture won't watch them again."
    `Domain/WatchlistEditing.swift`
"\(outcome.drafted) drafted"
    `Domain/PrepRunSummary.swift`
"\(outcome.found) found"
    `Domain/ScoutRunSummary.swift`
"\(outcome.inserted) new"
    `Domain/ScoutRunSummary.swift`
"\(outcome.skippedEdited) kept your edits"
    `Domain/PrepRunSummary.swift`
"\(outcome.skippedHandWritten) left as you wrote them"
    `Domain/PrepRunSummary.swift`
"\(outcome.unmatchedKeys.count) didn't match"
    `Domain/PrepRunSummary.swift`
"\(p.groupName), follow up with \(displayName(r))"
    `Domain/OmniFocusSync.swift`
"\(p.groupName), reply to \(displayName(r))"
    `Domain/OmniFocusSync.swift`
"\(parts[0]), \(parts[1])"
    `Domain/EventLocationFill.swift`
"\(path(context)) is not the expected type (\(type))"
    `Domain/HandoffDecodeFailure.swift`
"\(path) is the wrong type or empty"
    `Domain/ResponseBody.swift`
"\(pending) calendars have new listings to read."
    `Domain/ScoutReadBudget.swift`
"\(piece) is not an email address"
    `App/ActionFeedback.swift`
"\(piece) is not an email address or a link. No contact was added"
    `App/ActionFeedback.swift`
"\(piece) is not an email address. Nothing was saved"
    `App/ActionFeedback.swift`
"\(placed) shows"
    `UI/SourcesView.swift`
"\(progress.completed) of \(progress.total)"
    `Domain/PrepProgress.swift`
"\(range) is no longer blocked"
    `App/ActionFeedback.swift`
"\(range) is now blocked"
    `App/ActionFeedback.swift`
"\(readNothing.count) sources have listed shows before and came back with nothing this run: \(list). Their page formats may have changed."
    `Domain/ScoutWarningCopy.swift`
"\(readable) shows listed, down from the usual \(baseline), so Overture won't mark anything from this source as gone until the smaller calendar holds."
    `Domain/SourceReadability.swift`
"\(reason) Those reminders are not there, and running the sync again will not change it."
    `Domain/OmniFocusFailureKind.swift`
"\(released) later nights"
    `App/ActionFeedback.swift`
"\(runs[0]) runs past \(dateLabel), so dismissing it takes its later nights too."
    `Domain/BulkDismiss.swift`
"\(s)\n\n\(c)"
    `Domain/PrepLaunchCopy.swift`
"\(s.alreadyAnsweredCount) more "
    `Domain/ProbeSelection.swift`
"\(s.dateCount) dates"
    `Domain/ProbeSelection.swift`
"\(s.organisationCount) named producers answer for several shows each; \(s.performerHuntCount) "
    `Domain/ProbeSelection.swift`
"\(s.previouslyMissedCount) of them went through an earlier check and never got an answer."
    `Domain/ProbeSelection.swift`
"\(s.researchCount) lookups"
    `Domain/ProbeSelection.swift`
"\(s.showCount) shows"
    `Domain/ProbeSelection.swift`
"\(sends) of \(experimentCallThreshold) sends toward a reliable read"
    `Domain/ExperimentReport.swift`
"\(sends) sends in, enough for the rate to mean something"
    `Domain/ExperimentReport.swift`
"\(shortMonth(c.month ?? 1)) \(c.day ?? 0)"
    `UI/QueueView+Model.swift`
"\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
    `UI/QueueView+Model.swift`
"\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d)) at \(joined)"
    `UI/QueueView+Model.swift`
"\(shortMonth(cal.component(.month, from: e))) \(cal.component(.day, from: e))"
    `UI/QueueView+Model.swift`
"\(shortMonth(calendar.component(.month, from: d))) \(calendar.component(.day, from: d))"
    `Domain/EasternDate.swift`
"\(show) is on a date you already have a pitch in progress for \(others)."
    `Domain/SelfBookingConflict.swift`
"\(show) plays \(label), when you already have a pitch in progress for \(others)."
    `Domain/SelfBookingConflict.swift`
"\(show) plays a later night of its run when you already have a pitch in progress for \(others)."
    `Domain/SelfBookingConflict.swift`
"\(show): \(clash.note)"
    `Domain/PrepLaunchCopy.swift`
"\(showCount) shows"
    `UI/SourcesView.swift`
"\(showName), closed out"
    `Domain/DepartureCopy.swift`
"\(shows) waiting on this"
    `UI/SourcesView.swift`
"\(source.droppedRowCount) shows"
    `Domain/ScoutWarningCopy.swift`
"\(source.orgName) listed \(shows) this run and every one was dropped, so its page is being read fine. Open Sources to see why they were dropped."
    `Domain/ScoutWarningCopy.swift`
"\(stamp(now)) \(message)\n"
    `App/AgentLog.swift`
"\(stamp) \(nothingCopiedLogNote)"
    `App/StoreBackup.swift`
"\(stamp) \(outcome)"
    `App/StoreBackup.swift`
"\(startLabel) to \(endLabel)"
    `UI/QueueView+Model.swift`
"\(status.name): \(status.detail)"
    `UI/QueueView.swift`
"\(structuralGaps) of \(total) listings named no venue, so Overture left \(left) out of the queue."
    `Domain/SourceReadability.swift`
"\(subject) a look: failing, never read at all, empty run after run, or can't mark shows as gone until it reads its calendar properly again"
    `Domain/SourceAttention.swift`
"\(subject) you to stop still \(verb) on calendars you watch: \(who). Nothing was added and nothing will go out to them."
    `Domain/SuppressionReport.swift`
"\(subject), \(f.localizedString(for: sentAt, relativeTo: now))"
    `Domain/ProposedConversation.swift`
"\(suggestions) word\(suggestions == 1 ? "" : "s") worth adding to the classifier, from \(correctionsSeen) correction\(correctionsSeen == 1 ? "" : "s")."
    `Domain/GenreCorrection.swift`
"\(tally.booked) booked of \(tally.contacted)"
    `Domain/OutcomePatterns.swift`
"\(tally.bookedAuto) auto-detected"
    `Domain/OutcomePatterns.swift`
"\(tally.bookedManual) confirmed by you"
    `Domain/OutcomePatterns.swift`
"\(tally.kept) of \(reviewed) kept after review"
    `Domain/SourceYield.swift`
"\(tally.replied + tally.booked) replied"
    `Domain/OutcomePatterns.swift`
"\(titleRejected) of \(total) shows had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
    `Domain/SourceReadability.swift`
"\(titleRejected) of \(total) shows had no title."
    `Domain/SourceReadability.swift`
"\(to) · nudge \(attempt(after: followUpCount)) of \(config.maxFollowUps)"
    `Domain/FollowUp.swift`
"\(toReview) to review"
    `Domain/DraftedDeadEnd.swift`
"\(toReview) to review, \(deadEnds) with nobody to send to"
    `Domain/DraftedDeadEnd.swift`
"\(total) web calls for \(shows)\(people), more than expected"
    `Domain/PrepRunSummary.swift`
"\(town) is already on your skip list"
    `App/ActionFeedback.swift`
"\(trimmed) on \(day)"
    `Domain/SourceReadability.swift`
"\(unanswered) of \(requested) shows never got an answer and are still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"\(unchecked) runs were left alone: Overture could not check whether their next nights are free"
    `App/ActionFeedback.swift`
"\(undoRestoredNight(count: restored, priorStatuses: priorStatuses)). \(others) already moved on."
    `App/ActionFeedback.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page, so Overture won't mark anything from this source as gone until it can confirm one."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page."
    `Domain/SourceReadability.swift`
"\(waiting) · \(kept)"
    `Domain/SourceYield.swift`
"\(web.items) shows"
    `Domain/PrepRunSummary.swift`
"\(what) stopped before it finished. Overture has cleared it, so you can start again."
    `UI/RunProgressView.swift`
"\(where_) could not be read"
    `Domain/HandoffDecodeFailure.swift`
"\(who) is already a recipient on \(org)."
    `App/ActionFeedback.swift`
"\(worst.name) is flagged as a possible match on \(worst.count) shows, which usually means the match is wrong."
    `Domain/PossibleMatchFanOut.swift`
"\(writer) wrote, and this reply would go to \(Plural.list(audience)) instead, so Overture won't send it. Answer this one in Gmail."
    `Domain/ReplyPanel.swift`
"\n\nLast lines of the run log:\n\(tail)"
    `Domain/DetachedRunOutcome.swift`
    `UI/LeadIntakeModel.swift`
"\n\nLeft out: "
    `Domain/ScoutWarningCopy.swift`
"_(Removed: the auto-generated guidance contained a specific name and was quarantined; it will regenerate on the next Prep run.)_"
    `Domain/VoiceGuidanceGuard.swift`
"a field is the wrong type"
    `Domain/ResponseBody.swift`
"a field the response should carry is missing: \(key.stringValue)"
    `Domain/ResponseBody.swift`
"a past client"
    `UI/QueueView+Model.swift`
"a required field is empty: \(path(context))"
    `Domain/HandoffDecodeFailure.swift`
"a required field is missing: \(path(context, adding: key))"
    `Domain/HandoffDecodeFailure.swift`
"a show that wrote back"
    `UI/QueueView+Model.swift`
"a show you booked in Overture"
    `UI/QueueView+Model.swift`
"a show you dismissed in Overture"
    `UI/QueueView+Model.swift`
"a show you emailed in Overture"
    `UI/QueueView+Model.swift`
"about 1 minute"
    `Domain/ProbeSelection.swift`
"about \(minutes) minutes"
    `Domain/ProbeSelection.swift`
"across \(entry.distinctVenueCount) rooms"
    `Domain/OrganisationListing.swift`
"all \(count) of these people"
    `UI/SendConfirmSheet.swift`
"all in one room"
    `Domain/OrganisationListing.swift`
"all the same title"
    `Domain/OrganisationListing.swift`
"another show"
    `Domain/SelfBookingConflict.swift`
"at \(v)"
    `Domain/InquiryCopy.swift`
"at \(venue) on \(dateLabel)"
    `UI/QueueView+Model.swift`
"book now"
    `Domain/TicketLink.swift`
"both of these people"
    `UI/SendConfirmSheet.swift`
"couldn't read \(read.label). (\(underlying))"
    `Integration/ScoutService.swift`
"couldn't save the producer answers, so other shows by them won't reuse this one"
    `Domain/ReachabilityRunSummary.swift`
"couldn't save what this check found, so it isn't finished and those shows may be checked again"
    `Domain/ReachabilityRunSummary.swift`
"couldn't save, try again"
    `Domain/PrepRunSummary.swift`
"date unknown"
    `Domain/ReachedOutQueue.swift`
"delivery failed"
    `Domain/BounceDetection.swift`
"drafter used this shape on \(Int((rate * 100).rounded()))% of sends"
    `Domain/ExperimentReport.swift`
"elsewhere on \(dateLabel)"
    `UI/QueueView+Model.swift`
"event streams NOT archived (\(count) found): \(reason)"
    `App/PrepRunArchive.swift`
"gave it up"
    `App/ActionFeedback.swift`
"gave them up"
    `App/ActionFeedback.swift`
"get seats"
    `Domain/TicketLink.swift`
"has its own card"
    `App/ActionFeedback.swift`
"have their own cards"
    `App/ActionFeedback.swift`
"high confidence"
    `Domain/ReviewStatus.swift`
"if an alert or an OmniFocus task went out for this reply, clear those yourself."
    `Domain/DetachConversation.swift`
"if an alert went out for this reply, clear it yourself."
    `Domain/DetachConversation.swift`
"in 1 day"
    `Domain/ReachedOutQueue.swift`
"in \(days) days"
    `Domain/ReachedOutQueue.swift`
"in the queue"
    `UI/QueueView.swift`
"it is not valid JSON"
    `Domain/HandoffDecodeFailure.swift`
"it is version \(v), which this build of Overture does not read"
    `Domain/ReplyClassify.swift`
"its 1 confident contact never says the page it cites is anyone on this show, so a same named stranger would be kept as an answer"
    `Domain/RunInstructionCompliance.swift`
"just now"
    `Domain/PrepStatus.swift`
"last prep \(Self.relative(from: last, to: now))"
    `Domain/PrepStatus.swift`
"low confidence"
    `Domain/ReviewStatus.swift`
"medium confidence"
    `Domain/ReviewStatus.swift`
"never heard back"
    `Domain/ShowOutcome.swift`
"no Downbeat client export was found"
    `Persistence/PrepImporter.swift`
"no code in redirect"
    `Integration/GmailAuthManager.swift`
"no contact"
    `Domain/FollowUp.swift`
    `Domain/ReplyIdentity.swift`
    `UI/FollowUpsView.swift`
"not one of its \(cited) confident contacts says the page it cites is anyone on this show, so a same named stranger would be kept as an answer"
    `Domain/RunInstructionCompliance.swift`
"not one of its \(contacts) contacts carries a tier, so the fit score is guessing"
    `Domain/RunInstructionCompliance.swift`
"page fetch"
    `Domain/WebCallRefusals.swift`
"prep run"
    `Domain/RunKind.swift`
"reachability check"
    `Domain/RunKind.swift`
"redraft and find new contacts"
    `App/ActionFeedback.swift`
"restored your guidance notes"
    `Domain/PrepRunSummary.swift`
"send failed"
    `Integration/GmailSender.swift`
"show is"
    `Domain/ProbeSelection.swift`
"show was"
    `Domain/ProbeSelection.swift`
"shows are"
    `Domain/ProbeSelection.swift`
"shows were"
    `Domain/ProbeSelection.swift`
"so Overture can't keep clear of your booked nights or spot a booking."
    `Domain/AppNotice.swift`
"something Overture has seen before"
    `UI/QueueView+Model.swift`
"still couldn't save what this check found, so it has stopped trying and those shows will be checked again"
    `Domain/ReachabilityRunSummary.swift`
"the Downbeat client export couldn't be read"
    `Persistence/PrepImporter.swift`
"the Downbeat client export is \(days) days old"
    `Persistence/PrepImporter.swift`
"the \(day) listing"
    `Domain/SourceReadability.swift`
"the archive"
    `App/ActionFeedback.swift`
"the body could not be decoded"
    `Domain/ResponseBody.swift`
"the body is JSON but not an object"
    `Domain/ResponseBody.swift`
"the body is not valid JSON"
    `Domain/ResponseBody.swift`
"the booking history couldn't be read"
    `Persistence/PrepImporter.swift`
"the contact"
    `App/ActionFeedback.swift`
    `Domain/OmniFocusSync.swift`
"the list of calendars it watches"
    `Integration/ScoutService.swift`
"the one contact it found carries no tier, so the fit score is guessing"
    `Domain/RunInstructionCompliance.swift`
"the other \(leftover)"
    `Domain/ScoutReadBudget.swift`
"the other one"
    `Domain/ScoutReadBudget.swift`
"the presenter"
    `UI/QueueView+Model.swift`
"the queue"
    `UI/ProspectMutations.swift`
"the record of who you have shot before"
    `Integration/ScoutService.swift`
"the show you checked never got an answer and is still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"the shows it already had"
    `Integration/ScoutService.swift`
"the venue"
    `UI/QueueView+Model.swift`
"the venue names it matches against"
    `Integration/ScoutService.swift`
"they said no"
    `Domain/ShowOutcome.swift`
"they said not now"
    `Domain/ShowOutcome.swift`
"they said the price was too high"
    `Domain/ShowOutcome.swift`
"to confirm"
    `UI/QueueView.swift`
"too few to tell"
    `UI/OutcomePatternsView.swift`
"turn up"
    `Domain/SuppressionReport.swift`
"turns up"
    `Domain/SuppressionReport.swift`
"under a minute"
    `Domain/ProbeSelection.swift`
"voice guidance leaked a name, quarantined"
    `Domain/PrepRunSummary.swift`
"web search"
    `Domain/WebCallRefusals.swift`
"would have read \(count) show\(count == 1 ? "" : "s") as \(discipline.label)"
    `Domain/GenreCorrection.swift`
"wrote this"
    `Domain/ReplyPanel.swift`
"you stopped this check after 1 of \(requested) shows got an answer, and the lookups that were already under way still counted as spent"
    `Domain/ReachabilityRunSummary.swift`
"you stopped this check after \(answered) of \(requested) shows got an answer, and the lookups that were already under way still counted as spent"
    `Domain/ReachabilityRunSummary.swift`
"you stopped this check before any of the \(requested) shows got an answer, and the lookups that were already under way still counted as spent"
    `Domain/ReachabilityRunSummary.swift`
"you stopped this check before the show got an answer, and the lookup it had already started still counted as spent"
    `Domain/ReachabilityRunSummary.swift`
"your booking log"
    `UI/QueueView+Model.swift`
"your queue"
    `App/ActionFeedback.swift`
