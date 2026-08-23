# Where Overture's messages render

A companion to `copy-inventory.md`, which lists every sentence the app can say and nothing about
where it lands. This says which SURFACES each file renders into, so a review of new copy is also
a review of where that copy goes.

Generated, do not edit by hand. The test suite regenerates it and fails when it is stale, so a
PR that puts a message into a surface the platform can take away shows that in its diff.

**What this claims:** the container kinds each file CREATES, read from the code with comments
stripped. **What it deliberately does not claim:** which container a given sentence ends up in.
That is not knowable from one file, since a sentence declared in one view routinely surfaces
through another, and a wrong label would be worse than none.

17 files render at least one container.

## Surfaces where a message can go astray

A message here can be correct, tested, and still fail to do its job: taken away by the platform
before Dan sees it, or delivered somewhere he cannot act on it. These are the ones to look at
when new copy lands in them.

### OS alert (4 files)

This appears over whatever is already on screen, including a sheet Dan is in the middle of, so it can interrupt an answer it has nothing to do with.

- `App/RootView.swift`
- `UI/DraftReviewView.swift`
- `UI/FollowUpsView.swift`
- `UI/SendConfirmAndReconnectAlerts.swift`

### Info block (1 file)

This container is informational by construction, so a message here that names a specific show, source or venue tells Dan what is wrong and gives him nothing to press.

- `UI/ScoutSummaryView.swift`

### Menu bar (2 files)

A crowded menu bar can push this item off screen, and losing the status item terminates the app.

- `App/AppEnvironment.swift`
- `App/OvertureApp.swift`

### Toolbar item (1 file)

macOS may relocate this into the overflow menu or drop it entirely at a narrow window width, so a message here can be correct and never seen.

- `App/RootView.swift`

## Which sentences each file renders

A sentence written as a constant is read here at the file that RENDERS it, not only at the file that declares it. That is the case the rest of this document and `copy-inventory.md` cannot show: moving an existing sentence onto a new screen changes no literal anywhere, so it produces no diff and gets no cold read, which is exactly when placement most needs reading.

50 files render a sentence declared as a constant.

`App/OvertureApp.swift`
    StoreLaunchOutcome.defaultUnavailableReason  "Overture's data is unavailable."
`App/RootView.swift`
    CancelledReadCopy.title  "Scout stopped"
    RunProgressCopy.diedLineForReplies  "Drafting replies"
`Domain/DebugStaging.swift`
    SendIdentity.danWright  "Dan Wright"
`Domain/EmptyState.swift`
    StalledReplyDraftCopy.nothingStalled  "A reply draft that stalls before it arrives appears here too."
`Domain/GenreGate.swift`
    GenreGateCopy.blocked  "Set this show's genre before you keep or dismiss it."
`Domain/LaunchMigrations.swift`
    LaunchMigrationsCopy.saveFailedTitle  "Overture couldn't finish starting up"
`Domain/ManualPrepPrefill.swift`
    ActionAck.manualPrepExtraSeparator  "One of the addresses is blank. Nothing was saved"
    ActionAck.manualPrepExtraSeparatorReason  "One of the addresses is blank"
    ActionAck.manualPrepGreetingHint  "Emails are held at send unless the body opens with a greeting"
    ActionAck.manualPrepNeedsBody  "Write the email before saving it. Nothing was saved"
    ActionAck.manualPrepNeedsBodyReason  "Write the email before saving it"
    ActionAck.manualPrepNeedsRecipient  "Add an address to send to. Nothing was saved"
    ActionAck.manualPrepNeedsRecipientReason  "Add an address to send to"
    ActionAck.manualPrepNeedsSubject  "Add a subject line. Nothing was saved"
    ActionAck.manualPrepNeedsSubjectReason  "Add a subject line"
`Domain/OmniFocusFailureKind.swift`
    OmniFocusSync.couldNotUpdatePhrase  "It could not update "
`Domain/ReplyComposition.swift`
    InquiryCopy.replySubjectDefault  "Re: your inquiry"
`Domain/ReplyPanel.swift`
    AttachConversationWriteCopy.linkedByHand  "You linked this conversation. Overture didn't email them."
    GmailCopy.notConnected  "Connect Gmail first"
    ReplyPanelCopy.aiWroteThisDraft  "Written by AI"
    ReplyPanelCopy.noCapturedWords  "Overture didn't capture what they wrote. Their message is in Gmail."
    ReplyPanelCopy.preparing  "Getting your reply ready"
    SendConfirmCopy.openReview  "Review and send"
