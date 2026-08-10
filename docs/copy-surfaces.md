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

Scanned 402 source files; 18 of them render at least one container.

## Surfaces where a message can go astray

A message here can be correct, tested, and still fail to do its job: taken away by the platform
before Dan sees it, or delivered somewhere he cannot act on it. These are the ones to look at
when new copy lands in them.

### OS alert (3 files)

This appears over whatever is already on screen, including a sheet Dan is in the middle of, so it can interrupt an answer it has nothing to do with.

- `App/RootView.swift`
- `UI/DraftReviewView.swift`
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

## Every file, by surface

`App/AppEnvironment.swift`
    Menu bar
`App/OvertureApp.swift`
    Menu bar
`App/RootView.swift`
    OS alert, Menu, Sheet, Toolbar item
`UI/BuildFreshnessSheet.swift`
    Sheet
`UI/ConversationStateMenu.swift`
    Menu
`UI/DaysOffView.swift`
    Confirmation dialog
`UI/DraftReviewView.swift`
    OS alert, Confirmation dialog, Menu, Popover
`UI/FollowUpsView.swift`
    Menu, Sheet
`UI/OutcomePatternsView.swift`
    Popover, Sheet
`UI/PrepSelectionSheet.swift`
    Sheet
`UI/ProspectRowView.swift`
    Popover, Sheet
`UI/QueueView.swift`
    Menu, Sheet
`UI/ReplySheet.swift`
    Menu, Sheet
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
