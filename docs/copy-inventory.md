# Copy inventory

Every sentence Overture can say to Dan: **928 sentences**, from 318 source files.

Generated, do not edit by hand. The test suite regenerates it (`mac/scripts/run-tests-locked.sh`)
and fails if it is stale, so a PR that changes what the app says shows the change here, in the
words Dan will read rather than as a line of Swift.

What is in it: a string literal carrying two or more words, from anywhere in `mac/Overture`.
What is not, and why:

- **One-word labels** (`Text("Sources")`). At this altitude a single word cannot be told apart
  from an SF Symbol, a defaults key or an identifier, and letting those in would bury the
  sentences under tokens nobody reads.
- **Sentences assembled from parts.** This lists the templates in the source, so a line built at
  runtime from `Plural.count(n, "show")` plus a suffix appears as its pieces, not as the finished
  sentence.
- **DEBUG-only copy**, which is compiled out of the app Dan runs.
- **Marked regions**, listed below with the reason, at the source.

## Excluded at the source

- `App/StoreBackup.swift`: backup.log is a diagnostic record, not the app's voice on screen
- `App/StoreShrinkCheck.swift`: SQL, not a sentence Overture says to Dan
- `Domain/CatchAllFitReasonMigration.swift`: the retired sentence, named only so this pass can find and clear it
- `Domain/ConversationReminder.swift`: outbound email: a recipient reads this, not Dan (#915)
- `Domain/DebugStaging.swift`: a debug-only stand-in draft body (contact-facing email copy, not app voice)
- `Domain/DebugStaging.swift`: a debug-only stand-in draft body (contact-facing email copy, not app voice)
- `Domain/DraftCheck.swift`: draft lint needles: phrases the linter HUNTS FOR, never words it says (#915)
- `Domain/DriftedRunMerge.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/EventPlace.swift`: Place names the resolver MATCHES against, never says: Dan reads a verdict, not this data (#970)
- `Domain/FeedMovementLog.swift`: a machine-parsed diagnostic log line for #913, never shown to Dan
- `Domain/FollowUp.swift`: outbound email: a recipient reads this, not Dan (#915)
- `Domain/LaunchMigrations.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/NaturalKeyVenueMigration.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/OrgReachabilityAnswer.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Domain/OutboundSignature.swift`: outbound email sign-off, not Overture's own voice to Dan (#915)
- `Domain/ProducerGate.swift`: Words matched inside an organisation's own name, never said to Dan (#1749)
- `Domain/SameNightTitleVariantMerge.swift`: developer diagnostic log, not the app's own voice (#915)
- `Domain/SendIdentity.swift`: an RFC822 sender identity (name + address), not the app's own voice
- `Domain/VenuePlaces.swift`: Venue and place names this table MATCHES and stores, not the app's voice: 79 city strings would bury the inventory a person reads cold (#1744)
- `Integration/AppleScriptOmniFocusClient.swift`: AppleScript source and OmniFocus tag names: OmniFocus reads these, not Dan (#915)
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
- `Integration/GmailSender.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSignatureHealth.swift`: developer diagnostic reason (log/badge detail), not the app's own voice (#915)
- `Integration/GmailSignatureService.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSignatureService.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/GmailSignatureStore.swift`: developer diagnostic log, not the app's own voice (#915)
- `Integration/LoopbackListener.swift`: developer diagnostic log, not the app's voice (#915)
- `Integration/OperaAmericaCalendar.swift`: synthesized source HTML the
- `Integration/OperaAmericaCalendar.swift`: an outbound API request body, not the app's voice (#915)
- `Integration/OvationTixCalendar.swift`: synthesized source HTML the extractor reads, not the app's voice (#915)
- `Integration/OvationTixCalendar.swift`: an outbound API request scoped by a header, not the app's voice (#915)
- `Integration/PrepQueueService.swift`: a diagnostic log line, not a sentence Overture says on screen
- `Integration/TicketTailor.swift`: an outbound API request's headers, not the app's voice (#915)
- `Integration/TicketTailorCalendar.swift`: an outbound fetch's headers for the venue page hop, not the app's voice (#915)
- `Integration/TicketTailorCalendar.swift`: a search marker for the widget's JS assignment, not the app's voice (#915)
- `Integration/VenueTixCalendar.swift`: synthesized source HTML the extractor reads, not the app's voice (#915)
- `Integration/VenueTixCalendar.swift`: an outbound API request scoped by Origin, not the app's voice (#915)
- `UI/DraftSignaturePreview.swift`: renders the outbound email's own HTML (body + Gmail signature), not Overture's voice (#1203)

## The same sentence, said in more than one place (44)

Two copies of a sentence will drift. #843 owns fixing these.

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
  - `Domain/ArchiveStatus.swift`
  - `Domain/PerformanceStatus.swift`
  - `UI/DraftReviewView.swift`
  - `UI/QueueView+Model.swift`
- "Closed (not now)"
  - `Domain/ArchiveStatus.swift`
  - `Domain/PerformanceStatus.swift`
  - `UI/DraftReviewView.swift`
  - `UI/QueueView+Model.swift`
- "Confirm booking"
  - `UI/ProspectRowView.swift`
  - `UI/ProspectRowView.swift`
- "Connect Gmail"
  - `App/RootView.swift`
  - `UI/OnboardingView.swift`
  - `UI/SendConfirmAndReconnectAlerts.swift`
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
- "In conversation"
  - `UI/DraftReviewView.swift`
  - `UI/QueueView+Model.swift`
- "Interested, going quiet"
  - `Domain/ConversationReminder.swift`
  - `UI/ReminderSettingsView.swift`
- "Not a booking"
  - `UI/ProspectRowView.swift`
  - `UI/ProspectRowView.swift`
- "Not a real reply"
  - `UI/DraftReviewView.swift`
  - `UI/DraftReviewView.swift`
- "Nothing matches this filter"
  - `Domain/EmptyState.swift`
  - `Domain/EmptyState.swift`
- "Owes a reply"
  - `Domain/ConversationReminder.swift`
  - `UI/ReminderSettingsView.swift`
- "Reached out"
  - `App/ActionFeedback.swift`
  - `Domain/AgentRoster.swift`
  - `Domain/AgentRoster.swift`
- "Redraft and find contacts"
  - `App/RootView.swift`
  - `UI/DraftReviewView.swift`
- "Redraft only"
  - `App/RootView.swift`
  - `UI/DraftReviewView.swift`
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
- "Send nudge"
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
- "Send reply"
  - `UI/DraftReviewView.swift`
  - `UI/InquiryReplySheet.swift`
- "Set a state"
  - `UI/ConversationStateMenu.swift`
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
- "Set up Overture"
  - `App/AppDelegate.swift`
  - `UI/OnboardingView.swift`
- "Skipped towns"
  - `App/RootView.swift`
  - `UI/ExcludedTownsView.swift`
- "Source listing"
  - `UI/QueueView+Model.swift`
  - `UI/QueueView+Model.swift`
- "Their events or season page"
  - `UI/SourceFixConfirmActions.swift`
  - `UI/SourcesView.swift`
- "Verbal yes, not booked"
  - `Domain/ConversationReminder.swift`
  - `UI/ReminderSettingsView.swift`
- "View in Archive"
  - `UI/FollowUpsView.swift`
  - `UI/FollowUpsView.swift`
  - `UI/QueueView.swift`
- "Voice guidance"
  - `App/RootView.swift`
  - `UI/VoiceGuidanceView.swift`
- "Went by"
  - `Domain/ArchiveStatus.swift`
  - `Domain/ReviewStatus.swift`
  - `UI/ProspectRowView.swift`
- "What converts"
  - `App/RootView.swift`
  - `UI/OutcomePatternsView.swift`
- "\n\nLast lines of the run log:\n\(tail)"
  - `Domain/DetachedRunOutcome.swift`
  - `UI/LeadIntakeModel.swift`
- "another show"
  - `Domain/SelfBookingConflict.swift`
  - `Domain/SelfBookingConflict.swift`
- "no contact"
  - `Domain/FollowUp.swift`
  - `UI/FollowUpsView.swift`
  - `UI/QueueView.swift`
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
" One other match is flagged the same way."
    `Domain/PossibleMatchFanOut.swift`
" Their email matches the address on file."
    `Domain/HistoryMatch.swift`
" Try again, and if it keeps happening the page may be one it can't make sense of."
    `UI/LeadIntakeModel.swift`
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
"## Dan's notes"
    `Domain/VoiceNotesProtector.swift`
"## Dan's notes (authoritative, never auto-edited)\n\nWrite any voice guidance you want every draft to follow. This section is yours; Prep runs never change it.\n\n## Observed tendencies (auto-generated; regenerated each run)\n\n_Nothing learned yet. This fills in after you've edited and sent some drafts._"
    `Domain/VoiceGuidanceStore.swift`
"## Observed tendencies"
    `Domain/VoiceGuidanceGuard.swift`
    `Domain/VoiceNotesProtector.swift`
"'\(scriptPath)' >/dev/null 2>&1 &"
    `Integration/DetachedRunner.swift`
"(no subject)"
    `Domain/SendConfirmation.swift`
", likely without its own photographer"
    `Domain/EventClassifier.swift`
", so a performer who is a past client may have read as cold"
    `Persistence/PrepImporter.swift`
"1 ignored client"
    `Domain/ClientCoverage.swift`
"1 named producer answers for several of them; \(s.performerHuntCount) "
    `Domain/ProbeSelection.swift`
"1 new show waiting for you"
    `Domain/SourceYield.swift`
"1 of \(requested) shows never got an answer and is still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"1 source needs"
    `Domain/SourceAttention.swift`
"1 venue is still waiting to be checked."
    `UI/ScoutSummaryView.swift`
"A Gmail connection is already in progress. Finish it in the browser."
    `Integration/GmailAuthManager.swift`
"A Prep run is already in progress. Wait for it to finish."
    `Integration/PrepQueueService.swift`
"A Prep run is already in progress. \(org) is queued to re-prep on the next run"
    `App/ActionFeedback.swift`
"A booking was detected that needs your confirmation. Tap to confirm or dismiss."
    `UI/ProspectRowView.swift`
"A contact on this show is held back by a check (a venue guess, a press address, a duplicate, the salutation, or the draft lint). Look at it below: dismissing the check releases the email."
    `UI/DraftReviewView.swift`
"A later night of this run is out: you blocked \(day) (\(name))."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you blocked \(day)."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you're already shooting \(name) on \(day)."
    `Domain/BlockedCalendar.swift`
"A later night of this run is out: you're already shooting on \(day)."
    `Domain/BlockedCalendar.swift`
"A previous run is still reading pages. The pages that changed will be read on the next scout."
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
"A reply-classify run is already in progress. Wait for it to finish."
    `Integration/ReplyClassifyService.swift`
"A run is already in progress. This will be available once it finishes."
    `Domain/Reachability.swift`
"A scout-extract run is already in progress. Wait for it to finish."
    `Integration/ScoutExtractService.swift`
"A show you kept lands here if a clash with your calendar turns up later."
    `Domain/StageEmptyState.swift`
"A source \"\(sourceName)\" may be them: check its name, or tag it a returning client."
    `Domain/ClientCoverage.swift`
"A source couldn't be checked. Open Sources to fix or confirm it."
    `Domain/ScoutWarnings.swift`
"A test tried to launch a real Claude run. Inject the launch seam instead."
    `Integration/ScoutExtractService.swift`
"AI read: \(replyIntentLabel(hint))"
    `UI/QueueView+Model.swift`
"Add a Lead..."
    `App/OvertureApp.swift`
"Add a contact"
    `UI/DraftReviewView.swift`
"Add a lead"
    `UI/AddLeadSheet.swift`
"Add a lead..."
    `App/RootView.swift`
"Add address"
    `UI/SourcesView.swift`
"Add another"
    `UI/AddLeadSheet.swift`
"Add contact"
    `UI/DraftReviewView.swift`
"Add this venue's address so its shows count as in your area."
    `UI/SourcesView.swift`
"Added \(Plural.count(count, "show")), ranked into your queue with everything else."
    `UI/LeadIntakeModel.swift`
"Added \(who). \(totalCount) recipient\(totalCount == 1 ? "" : "s") on \(org) now."
    `App/ActionFeedback.swift`
"Agency-routed showcase rental, the dead zone that rarely converts."
    `Domain/EventClassifier.swift`
"Agent logged an error: open agent logs"
    `App/MenuBarStatus.swift`
"All caught up"
    `Domain/PrepStatus.swift`
"All set"
    `UI/OnboardingView.swift`
"Allow OmniFocus control"
    `UI/OnboardingView.swift`
"Allow contact again"
    `UI/ProspectRowView.swift`
"Allow notifications"
    `UI/OnboardingView.swift`
"Allowed back in"
    `UI/ExcludedTownsView.swift`
"Already booked"
    `Domain/ReviewStatus.swift`
"Already watching \(orgName)'s calendar, so their shows turn up on their own."
    `UI/LeadIntakeModel.swift`
"Already watching \(orgName)'s calendar."
    `Domain/WatchlistEditing.swift`
"Also pitching \($0) on this date"
    `Domain/SelfBookingConflict.swift`
"Always a returning client"
    `Domain/ClientTagCopy.swift`
"Always skipped"
    `UI/ExcludedTownsView.swift`
"An organization that asked"
    `Domain/SuppressionReport.swift`
"Another copy of Overture is already using its data."
    `App/OvertureApp.swift`
"Another inquiry is already logged for this event. You can still save this one."
    `Domain/InquiryCopy.swift`
"Another pitch is already in progress on this date"
    `Domain/SelfBookingConflict.swift`
"Approve a show on a date you're already pitching?"
    `Domain/SelfBookingConflict.swift`
"Approve anyway"
    `Domain/SelfBookingConflict.swift`
"Approved, but no email to send to. Add a contact by hand."
    `Domain/DraftReviewNotes.swift`
"Asking macOS for OmniFocus permission…"
    `UI/OnboardingView.swift`
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
"Cancel prep"
    `App/RootView.swift`
"Carnegie Hall"
    `Domain/WatchedSourceBackfill.swift`
    `Integration/ScoutService.swift`
    `UI/FollowUpsView.swift`
"Carnegie Hall is added the first time Overture opens your store."
    `UI/SourcesView.swift`
"Check reachability"
    `Domain/Reachability.swift`
"Check reachability for these \(count) shows?"
    `Domain/Reachability.swift`
"Check reachability for this show?"
    `Domain/Reachability.swift`
"Checking reachability"
    `UI/RunProgressView.swift`
"City not known"
    `Domain/VenueDisplay.swift`
"Clear the search"
    `Domain/SourceSearch.swift`
"Cleared the flag on \(org), but read it once so a quiet page can stay quiet."
    `UI/SourceFixConfirmActions.swift`
"Closed (not interested)"
    `Domain/ArchiveStatus.swift`
    `Domain/PerformanceStatus.swift`
    `UI/DraftReviewView.swift`
    `UI/QueueView+Model.swift`
"Closed (not now)"
    `Domain/ArchiveStatus.swift`
    `Domain/PerformanceStatus.swift`
    `UI/DraftReviewView.swift`
    `UI/QueueView+Model.swift`
"Closing note sent to \(org)"
    `App/ActionFeedback.swift`
"Cold-contacted before, no booking"
    `UI/QueueView+Model.swift`
"Confirm booking"
    `UI/ProspectRowView.swift`
"Confirm bookings (\(count))"
    `UI/QueueView+Model.swift`
"Connect Gmail"
    `App/RootView.swift`
    `UI/OnboardingView.swift`
    `UI/SendConfirmAndReconnectAlerts.swift`
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
"Copy pitch and open form"
    `Domain/FormOutreach.swift`
"Copy the draft and mark it replied (paste it into Gmail yourself)"
    `UI/DraftReviewView.swift`
"Correct this source's web address, then read it to check"
    `UI/SourceFixConfirmActions.swift`
"Couldn't block \(range)"
    `UI/ProspectMutations.swift`
"Couldn't connect Gmail"
    `App/RootView.swift`
"Couldn't connect Gmail: \(reason)"
    `Domain/OnboardingState.swift`
"Couldn't find the Prep runner. Make sure Claude Code is installed and the Overture project is set up."
    `Integration/PrepQueueService.swift`
"Couldn't find the reply-classify runner. Make sure Claude Code is installed and the Overture project is set up."
    `Integration/ReplyClassifyService.swift`
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
"Couldn't send the closing note to \(org)"
    `App/ActionFeedback.swift`
"Couldn't send the follow-up to \(org)"
    `App/ActionFeedback.swift`
"Couldn't send the nudge to \(org)"
    `App/ActionFeedback.swift`
"Couldn't start the reader."
    `UI/LeadIntakeModel.swift`
"Couldn't start the reader: \(error.localizedDescription)"
    `UI/LeadIntakeModel.swift`
"Couldn't tell who's putting this on: the listing named only the room."
    `UI/QueueView+Model.swift`
"Coverage cannot be checked right now: the Downbeat client export is missing or could not be read. Refresh it from Downbeat."
    `Domain/ClientCoverage.swift`
"Dan Wright"
    `Integration/GmailSender.swift`
"Date TBD"
    `UI/QueueView+Model.swift`
"Date conflict"
    `Domain/ReviewStatus.swift`
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
    `Domain/ReviewStatus.swift`
"Downbeat clients no watched source treats as a returning client, so their next season would not surface a year ahead. Add a source for them, or tag an existing one below."
    `Domain/ClientCoverage.swift`
"Draft a reply"
    `UI/DraftReviewView.swift`
"Drafted by \(name)"
    `Domain/DraftTrace.swift`
"Drafting a reply"
    `UI/DraftReviewView.swift`
"Drafting replies \(count)"
    `Domain/ReplyClassifyProgress.swift`
"Drafts waiting for you to read, edit, and approve."
    `Domain/AgentRoster.swift`
"Each pair counts as two organisations, so nothing found for one is ever reused for the other. Some are real typos and some are simply different names."
    `UI/OrganisationsView.swift`
"Edit details..."
    `UI/InquiryRowView.swift`
"Edit inquiry"
    `Domain/InquiryCopy.swift`
"Email found"
    `Domain/Reachability.swift`
"End this experiment"
    `UI/ExperimentReportView.swift`
"Event (optional)"
    `UI/InquiryIntakeSheet.swift`
"Event passed, send a closing note"
    `Domain/ConversationReminder.swift`
"Every one is a one-off hunt, so none of them share an answer."
    `Domain/ProbeSelection.swift`
"Every scout re-checks it, so their next show turns up on its own. Untick it for a touring act: an itinerary is mostly not in New York, and re-reading it buys nothing."
    `UI/AddLeadSheet.swift`
"Every show Overture has ever tracked: past its window, booked, closed, or dismissed"
    `App/RootView.swift`
"Far towns skipped from the start. Allow one back if you now want its shows."
    `UI/ExcludedTownsView.swift`
"Filed as \(reason.label) either way."
    `Domain/BulkDismiss.swift`
"Find contacts only"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Finds a contact and drafts an email for shows you've kept."
    `Domain/AgentRoster.swift`
"First day"
    `UI/DayOffRangeFields.swift`
"Fit tier"
    `Domain/OutcomePatterns.swift`
"Fix the address"
    `UI/SourceFixConfirmActions.swift`
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
"Freshly found events waiting for you to keep or dismiss."
    `Domain/AgentRoster.swift`
"From Downbeat"
    `UI/DaysOffView.swift`
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
"Gmail is connected for sending"
    `Domain/DraftReviewNotes.swift`
"Gmail isn't connected yet. Authorize the photography account to enable sending."
    `Integration/MailSender.swift`
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
"Group website"
    `UI/ProspectRowView.swift`
"Grouped by when to reach out next"
    `UI/QueueView.swift`
"HIGH FIT"
    `UI/QueueView+Model.swift`
"Hard to reach"
    `Domain/Reachability.swift`
"Has a question"
    `Domain/ReviewStatus.swift`
"Heads up: looks like the venue's own domain."
    `UI/ProspectMutations.swift`
"Heads up: shares a domain with another contact already on this show."
    `UI/ProspectMutations.swift`
"Hedges like a cold pitch at a warm client"
    `Domain/DraftCheck.swift`
"Hidden for a week. Overture still can't keep clear of shoots it doesn't know about."
    `App/ActionFeedback.swift`
"Hide this for a week"
    `Domain/DaysOffAttention.swift`
"How Overture drafts in your voice. Your notes are yours and are never auto-edited; the observed tendencies are learned from your edits after each Prep run."
    `UI/VoiceGuidanceView.swift`
"How long to wait before nudging an active conversation, and how close to the event a reminder may still fire."
    `UI/ReminderSettingsView.swift`
"How they reached you"
    `UI/InquiryIntakeSheet.swift`
"I can shoot this anyway"
    `UI/ProspectRowView.swift`
"I can't read that page: the site builds its calendar with JavaScript, so the shows aren't in what I download. Nothing's wrong with your link. Try the venue's page for the show, or a ticket link (Eventbrite and the like) if there is one."
    `Domain/LeadIntake.swift`
"I can't read that: it's behind a login, so I only get the sign-in page. Paste the org's own site or the venue's event page instead."
    `Domain/LeadIntake.swift`
"I couldn't read \(list(unread.map(name))), so anything on in "
    `UI/LeadIntakeModel.swift`
"I couldn't read that page, so I followed its ticket link and read \(host) instead."
    `UI/LeadIntakeModel.swift`
"I read \(read.count) months of that calendar (\(name(first)) to \(name(last)))."
    `UI/LeadIntakeModel.swift`
"I sent it"
    `Domain/FormOutreach.swift`
"I'll read the ones you fix."
    `UI/ScoutSummaryView.swift`
"If another Overture window is open, use that one. Otherwise quit and reopen Overture."
    `App/StoreUnavailableView.swift`
"If they asked you to stop emailing them, Overture will keep every future show from this org out of your queue. You can undo it from the row."
    `UI/DraftReviewView.swift`
"Ignored \(name). It will not show as a coverage gap."
    `Domain/ClientCoverage.swift`
"In \(days) day\(days == 1 ? "" : "s"), likely too close to book"
    `UI/QueueView+Model.swift`
"In \(days) days, good to send"
    `UI/QueueView+Model.swift`
"In \(days) days, reach out now"
    `UI/QueueView+Model.swift`
"In \(days) days, send ~3 weeks out"
    `UI/QueueView+Model.swift`
"In conversation"
    `UI/DraftReviewView.swift`
    `UI/QueueView+Model.swift`
"Include this date in one reachability check"
    `UI/QueueView.swift`
"Interested, going quiet"
    `Domain/ConversationReminder.swift`
    `UI/ReminderSettingsView.swift`
"It fetches the page, then follows each show's own link to get the venue and date."
    `UI/AddLeadSheet.swift`
"It leaves your queue, filed as \(reason.label)."
    `Domain/BulkDismiss.swift`
"Its most recent backup (\(folder)) could not be read. Nothing has been changed. Check that "
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
"Keep a show from Scout and it lands here to prep."
    `Domain/StageEmptyState.swift`
"Keep editing"
    `UI/DaysOffView.swift`
"Keep this page but stop flagging it, until its contents change"
    `UI/SourceFixConfirmActions.swift`
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
"Last lines of the run log:"
    `Domain/SourceNote.swift`
"Lead buffer before the event"
    `UI/ReminderSettingsView.swift`
"Learn from this email again"
    `UI/ProspectRowFactory.swift`
"Learning from \(org)'s email again"
    `App/ActionFeedback.swift`
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
"Links a site that is not danwrightphotography.com"
    `Domain/DraftCheck.swift`
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
    `UI/ReminderSettingsView.swift`
"Looks booked?"
    `UI/InquiryRowView.swift`
"Looks like \(state.label.lowercased())"
    `Domain/ReviewStatus.swift`
"Looks right"
    `UI/ProspectRowView.swift`
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
"Music only travels to the five boroughs. As theater this would stay."
    `UI/QueueView+Model.swift`
"Name (optional)"
    `UI/DraftReviewView.swift`
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
    `Domain/Inquiry.swift`
"Never show me shows in \(town)"
    `UI/QueueView+Model.swift`
"New finds land here to keep or dismiss."
    `Domain/StageEmptyState.swift`
"New listings, not read yet. Run a scout to read them."
    `Domain/SourceReadState.swift`
"No Downbeat client export was found, so the scout treated every prospect as a cold lead. Open Downbeat to export your client list, then run the scout again."
    `Domain/DownbeatExport.swift`
"No Prep run or other check can start until it finishes."
    `Domain/ProbeSelection.swift`
"No address yet, so its shows are not placed in your area."
    `UI/SourcesView.swift`
"No contact found"
    `UI/DraftReviewView.swift`
"No contacts yet."
    `UI/DraftReviewView.swift`
"No drafted or approved prospects to re-prep"
    `App/ActionFeedback.swift`
"No drafts to review"
    `Domain/StageEmptyState.swift`
"No email found"
    `Domain/Reachability.swift`
"No email on file for this inquiry, so it can't be sent from here."
    `UI/InquiryReplySheet.swift`
"No email yet"
    `UI/QueueView+Model.swift`
"No experiment running. Start one to test two opener styles against each other and see which earns more replies. Nothing changes until you start it."
    `UI/ExperimentReportView.swift`
"No kept prospects need prepping. Keep some prospects first."
    `Integration/PrepQueueService.swift`
"No longer in the feed, may be cancelled"
    `UI/ProspectRowView.swift`
"No matches for \"\(query)\""
    `Domain/ShowSearch.swift`
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
"No replies need classifying right now."
    `Integration/ReplyClassifyService.swift`
"No response"
    `Domain/ReviewStatus.swift`
"No source matches that name."
    `Domain/SourceSearch.swift`
"No sources need re-reading right now."
    `Integration/ScoutExtractService.swift`
"No sources yet."
    `UI/SourcesView.swift`
"No upcoming shows on that page. That's normal off-season: the organization may not have announced its next season yet."
    `Domain/LeadIntake.swift`
"No venue"
    `Domain/OutcomePatterns.swift`
"None due"
    `Domain/AgentRoster.swift`
"None yet. Refuse a town from a show and it lands here, where you can take it back."
    `UI/ExcludedTownsView.swift`
"Not a booking"
    `UI/ProspectRowView.swift`
"Not a duplicate"
    `UI/DraftReviewView.swift`
"Not a fit"
    `Domain/ReviewStatus.swift`
"Not a fit for me"
    `Domain/Inquiry.swift`
"Not a real reply"
    `UI/DraftReviewView.swift`
"Not actually covered"
    `UI/ProspectRowView.swift`
"Not allowed. Enable Overture in System Settings ▸ Notifications."
    `Domain/OnboardingState.swift`
"Not checked yet"
    `Domain/SourceGrade.swift`
"Not installed yet. Run your Overture build once to install it."
    `UI/OnboardingView.swift`
"Not now"
    `UI/BlockDaysSheet.swift`
"Not one I scout"
    `Domain/ClientCoverage.swift`
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
"Not treated as a returning client."
    `Domain/ClientTagCopy.swift`
"Not yet synced"
    `Domain/OmniFocusSyncStatus.swift`
"Notes (optional)"
    `UI/InquiryIntakeSheet.swift`
"Nothing blocked. Add a vacation and Overture will stop pitching you for those nights."
    `UI/DaysOffView.swift`
"Nothing found here was verified as belonging to this act. Only an address read off a page naming them counts; a generic inbox or an inferred address doesn't. It may still be right, so it's worth a look before you write."
    `Domain/Reachability.swift`
"Nothing held by a date clash"
    `Domain/StageEmptyState.swift`
"Nothing here right now"
    `Domain/StageEmptyState.swift`
"Nothing in the queue matches \"\(query)\""
    `Domain/ShowSearch.swift`
"Nothing is recorded until you confirm you sent it."
    `UI/DraftReviewView.swift`
"Nothing looks odd right now."
    `UI/OrganisationsView.swift`
"Nothing matches this filter"
    `Domain/EmptyState.swift`
"Nothing new"
    `Domain/AgentRoster.swift`
"Nothing new on the watched calendars"
    `Domain/ScoutRunSummary.swift`
"Nothing new to triage"
    `Domain/StageEmptyState.swift`
"Nothing on this date still needs a reachability check."
    `Integration/PrepQueueService.swift`
"Nothing scouted yet"
    `Domain/EmptyState.swift`
"Nothing to act on. Leads you've emailed show up here for a gentle follow-up, active conversations for a re-touch, and they drop off the moment they reply, book, or you close them out."
    `UI/FollowUpsView.swift`
"Nothing to prep yet"
    `Domain/StageEmptyState.swift`
"Nothing to review"
    `Domain/AgentRoster.swift`
"Nothing to send"
    `Domain/AgentRoster.swift`
"Nothing tracked yet"
    `Domain/EmptyState.swift`
"Nothing upcoming for \(org) on that page. The other shows there belong to the venue's own programme, not to them, so I've left them out."
    `Domain/LeadIntake.swift`
"Nothing waiting"
    `Domain/AgentRoster.swift`
"Nothing was added and nothing will go out to them."
    `Domain/SuppressionReport.swift`
"Notifications allowed."
    `Domain/OnboardingState.swift`
"Nudge sent to \(org)"
    `App/ActionFeedback.swift`
"Nudges due on shows you've already reached out to."
    `Domain/AgentRoster.swift`
"Of the \(high) high-fit: \(relationshipDriven) from a prior relationship, \(meritDriven) on event merit"
    `UI/QueuePriorityBreakdown.swift`
"Offers a discount or free/complimentary work"
    `Domain/DraftCheck.swift`
"OmniFocus is syncing due follow-ups. It only fires while Overture is open, so it looks ahead by:"
    `UI/ReminderSettingsView.swift`
"OmniFocus needs Automation permission"
    `Domain/OmniFocusSyncStatus.swift`
"OmniFocus permission granted."
    `Domain/OnboardingState.swift`
"OmniFocus sync failed"
    `Domain/OmniFocusSyncStatus.swift`
"OmniFocus sync failed: \(reason)"
    `Domain/OmniFocusSync.swift`
"OmniFocus sync failing"
    `App/RootView.swift`
"OmniFocus sync needs attention"
    `App/MenuBarStatus.swift`
"Once you have sent a pitch, the people you are waiting to hear back from show up here, soonest follow-up first. They drop off when you book them, mark them lost, or the follow-ups run out."
    `UI/QueueView.swift`
"One source couldn't be checked."
    `UI/ScoutSummaryView.swift`
"One source couldn't be checked. \(lines[0])"
    `Integration/ScoutService.swift`
"Only a press address"
    `Domain/Reachability.swift`
"Only the venue's address"
    `Domain/Reachability.swift`
"Open Overture"
    `App/MenuBarContent.swift`
"Open Settings"
    `Integration/NotificationService.swift`
"Open agent logs"
    `App/MenuBarContent.swift`
"Open in Overture: \(link)"
    `Domain/OmniFocusSync.swift`
"Opening Google sign-in…"
    `UI/OnboardingView.swift`
"Organisations Overture may have read wrongly. Everything else it decided is on the show itself."
    `UI/OrganisationsView.swift`
"Organizations that asked"
    `Domain/SuppressionReport.swift`
"Outside New York, New Jersey and Connecticut."
    `UI/QueueView+Model.swift`
"Overture cannot tell whether anything is missing"
    `App/StoreShrinkCheck.swift`
"Overture contact: "
    `Domain/OmniFocusSync.swift`
"Overture couldn't finish starting up"
    `Domain/LaunchMigrations.swift`
"Overture couldn't move its data to \(newStoreURL.path): "
    `App/StoreRelocation.swift`
"Overture couldn't safely confirm the greeting in this draft is free of a real name. Confirm you've checked it and it's fine to send as-is."
    `UI/DraftReviewView.swift`
"Overture couldn't spot a way to email this one: no presenting org, or only a social page (which sits behind a login). You can still keep it and add a contact by hand. This is a heads up so you don't dismiss a reachable show in its place."
    `Domain/Reachability.swift`
"Overture couldn't start the Gmail sign-in on this Mac, so it didn't open your browser."
    `Integration/GmailAuthManager.swift`
"Overture couldn't update OmniFocus"
    `Integration/OmniFocusUserNotifier.swift`
"Overture decided: \(what)"
    `UI/QueueView+Model.swift`
"Overture is still reading a previous page. Give it a moment and try again."
    `UI/LeadIntakeModel.swift`
"Overture knows of no upcoming shoots from Downbeat, so it can't keep clear of them. Block those days here."
    `Domain/DaysOffAttention.swift`
"Overture knows of no upcoming shoots from Downbeat, so the only days it keeps clear are the ones you add here."
    `Domain/DaysOffAttention.swift`
"Overture lead: "
    `Domain/OmniFocusSync.swift`
"Overture needs OmniFocus permission"
    `Integration/OmniFocusUserNotifier.swift`
"Overture opened with \(live) \(live == 1 ? "show" : "shows"). Its most recent backup holds "
    `App/StoreShrinkCheck.swift`
"Overture's data file doesn't look like Overture's own database. Another app may "
    `App/StoreSchemaGuard.swift`
"Overture's data is unavailable"
    `App/StoreUnavailableView.swift`
"Overture's data is unavailable."
    `App/StoreLaunchOutcome.swift`
"Owes a reply"
    `Domain/ConversationReminder.swift`
    `UI/ReminderSettingsView.swift`
"Paste a link to the show, or to the organization's events page."
    `UI/AddLeadSheet.swift`
"Paused (booked elsewhere)"
    `UI/QueueView+Model.swift`
"Paused (show declined)"
    `UI/QueueView+Model.swift`
"Performance passed"
    `UI/QueueView+Model.swift`
"Performative enthusiasm or an exclamation point"
    `Domain/DraftCheck.swift`
"Performs today, too close to book"
    `UI/QueueView+Model.swift`
"Pick two different styles to compare."
    `UI/ExperimentReportView.swift`
"Pitch copied for \(org)"
    `App/ActionFeedback.swift`
"Possible booking, confirm?"
    `UI/ProspectRowView.swift`
"Possible match to \(possibleMatchOrigin(item.possibleMatchSource)): \(name)?"
    `UI/QueueView+Model.swift`
"Possibly one name twice"
    `UI/OrganisationsView.swift`
"Prep a show on a date you're already pitching?"
    `Domain/SelfBookingConflict.swift`
"Prep anyway"
    `Domain/SelfBookingConflict.swift`
"Prep kept"
    `App/RootView.swift`
"Prep matched this show's performer to a past client, which raised the fit score. The draft won't treat them as a returning client until you confirm it."
    `UI/QueueView+Model.swift`
"Prep these \(count) shows"
    `Domain/PrepQueueButton.swift`
"Prep this 1 show"
    `Domain/PrepQueueButton.swift`
"Prep's research found this show may already have its own photographer. Tap if that's wrong."
    `UI/ProspectRowView.swift`
"Prepped drafts land here to read and approve."
    `Domain/StageEmptyState.swift`
"Presumes the booking instead of handing back the decision"
    `Domain/DraftCheck.swift`
"Put this prospect back in the queue as undecided"
    `UI/ProspectRowView.swift`
"Queued \(draftGrantedCount) of \(total) \(prospectWord) to \(base); "
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
    `UI/DraftReviewView.swift`
"Re-prepping \(org) to find new contacts"
    `App/ActionFeedback.swift`
"Re-prepping \(org) to redraft"
    `App/ActionFeedback.swift`
"Re-prepping \(org) to redraft and find new contacts"
    `App/ActionFeedback.swift`
"Re: your inquiry"
    `UI/InquiryReplySheet.swift`
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
"Read \(n) shows before you cancelled."
    `Domain/CancelledReadDisposition.swift`
"Read \(reads) times but never turned up a show. It may be pointed at the wrong page."
    `Domain/SourceYield.swift`
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
"Reading them all takes a few minutes. A smaller batch leaves \(them) first in line next time."
    `Domain/ScoutReadBudget.swift`
"Reconcile complete: "
    `Domain/ReconcileSummary.swift`
"Reconcile complete: nothing was due."
    `Domain/ReconcileSummary.swift`
"Reconcile ran but couldn't save its results. Try again; if this keeps happening, something's wrong with the local store."
    `Domain/ReconcileSummary.swift`
"Reconnect Gmail"
    `UI/SendConfirmAndReconnectAlerts.swift`
"Recorded. \(org) is now in Reached out."
    `App/ActionFeedback.swift`
"Redo Anyway"
    `UI/DraftReviewView.swift`
"Redo it anyway?"
    `Domain/ReprepRequest.swift`
"Redo this re-prep?"
    `UI/DraftReviewView.swift`
"Redraft and find contacts"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Redraft only"
    `App/RootView.swift`
    `UI/DraftReviewView.swift`
"Remind me later"
    `UI/FollowUpsView.swift`
"Reminder timing"
    `UI/ReminderSettingsView.swift`
"Reminder timing…"
    `App/RootView.swift`
"Remove this contact"
    `UI/DraftReviewView.swift`
"Removed \(who) from \(org)."
    `App/ActionFeedback.swift`
"Rename show"
    `UI/ProspectRowView.swift`
"Rename this show"
    `UI/ProspectRowView.swift`
"Renamed to \(name)"
    `App/ActionFeedback.swift`
"Replaces the scout's name on this row. Your name stays put across future scouts."
    `UI/ProspectRowView.swift`
"Replied, needs a state"
    `Domain/ConversationReminder.swift`
"Reply to \(inquirerName)"
    `Domain/InquiryCopy.swift`
"Reply-classify results couldn't save. Try again."
    `App/RootView.swift`
"Requesting notification permission…"
    `UI/OnboardingView.swift`
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
"SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
    `App/StoreSchemaGuard.swift`
"Save changes"
    `Domain/InquiryCopy.swift`
"Saved \(org)'s address. Its shows are placed on the next read."
    `UI/SourcesView.swift`
"Saved \(org)'s venue. Its shows are read again on the next scout."
    `UI/SourcesView.swift`
"Say what happened"
    `Domain/ReachedOutQueue.swift`
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
"Search by name"
    `Domain/SourceSearch.swift`
"Search shows, venues, contacts"
    `UI/ShowSearchField.swift`
"Search the queue"
    `App/RootView.swift`
"Self-produced \(discipline.rawValue) group, a strong-fit target\(where_)."
    `Domain/EventClassifier.swift`
"Self-produced \(discipline.rawValue); worth a look once the fit is confirmed."
    `Domain/EventClassifier.swift`
"Send Anyway"
    `UI/DraftReviewView.swift`
"Send a follow-up"
    `UI/QueueView.swift`
"Send anyway?"
    `UI/DraftReviewView.swift`
"Send closing note"
    `UI/FollowUpsView.swift`
"Send failed: \(raw)"
    `Domain/SendFailureLine.swift`
"Send issues"
    `Domain/AgentRoster.swift`
"Send nudge"
    `UI/FollowUpsView.swift`
"Send reply"
    `UI/DraftReviewView.swift`
    `UI/InquiryReplySheet.swift`
"Send this email now"
    `UI/DraftReviewView.swift`
"Send this email now?"
    `UI/SendConfirmSheet.swift`
"Send this follow-up now?"
    `UI/SendConfirmSheet.swift`
"Send this note now?"
    `UI/SendConfirmSheet.swift`
"Send this reply on the contact's thread"
    `UI/DraftReviewView.swift`
"Sending despite the draft warning you confirmed."
    `Domain/DraftReviewNotes.swift`
"Sending despite the greeting warning you confirmed."
    `Domain/DraftReviewNotes.swift`
"Sending reply"
    `UI/DraftReviewView.swift`
"Sending your reply..."
    `UI/InquiryReplySheet.swift`
"Sent emails that hit a problem, or approved ones you can't send yet."
    `Domain/AgentRoster.swift`
"Sent through their form. Overture cannot see a reply to this one."
    `Domain/FormOutreach.swift`
"Sent, waiting to hear back"
    `Domain/InquiryCopy.swift`
"Set a state"
    `UI/ConversationStateMenu.swift`
    `UI/FollowUpsView.swift`
"Set this show's genre"
    `UI/ProspectRowView.swift`
"Set up Overture"
    `App/AppDelegate.swift`
    `UI/OnboardingView.swift`
"Set up Overture…"
    `App/MenuBarContent.swift`
"Show in Finder"
    `App/StoreUnavailableView.swift`
"Show me the backups"
    `UI/StoreShrinkNoticeSheet.swift`
"Show name"
    `UI/ProspectRowView.swift`
"Show only prospects where Downbeat detected a booking, to confirm or dismiss each one"
    `UI/QueueView+Model.swift`
"Show only the shows that are too far away to shoot"
    `UI/QueueView+Model.swift`
"Show the scout that's running. Hiding its window doesn't stop it."
    `App/RootView.swift`
"Show which bookings were auto-detected"
    `UI/OutcomePatternsView.swift`
"Showing only the \(Plural.count(count, "pending booking")). Click to show the whole queue again."
    `UI/QueueView+Model.swift`
"Showing only the \(Plural.count(count, "show")) that are too far away. Click to show the whole queue again."
    `UI/QueueView+Model.swift`
"Shows in \(town) can appear again"
    `App/ActionFeedback.swift`
"Shows land here once Overture has tracked at least one."
    `Domain/EmptyState.swift`
"Shows too far out to pitch yet start unchecked. Include any you want prepped now."
    `Domain/PrepSelectionCopy.swift`
"Shows you've pitched and are waiting to hear back on."
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
"Sources you stopped watching."
    `Domain/SourceGrade.swift`
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
"Still not granted. Allow Overture in the prompt, or in System Settings ▸ Privacy & Security ▸ Automation."
    `Domain/OnboardingState.swift`
"Still watched and still checked. Overture will keep reporting these every run rather than quietly giving up on them."
    `Domain/SourceGrade.swift`
"Stop ignoring this"
    `Domain/ClientCoverage.swift`
"Stop the reply drafting run"
    `UI/DraftReviewView.swift`
"Stop watching"
    `UI/SourceFixConfirmActions.swift`
"Stopped at their request"
    `Domain/SourceGrade.swift`
"Stopped watching \(org). Overture keeps what it found, and you can watch them again any time."
    `App/ActionFeedback.swift`
"Street, city, state"
    `UI/SourcesView.swift`
"Sync now"
    `App/RootView.swift`
"Tagged a returning client: shows surface up to a year ahead."
    `Domain/ClientTagCopy.swift`
"Tagged as returning client \(namedClient): shows surface up to a year ahead."
    `Domain/ClientTagCopy.swift`
"Take this source off the watchlist. You can put it back any time"
    `UI/SourceFixConfirmActions.swift`
"Thalia Spanish Theatre"
    `Domain/VenueParser.swift`
"That address is missing the part Overture needs to read this venue's calendar."
    `Integration/SourceFetcher.swift`
"That calendar has more months on it (\(list(unreachable.map(name)))), but it "
    `UI/LeadIntakeModel.swift`
"That calendar is drawn by JavaScript, so there is nothing to read in the page we fetch."
    `Domain/WatchedSource.swift`
"That calendar's feed answered but nothing could be read from it, so its format has probably changed."
    `Integration/SourceFetcher.swift`
"That contact"
    `App/ActionFeedback.swift`
"That doesn't look like a link. Paste the web address of the show or the org's events page."
    `UI/LeadIntakeModel.swift`
"That doesn't look like a web address."
    `Domain/WatchlistEditing.swift`
"That isn't a date Overture can read."
    `Domain/DayOff.swift`
"That link isn't a web page (it served \(type ?? "an unknown type"))."
    `Integration/SourceFetcher.swift`
"That link redirects to a different site (\(h)). Check the address."
    `Integration/SourceFetcher.swift`
"That page couldn't be read."
    `Domain/WatchedSource.swift`
"That page doesn't list any dated events. It may not be their events page: try the link that shows their season or calendar."
    `Domain/LeadIntake.swift`
"That page has more on it than I could read in one pass, and I didn't find a show in the part I did read. Try again, or paste a narrower link (a specific month or season) if it keeps happening."
    `Domain/LeadIntake.swift`
"That page has no dated listings on it. It may be the wrong page for this org."
    `Domain/WatchedSource.swift`
"That show had already moved on, so there was nothing to undo"
    `App/ActionFeedback.swift`
"That site is up, but its secure connection is broken, so the page can't be read. A re-check won't clear this."
    `Integration/SourceFetcher.swift`
"That was \(named[0])."
    `Domain/SourceReadability.swift`
"That's longer than a year. Block a shorter stretch."
    `Domain/DayOff.swift`
"The Downbeat client export couldn't be read (it may be corrupted or a newer format), so the scout treated every prospect as cold. Re-export it from Downbeat."
    `Domain/DownbeatExport.swift`
"The Prep run finished but didn't produce any results. It may have hit an error or found no contacts."
    `Domain/DetachedRunOutcome.swift`
"The act takes messages through the form on their own site. You'd fill that in yourself; Overture can't send it for you."
    `Domain/Reachability.swift`
"The automatic OmniFocus sync last failed, so follow-up tasks may not be getting created. Click \"Sync to OmniFocus\" to retry, and check that OmniFocus is installed and has Automation permission. A successful sync clears this."
    `App/RootView.swift`
"The calendar reader ran but produced nothing this run."
    `Domain/ScoutWarnings.swift`
"The calendars Overture re-checks on every scout, and how each one is doing"
    `Domain/SourceAttention.swift`
"The calendars Overture re-checks on every scout."
    `UI/SourcesView.swift`
"The date is known"
    `UI/InquiryIntakeSheet.swift`
"The days Overture won't pitch you for."
    `UI/DaysOffView.swift`
"The days Overture won't pitch you for: your booked shoots, and the days you block."
    `Domain/DaysOffAttention.swift`
"The email that will send"
    `UI/SendConfirmSheet.swift`
"The last day is before the first day."
    `Domain/DayOff.swift`
"The last follow-up sync failed. Tap Retry sync to try again."
    `Integration/OmniFocusUserNotifier.swift`
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
"The reader came back with nothing for that page. Try again, or paste the org's events page."
    `UI/LeadIntakeModel.swift`
"The reader didn't finish in time. It may still be running; try again in a minute."
    `UI/LeadIntakeModel.swift`
"The reader finished without producing anything for that page, so nothing was read."
    `UI/LeadIntakeModel.swift`
"The reader that pulls listings off a page isn't set up yet, so the pages that changed couldn't be read. See docs/scout-extract-runbook.md. Nothing was lost: they'll be read on the next scout once it's configured."
    `Integration/ScoutService.swift`
"The reply couldn't be sent. Check that Gmail is connected, then try again."
    `UI/InquiryReplySheet.swift`
"The reply drafter finished but didn't produce a draft. It may have hit an error."
    `Domain/DetachedRunOutcome.swift`
"The room its shows play in"
    `UI/SourcesView.swift`
"The run ended before reading this page, so it has not been read. The next scout will try it again."
    `Domain/WatchedSource.swift`
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
"The scout couldn't run. This stopped the whole run, so no source was checked. Try again; if it keeps failing, something is wrong with the local store rather than with any one calendar.\n\nDetails: \(message)"
    `Domain/ScoutFailure.swift`
"The scout couldn't save its results. Run it again."
    `Domain/ScoutWarnings.swift`
"The scout ran but couldn't save its results. Run it again; if this keeps happening, something's wrong with the local store."
    `Domain/ScoutWarningCopy.swift`
"The scout started reading the calendars that changed, but the run finished without producing anything. Those pages have NOT been read, and it will try them again on the next scout."
    `Domain/DetachedRunOutcome.swift`
"The scout-extract runner isn't set up yet. See docs/scout-extract-runbook.md: point Overture at scout-extract-run.sh and make it executable."
    `Integration/ScoutExtractService.swift`
"The show on \(dateLabel) is dismissed as \(reason.label)"
    `App/ActionFeedback.swift`
"The show's status, read from its contacts. Mark a contact below to change it."
    `UI/DraftReviewView.swift`
"Their calendar, not one show: a single show's page never changes again, so watching it would watch nothing."
    `UI/SourcesView.swift`
"Their email (optional)"
    `UI/InquiryIntakeSheet.swift`
"Their events or season page"
    `UI/SourceFixConfirmActions.swift`
    `UI/SourcesView.swift`
"Their name"
    `UI/InquiryIntakeSheet.swift`
"Their shows sit oddly for a company. Correct one from any of its shows if it looks wrong."
    `UI/OrganisationsView.swift`
"These leads are no longer in your queue."
    `UI/QueueView.swift`
"These organizations asked not to be contacted. Overture no longer watches them, and will not draft to them."
    `Domain/SourceGrade.swift`
"They all leave your queue, filed as \(reason.label)."
    `Domain/BulkDismiss.swift`
"They declined"
    `Domain/Inquiry.swift`
"They include \(named.joined(separator: " and ")), and \(others) \(plural)."
    `Domain/SourceReadability.swift`
"They replied"
    `Domain/InquiryCopy.swift`
"This booking was auto-detected from Downbeat. Confirm it (it then moves out of the reach-out list), or reject a wrong match to pull it back out."
    `UI/ProspectRowView.swift`
"This draft won't send: \(what.isEmpty ? "a blocking issue" : what)."
    `Domain/DraftCheck.swift`
"This group also performs at this venue on other dates"
    `UI/QueueView+Model.swift`
"This looks up a real contact for every still-open show on the "
    `Domain/ProbeSelection.swift`
"This looks up a real contact for the still-open show on \(dateLabel), so you can tell whether it's still emailable before you keep it. It spends a little on that lookup, only for the show you check here."
    `Domain/Reachability.swift`
"This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    `Domain/Reachability.swift`
"This old draft may still have a name in the greeting Overture couldn't safely remove; "
    `Domain/DraftReviewNotes.swift`
"This org asked not to be contacted, so none of their shows will be scouted or emailed. Tap to allow contact again."
    `UI/ProspectRowView.swift`
"This page is right"
    `UI/SourceFixConfirmActions.swift`
"This production also plays \(list)."
    `UI/QueueView+Model.swift`
"This production also plays at \(venue) on \(dateLabel)."
    `UI/QueueView+Model.swift`
"This production also plays elsewhere on \(dateLabel)."
    `UI/QueueView+Model.swift`
"This run's results disagreed with themselves, so nothing from it was used."
    `Domain/WatchedSource.swift`
"This sends one email right now, to this recipient only. Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This sends one follow-up right now, to this recipient only. Nothing else goes out."
    `UI/SendConfirmSheet.swift`
"This sends one message right now, to this recipient only."
    `UI/SendConfirmSheet.swift`
"This sends one message right now, to this recipient only. It also closes the lead out (kept warm for next time)."
    `UI/SendConfirmSheet.swift`
"This should be their events or season page, not one show. A single show's page never changes again, so watching it would watch nothing."
    `UI/AddLeadSheet.swift`
"This show"
    `Domain/SelfBookingConflict.swift`
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
"Too far"
    `Domain/ReviewStatus.swift`
"Too far (\(count))"
    `UI/QueueView+Model.swift`
"Too few sends to call anything yet. Both styles need at least \(experimentCallThreshold) sends before the reply rates mean much."
    `Domain/ExperimentReport.swift`
"Too soon"
    `Domain/ReviewStatus.swift`
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
"Try a different discipline, or clear the high-fit filter."
    `Domain/EmptyState.swift`
"Try a different status filter, or clear the search."
    `Domain/EmptyState.swift`
"Try again"
    `App/RootView.swift`
"Try another link"
    `UI/AddLeadSheet.swift`
"Undo \(actionLabel) and Days Off: \(subject)"
    `Domain/QueueUndoStack.swift`
"Unknown contact"
    `UI/QueueView+Model.swift`
"Unverified email found"
    `Domain/Reachability.swift`
"Updated \(org)'s address."
    `UI/SourceFixConfirmActions.swift`
"Updated \(org)'s classification"
    `App/ActionFeedback.swift`
"Venue (optional)"
    `UI/InquiryIntakeSheet.swift`
"Venue TBD"
    `Domain/VenueDisplay.swift`
"Venue calendar"
    `UI/QueueView+Model.swift`
"Verbal yes, not booked"
    `Domain/ConversationReminder.swift`
    `UI/ReminderSettingsView.swift`
"View in Archive"
    `UI/FollowUpsView.swift`
    `UI/QueueView.swift`
"Voice guidance"
    `App/RootView.swift`
    `UI/VoiceGuidanceView.swift`
"Wants to book"
    `Domain/ReviewStatus.swift`
"Warm lead from a prior relationship"
    `UI/QueueView+Model.swift`
"Watch a calendar"
    `Domain/WatchlistEditing.swift`
"Watch again"
    `UI/SourcesView.swift`
"Watch it"
    `UI/SourcesView.swift`
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
    `Domain/ReviewStatus.swift`
    `UI/ProspectRowView.swift`
"What converts"
    `App/RootView.swift`
    `UI/OutcomePatternsView.swift`
"Which kept shows to prep?"
    `Domain/PrepSelectionCopy.swift`
"Who Overture thinks puts each show on, and who it reads as the building."
    `App/RootView.swift`
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
"Wrong match"
    `UI/ProspectRowView.swift`
"You already have a pitch in progress for \($0) on this date."
    `Domain/SelfBookingConflict.swift`
"You already watch \(org) at that address."
    `UI/SourceFixConfirmActions.swift`
"You blocked \(day) (\(name))."
    `Domain/BlockedCalendar.swift`
"You blocked \(day)."
    `Domain/BlockedCalendar.swift`
"You confirmed this performer is a past client, so the fit score counts it and a draft can write to them as a returning client."
    `UI/QueueView+Model.swift`
"You dismissed \(org) because the dates don't work. Block the days you can't shoot, and Overture will stop pitching you for them."
    `Domain/DayOffOffer.swift`
"You entered days off but haven't blocked them yet."
    `UI/DaysOffView.swift`
"You have \(pointerPhrase(for: target, count: n)) next."
    `Domain/StageEmptyState.swift`
"You opened their form \(f.localizedString(for: startedAt, relativeTo: now)). Did you send it?"
    `Domain/FormOutreach.swift`
"You set this: \(what)"
    `UI/QueueView+Model.swift`
"You told Overture to read \(name) as the building, not the presenter."
    `Domain/OrganisationListing.swift`
"You're already shooting \(name) on \(day)."
    `Domain/BlockedCalendar.swift`
"You're already shooting on \(day)."
    `Domain/BlockedCalendar.swift`
"You've already added that link. Its shows are in your queue, and once the watchlist is on, that organization gets re-checked on its own."
    `UI/LeadIntakeModel.swift`
"You've already logged an inquiry for this event. You can still add this one."
    `Domain/InquiryCopy.swift`
"Your Downbeat client export is \(days) days old. Recently booked clients may be missing, so some warm leads could look cold. Open Downbeat to refresh it."
    `Domain/DownbeatExport.swift`
"Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again."
    `UI/SendConfirmAndReconnectAlerts.swift`
"Zankel Hall"
    `Domain/VenueParser.swift`
"\(Plural.count(count, "draft")) to review"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "new lead")) while you were away"
    `UI/QueueView+Model.swift`
"\(Plural.count(count, "show")) \(Plural.word(count, "is", "are")) back in \(undoStageWord(for: priorStatuses))"
    `App/ActionFeedback.swift`
"\(Plural.count(count, "show")) held by a date clash"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) on \(dateLabel) are dismissed as \(reason.label)"
    `App/ActionFeedback.swift`
"\(Plural.count(count, "show")) to prep"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) to triage"
    `Domain/StageEmptyState.swift`
"\(Plural.count(count, "show")) you've pitched"
    `Domain/StageEmptyState.swift`
"\(added) from watched calendars"
    `Domain/ScoutRunSummary.swift`
"\(arm.editedExcluded) edited (\(Int((rate * 100).rounded()))% of sends), excluded from the rate"
    `Domain/ExperimentReport.swift`
"\(arm.editedExcluded) edited, excluded from the rate"
    `Domain/ExperimentReport.swift`
"\(arm.tally.replied + arm.tally.booked) replied of \(arm.tally.contacted)"
    `Domain/ExperimentReport.swift`
"\(base) looks stuck (\(elapsed))"
    `Domain/RunProgress.swift`
"\(contactCount) contacts across \(showCount) \(showCount == 1 ? "show" : "shows")"
    `Domain/ReachedOutQueue.swift`
"\(count) \(count == 1 ? "contact" : "contacts") held for a check"
    `Domain/DraftReviewNotes.swift`
"\(count) \(prospectWord) already pending or re-prepped recently; nothing new queued"
    `App/ActionFeedback.swift`
"\(count) didn't come back, they'll be retried"
    `Domain/HandoffShortfall.swift`
"\(count) ignored clients"
    `Domain/ClientCoverage.swift`
"\(count) sources couldn't be checked."
    `UI/ScoutSummaryView.swift`
"\(count) sources need"
    `Domain/SourceAttention.swift`
"\(deferredCount) venues are still waiting to be checked."
    `UI/ScoutSummaryView.swift`
"\(drafted) to review"
    `Domain/PrepStatus.swift`
"\(empties.count) established calendars came back empty this run."
    `Domain/ScoutWarnings.swift`
"\(empties[0].orgName) has listed shows before and came back empty this run."
    `Domain/ScoutWarnings.swift`
"\(entry.distinctShowCount) different titles"
    `Domain/OrganisationListing.swift`
"\(error.localizedDescription). Your data is safe and unchanged at "
    `App/StoreRelocation.swift`
"\(f.count) sources couldn't be checked. Open Sources to fix or confirm them."
    `Domain/ScoutWarnings.swift`
"\(failed.count) sources couldn't be checked.\n\n"
    `Integration/ScoutService.swift`
"\(first) and \(rest) other\(rest == 1 ? "" : "s")"
    `Domain/SelfBookingConflict.swift`
"\(i.keptToPrep) ready to prep"
    `Domain/AgentRoster.swift`
"\(i.readyToSend) approved, connect Gmail to send"
    `Domain/AgentRoster.swift`
"\(i.sendErrors) failed to send"
    `Domain/AgentRoster.swift`
"\(i.toReview) draft\(i.toReview == 1 ? "" : "s") to review"
    `Domain/AgentRoster.swift`
"\(i.toTriage) to triage"
    `Domain/AgentRoster.swift`
"\(kept) to prep"
    `Domain/PrepStatus.swift`
"\(list(runs)) run past \(dateLabel), so dismissing them takes their later nights too."
    `Domain/BulkDismiss.swift`
"\(list) has listed shows before and came back with nothing this run. Its page format may have changed."
    `Domain/ScoutWarningCopy.swift`
"\(lookups), \(wait): shows by the same producer share one."
    `Domain/ProbeSelection.swift`
"\(min(completed, total)) of \(total) done"
    `UI/RunProgressView.swift`
"\(n) \(shows(n)) held by a date clash"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) sent, but replies can't be tracked: check Gmail"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) with a contact held for a check"
    `Domain/AgentRoster.swift`
"\(n) \(shows(n)) with an unconfirmed send: check Gmail"
    `Domain/AgentRoster.swift`
"\(n) new shows waiting for you"
    `Domain/SourceYield.swift`
"\(n) reply draft\(n == 1 ? "" : "s") stalled"
    `Domain/AgentRoster.swift`
"\(name) is a room's name, so Overture reads it as the building, not the presenter."
    `Domain/OrganisationListing.swift`
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
"\(names.count) new booking\(names.count == 1 ? "" : "s") (\(names.joined(separator: ", ")))"
    `Domain/OutreachEventPhrasing.swift`
"\(names.count) new repl\(names.count == 1 ? "y" : "ies") (\(names.joined(separator: ", ")))"
    `Domain/OutreachEventPhrasing.swift`
"\(narrowedCount) already sent, so \(narrowedCount == 1 ? "it" : "they") only got new contacts"
    `App/ActionFeedback.swift`
"\(omniFocusChanged) follow-up\(omniFocusChanged == 1 ? "" : "s") updated"
    `Domain/ReconcileSummary.swift`
"\(org) already moved on, so there was nothing to undo"
    `App/ActionFeedback.swift`
"\(org) can be drafted despite the clash"
    `App/ActionFeedback.swift`
"\(org) has already been sent to, so there's nothing to redraft"
    `App/ActionFeedback.swift`
"\(org) has already been sent to; re-prepping to find new contacts only"
    `App/ActionFeedback.swift`
"\(org) is back in \(undoStageWord(for: priorStatus))"
    `App/ActionFeedback.swift`
"\(orgName) asked not to be contacted, so Overture won't watch their calendar."
    `Domain/WatchlistEditing.swift`
"\(orgName) asked not to be contacted, so Overture won't watch them again."
    `Domain/WatchlistEditing.swift`
"\(orgNames.count) sources have listed shows before and came back with nothing this run: \(list). Their page formats may have changed."
    `Domain/ScoutWarningCopy.swift`
"\(outcome.skippedEdited) kept your edits"
    `Domain/PrepRunSummary.swift`
"\(outcome.unmatchedKeys.count) didn't match"
    `Domain/PrepRunSummary.swift`
"\(p.groupName), follow up with \(displayName(r))"
    `Domain/OmniFocusSync.swift`
"\(p.groupName), reply to \(displayName(r))"
    `Domain/OmniFocusSync.swift`
"\(pending) calendars have new listings to read."
    `Domain/ScoutReadBudget.swift`
"\(previous). Nothing has been changed. If that drop is a surprise, quit Overture and "
    `App/StoreShrinkCheck.swift`
"\(range) is no longer blocked"
    `App/ActionFeedback.swift`
"\(range) is now blocked"
    `App/ActionFeedback.swift`
"\(readable) shows listed, down from the usual \(baseline), "
    `Domain/SourceReadability.swift`
"\(runs[0]) runs past \(dateLabel), so dismissing it takes its later nights too."
    `Domain/BulkDismiss.swift`
"\(s.organisationCount) named producers answer for several shows each; "
    `Domain/ProbeSelection.swift`
"\(sends) of \(experimentCallThreshold) sends toward a reliable read"
    `Domain/ExperimentReport.swift`
"\(sends) sends in, enough for the rate to mean something"
    `Domain/ExperimentReport.swift`
"\(show) is on a date you already have a pitch in progress for \(others)."
    `Domain/SelfBookingConflict.swift`
"\(structuralGaps) of \(total) listings named no venue, so Overture left \(left) out of the queue."
    `Domain/SourceReadability.swift`
"\(subject) a look: failing, or can't mark shows as gone until it reads its calendar properly again"
    `Domain/SourceAttention.swift`
"\(subject) you to stop still \(verb) on calendars you watch: \(who). "
    `Domain/SuppressionReport.swift`
"\(tally.booked) booked of \(tally.contacted)"
    `Domain/OutcomePatterns.swift`
"\(tally.bookedAuto) auto-detected"
    `Domain/OutcomePatterns.swift`
"\(tally.bookedManual) confirmed by you"
    `Domain/OutcomePatterns.swift`
"\(tally.kept) of \(reviewed) kept after review"
    `Domain/SourceYield.swift`
"\(titleRejected) of \(total) shows had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
    `Domain/SourceReadability.swift`
"\(titleRejected) of \(total) shows had no title."
    `Domain/SourceReadability.swift`
"\(to) · nudge \(attempt(after: followUpCount)) of \(config.maxFollowUps)"
    `Domain/FollowUp.swift`
"\(total) web lookups for \(shows), more than expected"
    `Domain/PrepRunSummary.swift`
"\(town) is already on your skip list"
    `App/ActionFeedback.swift`
"\(unanswered) of \(requested) shows never got an answer and are still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"\(undoRestoredNight(count: restored, priorStatuses: priorStatuses)). \(others) already moved on."
    `App/ActionFeedback.swift`
"\(unread.count == 1 ? "that month" : "those months") isn't here."
    `UI/LeadIntakeModel.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page, so Overture won't mark anything from this source as gone until it can confirm one."
    `Domain/SourceReadability.swift`
"\(venueRejected) of \(total) shows had no venue on their own detail page."
    `Domain/SourceReadability.swift`
"\(who) is already a recipient on \(org)."
    `App/ActionFeedback.swift`
"\(worst.name) is flagged as a possible match on \(worst.count) shows, "
    `Domain/PossibleMatchFanOut.swift`
"\n\nLast lines of the run log:\n\(tail)"
    `Domain/DetachedRunOutcome.swift`
    `UI/LeadIntakeModel.swift`
"_(Removed: the auto-generated guidance contained a specific name and was quarantined; it will regenerate on the next Prep run.)_"
    `Domain/VoiceGuidanceGuard.swift`
"a past client"
    `UI/QueueView+Model.swift`
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
"all in one room"
    `Domain/OrganisationListing.swift`
"all the same title"
    `Domain/OrganisationListing.swift`
"another show"
    `Domain/SelfBookingConflict.swift`
"at \(venue) on \(dateLabel)"
    `UI/QueueView+Model.swift`
"backup before working."
    `App/StoreShrinkCheck.swift`
"book now"
    `Domain/TicketLink.swift`
"couldn't save, try again"
    `Domain/PrepRunSummary.swift`
"delivery failed"
    `Domain/BounceDetection.swift`
"drafter used this shape on \(Int((rate * 100).rounded()))% of sends"
    `Domain/ExperimentReport.swift`
"edit it before sending."
    `Domain/DraftReviewNotes.swift`
"elsewhere on \(dateLabel)"
    `UI/QueueView+Model.swift`
"file before reopening Overture."
    `App/StoreSchemaGuard.swift`
"get seats"
    `Domain/TicketLink.swift`
"has a question"
    `UI/QueueView+Model.swift`
"have written to \(path). Nothing has been opened or changed. Check that "
    `App/StoreSchemaGuard.swift`
"high confidence"
    `Domain/ReviewStatus.swift`
"in 1 day"
    `Domain/ReachedOutQueue.swift`
"in \(days) days"
    `Domain/ReachedOutQueue.swift`
"in the queue"
    `UI/QueueView.swift`
"just now"
    `Domain/PrepStatus.swift`
"last prep \(Self.relative(from: last, to: now))"
    `Domain/PrepStatus.swift`
"low confidence"
    `Domain/ReviewStatus.swift`
"medium confidence"
    `Domain/ReviewStatus.swift`
"moves between them in a way I can't follow yet, so I only read the month it "
    `UI/LeadIntakeModel.swift`
"no Downbeat client export was found"
    `Persistence/PrepImporter.swift`
"no code in redirect"
    `Integration/GmailAuthManager.swift`
"no contact"
    `Domain/FollowUp.swift`
    `UI/FollowUpsView.swift`
    `UI/QueueView.swift`
"opened on. Paste \(one ? "that month's" : "a month's") own link and I'll "
    `UI/LeadIntakeModel.swift`
"read it."
    `UI/LeadIntakeModel.swift`
"redraft and find new contacts"
    `App/ActionFeedback.swift`
"restore a backup before working: every launch takes another backup, and only the last "
    `App/StoreShrinkCheck.swift`
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
"so Overture won't mark anything from this source as gone until the smaller calendar holds."
    `Domain/SourceReadability.swift`
"something Overture has seen before"
    `UI/QueueView+Model.swift`
"ten are kept."
    `App/StoreShrinkCheck.swift`
"the Downbeat client export couldn't be read"
    `Persistence/PrepImporter.swift`
"the Downbeat client export is \(days) days old"
    `Persistence/PrepImporter.swift`
"the \(day) listing"
    `Domain/SourceReadability.swift`
"the archive"
    `App/ActionFeedback.swift`
"the booking history couldn't be read"
    `Persistence/PrepImporter.swift`
"the contact"
    `App/ActionFeedback.swift`
    `Domain/OmniFocusSync.swift`
"the other \(leftover)"
    `Domain/ScoutReadBudget.swift`
"the other one"
    `Domain/ScoutReadBudget.swift`
"the presenter"
    `UI/QueueView+Model.swift`
"the queue"
    `UI/ProspectMutations.swift`
"the show you checked never got an answer and is still unchecked"
    `Domain/ReachabilityRunSummary.swift`
"the venue"
    `UI/QueueView+Model.swift`
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
"wants to book"
    `UI/QueueView+Model.swift`
"which usually means the match is wrong."
    `Domain/PossibleMatchFanOut.swift`
"your booking log"
    `UI/QueueView+Model.swift`
"your queue"
    `App/ActionFeedback.swift`