`Domain/SendConfirmation.swift`
    SendConfirmCopy.followUpReassurance  "This sends one follow-up right now, to this recipient only. Nothing else goes out."
    SendConfirmCopy.followUpTitle  "Send this follow-up now?"
    SendConfirmCopy.reassurance  "This sends one email right now, to this recipient only. Nothing else goes out."
    SendConfirmCopy.replyTitle  "Send this reply now?"
    SendConfirmCopy.title  "Send this email now?"
`Domain/SendGate.swift`
    GmailCopy.notConnected  "Connect Gmail first"
    SendGate.noAddressReason  "No email address for this contact"
`Domain/UpdateAttempt.swift`
    BuildFreshnessCopy.dismiss  "Not now"
    BuildFreshnessCopy.update  "Update Overture"
    UpdateAttemptCopy.unexplained  "The update stopped without saying why. Ask Claude to look."
`Domain/VenueDisplay.swift`
    VenueDisplay.cityUnknown  "City not known"
    VenueDisplay.venueTBD  "Venue TBD"
`Integration/ConfirmProposedConversation.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/GmailAuthManager.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/GmailReplyChecker.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/GmailReplySearch.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/GmailSignatureStore.swift`
    OutboundSignature.plainFallback  "Best,\nDan Wright\nDan Wright Photography"
`Integration/GmailThreadingRepair.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/InquiryConversationAttach.swift`
    SendIdentity.danWright  "Dan Wright"
`Integration/ReplyProposalSweep.swift`
    SendIdentity.danWright  "Dan Wright"
`UI/BuildFreshnessSheet.swift`
    BuildFreshnessCopy.cannotUpdate  "Ask Claude to reinstall Overture."
    BuildFreshnessCopy.dismiss  "Not now"
    BuildFreshnessCopy.title  "Overture is out of date"
    BuildFreshnessCopy.update  "Update Overture"
    BuildFreshnessCopy.updateNote  "This opens Terminal and runs the install. Overture quits partway through and comes back on its own."
`UI/CloseOutMenu.swift`
    ReachedOutClose.menuLabel  "Close this out"
`UI/DraftReviewView.swift`
    FormOutreachCopy.copyAndOpen  "Copy pitch and open form"
    FormOutreachCopy.didNotSend  "Didn't send"
    FormOutreachCopy.sentIt  "I sent it"
    GmailCopy.notConnected  "Connect Gmail first"
    SendConfirmCopy.heldTag  "Held, not sending"
    SendConfirmCopy.openReview  "Review and send"
    SendModeCopy.label  "How this goes out"
    SendModeCopy.separately  "A separate email each"
    SendModeCopy.together  "One email to everyone"
    ShowOutcome.reopenLabel  "Reopen this show"
`UI/EmptyAnswerSection.swift`
    EmptyAnswerCopy.nothingEmpty  "No check has come home without a contact. When one does, what it claimed appears here."
    EmptyAnswerCopy.title  "Checks that came home empty"
`UI/FollowUpsView.swift`
    GmailReconnectCopy.afterLinkAttempt  "Your Gmail access has expired or was revoked, so this conversation could not be linked. Nothing was sent and nothing changed. Click Connect Gmail to reconnect, then answer again."
    GmailReconnectCopy.connect  "Connect Gmail"
    GmailReconnectCopy.title  "Reconnect Gmail"
    ProposedConversationCopy.confirm  "Yes, link it"
    ProposedConversationCopy.decline  "Not them"
    ProposedConversationCopy.linked  "Linked. Overture is watching that conversation now."
    ProposedConversationCopy.question  "Is this their reply?"
    ProposedConversationCopy.section  "Conversations to confirm"
    SendConfirmCopy.openReview  "Review and send"
    StalledReplyDraftCopy.section  "Stalled reply drafts"
    StalledReplyDraftCopy.tryAgain  "Draft it again"
    StandDownCopy.menu  "Not this one"
    StandDownCopy.stop  "Stop sending to this contact"
`UI/GenreCorrectionsView.swift`
    GenreCorrectionReportCopy.title  "What your genre corrections are teaching"
`UI/HandMarkedReplyControl.swift`
    HandMarkedReplyCopy.mark  "They got back to me"
    HandMarkedReplyCopy.undo  "Undo that"
`UI/InquiryRowView.swift`
    InquiryCopy.replyTrackingLostBadge  "Replies can't be tracked"
    InquiryCopy.threadingDegradedBadge  "A nudge will arrive as a new email"
`UI/LinkReplyPicker.swift`
    ProposedConversationCopy.confirm  "Yes, link it"
    ProposedConversationCopy.linked  "Linked. Overture is watching that conversation now."
    ProposedConversationCopy.pickTitle  "Which message is their reply?"
    ProposedConversationCopy.reading  "Reading your inbox..."
    ProposedConversationCopy.tryAgain  "Try again"
    SendIdentity.danWright  "Dan Wright"
`UI/ManualPrepSheet.swift`
    SendModeCopy.label  "How this goes out"
    SendModeCopy.separately  "A separate email each"
    SendModeCopy.together  "One email to everyone"
`UI/NameRoomControl.swift`
    UnplacedRoomCopy.add  "Say where it is"
    UnplacedRoomCopy.placeholder  "The city and state it's in"
`UI/OmniFocusSettingsView.swift`
    OmniFocusFailureSection.heading  "Last failure"
`UI/PrepSelectionSheet.swift`
    PrepSelectionCopy.subtitle  "All of these are included. Uncheck any you would rather not prep in this run."
    PrepSelectionCopy.title  "Which kept shows to prep?"
    SelfBookingCopy.prepConfirmProceed  "Prep anyway"
    SelfBookingCopy.prepConfirmTitle  "Prep a show on a date you're already pitching?"
`UI/ProbeSelectionBar.swift`
    ReachabilityProbeCopy.controlLabel  "Check reachability"
`UI/ProspectMutations.swift`
    ActionAck.bulkReprepNothingEligible  "No drafted or approved prospects to re-prep"
    ActionAck.contactBlankAddress  "One of the addresses is blank. No contact was added"
    ActionAck.contactNeedsRoute  "Add an email address, or a link to a contact form or profile. No contact was added"
    ActionAck.contactOneAtATime  "Add one address at a time. No contact was added"
    SendIdentity.danWright  "Dan Wright"
`UI/ProspectRowView.swift`
    GenreControlCopy.help  "Set this show's genre"
    ReachabilityCopy.checkAgain  "Check again"
    ReachabilityCopy.checkAgainRetry  "Try again"
    ReachabilityCopy.checkMissedItBadge  "A check missed this show"
    ReachabilityCopy.contactFormOnlyBadge  "Contact form only"
    ReachabilityCopy.emailFoundBadge  "Email found"
    ReachabilityCopy.emailFoundHelp  "A reachability check found a contact you can email for this show."
    ReachabilityCopy.hardToReachBadge  "Hard to reach"
    ReachabilityCopy.noAuthorityBadge  "Nobody who can hire you"
    ReachabilityCopy.recheckOutstanding  "Waiting to be checked again."
    ReachabilityCopy.recheckRunning  "Researching this show again"
    ReachabilityCopy.socialOnlyBadge  "Social DM only"
    ReachabilityCopy.staleProbeBadge  "Reachability may be out of date"
    ReachabilityCopy.unconfirmedProfileNote  "Name matches, nothing ties it to this show"
    ReachabilityCopy.unverifiedEmailFoundBadge  "Unverified email found"
`UI/QueueView+Model.swift`
    SelfBookingCopy.dateHeaderNote  "Another pitch is already in progress on this date"
`UI/QueueView.swift`
    ProposedConversationCopy.confirm  "Yes, link it"
    ProposedConversationCopy.decline  "Not them"
    ProposedConversationCopy.linked  "Linked. Overture is watching that conversation now."
    ProposedConversationCopy.manualLink  "Link their reply"
    ProposedConversationCopy.question  "Is this their reply?"
    ReachabilityProbeCopy.controlLabel  "Check reachability"
    ReachabilityProbeCopy.dateCheckedMarker  "Reachability checked"
    SelfBookingCopy.prepConfirmProceed  "Prep anyway"
    SelfBookingCopy.prepConfirmTitle  "Prep a show on a date you're already pitching?"
`UI/ReplyConversationView.swift`
    ReplyPanelCopy.drafting  "Drafting a reply"
`UI/ReplySheet.swift`
    ReplyPanelCopy.audienceHeading  "Your reply goes to"
    ReplyPanelCopy.couldNotPrepare  "Overture couldn't get this reply ready to send."
    ReplyPanelCopy.draftArrivedWhileWriting  "An AI draft came back while you were writing."
    ReplyPanelCopy.draftWithAI  "Draft with AI"
    ReplyPanelCopy.draftWithAIHelp  "Write a first draft of this one reply, which you can then edit"
    ReplyPanelCopy.drafting  "Drafting a reply"
    ReplyPanelCopy.noAddress  "No address to reply to"
    ReplyPanelCopy.saveWriter  "Save this address"
    ReplyPanelCopy.sendFailed  "That didn't send. You can try again."
    ReplyPanelCopy.useTheDraft  "Use it instead"
    ReplyPanelCopy.useTheDraftHelp  "Replace what you've written here with the AI's draft"
    ReplyPanelCopy.wroteThis  "wrote this"
`UI/ScoutSummaryView.swift`
    ScoutSummaryCopy.subtitle  "I'll read the ones you fix."
    ScoutSummaryCopy.title  "Scout results"
`UI/SendConfirmAndReconnectAlerts.swift`
    GmailReconnectCopy.afterSend  "Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again."
    GmailReconnectCopy.connect  "Connect Gmail"
    GmailReconnectCopy.title  "Reconnect Gmail"
`UI/SendConfirmSheet.swift`
    SendConfirmCopy.chooseLabel  "Who this goes to"
    SendConfirmCopy.editLabel  "The email that will send, edit it here"
    SendConfirmCopy.heldTag  "Held, not sending"
    SendConfirmCopy.previewLabel  "The email that will send"
    SendModeCopy.label  "How this goes out"
    SendModeCopy.separately  "A separate email each"
    SendModeCopy.together  "One email to everyone"
`UI/SourceFixConfirmActions.swift`
    SourceFixConfirmCopy.confirmHelp  "Keep this page but stop flagging it, until its contents change"
    SourceFixConfirmCopy.confirmTitle  "This page is right"
    SourceFixConfirmCopy.fixHelp  "Point this source at a different page, then read it to check"
    SourceFixConfirmCopy.fixTitle  "Change the page link"
    SourceFixConfirmCopy.stopWatchingHelp  "Take this source off the watchlist. You can put it back any time"
    SourceFixConfirmCopy.stopWatchingTitle  "Stop watching"
`UI/SourcesView.swift`
    ClientTagCopy.menuTitle  "Returning client"
    ClientTagCopy.optionAlways  "Always a returning client"
    ClientTagCopy.optionAlwaysNoClient  "Without naming a client"
    ClientTagCopy.optionAutomatic  "Automatic (match Downbeat)"
    ClientTagCopy.optionNever  "Never a returning client"
    CoverageCopy.dismissLabel  "Set aside"
    CoverageCopy.restoreLabel  "Put back"
    CoverageCopy.sectionTitle  "Returning clients not covered"
    SourceAttention.sectionLabel  "Needs a look"
    SourceFixConfirmCopy.stopWatchingTitle  "Stop watching"
    SourceSearch.clearButtonLabel  "Clear the search"
    SourceSearch.fieldPlaceholder  "Search by name"
    SourceSearch.noMatchesLine  "No source matches that name."
    UnplacedRoomCopy.add  "Say where it is"
    UnplacedRoomCopy.heading  "Rooms Overture can't place"
    UnplacedRoomCopy.placeholder  "The city and state it's in"
    VenueLocationCopy.add  "Add address"
    VenueLocationCopy.placeholder  "Street, city, state"
    VenueNameCopy.add  "Name the venue"
    VenueNameCopy.placeholder  "The room its shows play in"
    WatchlistEditing.readOneHelp  "Read this source's listings now, without scouting the rest of the list"
    WatchlistEditing.readOneTitle  "Read this one now"
`UI/StoreShrinkNoticeSheet.swift`
    StoreShrinkCopy.dismiss  "Continue anyway"
    StoreShrinkCopy.reveal  "Show me the backups"
`UI/UpdateFailureSheet.swift`
    UpdateAttemptCopy.title  "Overture could not update"
`UI/WatchlistMutations.swift`
    WatchlistEditing.invalidURLMessage  "That doesn't look like a web address."
    WatchlistEditing.needsNameMessage  "Give the organization a name so you can recognize it here."

## Every file, by surface

`App/AppEnvironment.swift`
    Menu bar
`App/OvertureApp.swift`
    Menu bar
`App/RootView.swift`
    OS alert, Menu, Sheet, Toolbar item
`UI/BuildFreshnessSheet.swift`
    Sheet
`UI/DaysOffView.swift`
    Confirmation dialog
`UI/DraftReviewView.swift`
    OS alert, Confirmation dialog, Menu, Popover
`UI/FollowUpsView.swift`
    OS alert, Menu, Sheet
`UI/OutcomePatternsView.swift`
    Popover, Sheet
`UI/PrepSelectionSheet.swift`
    Sheet
`UI/ProspectRowView.swift`
    Popover, Sheet
`UI/QueueView.swift`
    Menu, Sheet
`UI/ReplySheet.swift`
    Sheet
`UI/ScoutSummaryView.swift`
    Info block
`UI/SendConfirmAndReconnectAlerts.swift`
    OS alert, Sheet
`UI/ShowSearchField.swift`
    Popover
`UI/SourcesView.swift`
    Menu
`UI/StoreShrinkNoticeSheet.swift`
    Sheet
