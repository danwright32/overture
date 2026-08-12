import SwiftUI
import SwiftData

@main
struct OvertureApp: App {
    // Optional now (#264): nil means the store couldn't be opened (another copy holds the lock, or
    // open failed). The app degrades instead of crashing (a fatalError under the future launchd
    // agent would become a crash-respawn loop on a transiently locked store).
    let modelContainer: ModelContainer?
    private let storeLock: StoreLock?      // held for the process lifetime to keep the single-writer lock
    private let degradedReason: String?
    // #1409: set when the store opened with far fewer shows than its last backup holds.
    private let shrinkWarning: StoreShrinkCheck.Finding?
    // #1160: whether this launch is healthy, a duplicate (defer to the resident and quit), or a broken
    // store (show the degraded screen). Distinguishes the last two, which both leave modelContainer nil.
    private let launchOutcome: StoreLaunchOutcome
    // #265: an app-level delegate owns the ReconcileScheduler so the safe reconciles run independent of
    // any window. The container is handed to it via AppDelegate.sharedContainer below.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // #799: whether the Add-a-lead sheet is open. Owned here, not in RootView, because the menu-bar
    // command below has to reach it: a keyboardShortcut on a Button inside a TOOLBAR MENU renders the
    // "⌘L" and never registers with the system, so the key did nothing at all (verified with a real
    // key press in the built app). A menu-bar command registers.
    // Built in init() from the store itself (#899), so it cannot claim a store the app does not have.
    @State private var addLead: AddLeadPresenter

    // #1413: the session undo stack, owned HERE rather than beside ActionFeedback, which is @State
    // inside RootView: a Scene-level .commands block cannot read view state. Owning it on the App also
    // settles the window question, since Overture is LSUIElement and closing the window is not
    // quitting: the stack survives a close and dies only on quit, which is what Dan asked for. In
    // RootView it would have silently emptied every time he closed the window.
    @State private var undoStack = QueueUndoStack()
    // #2365: Dan's Downbeat client list, loaded once for the whole app rather than by each surface that
    // needs it. See ClientRoster for why it is not read on the render path and not stored on a source.
    @State private var clientRoster = ClientRoster()
    // #1414: the App's menu raises a request; RootView performs it, because the reversal needs the
    // ModelContext, the live rows and the ActionFeedback, none of which a Scene-level .commands block
    // can reach (and the App must never capture the feedback object, see the stack above).
    @State private var undoRequest = QueueUndoRequest()

    init() {
        // #800: WatchedSource joins the schema. Additive (a new entity plus a defaulted [String] on
        // Prospect), so SwiftData's lightweight migration handles it, which is the only migration this
        // app has ever had: there is no MigrationPlan or VersionedSchema anywhere in it. That makes the
        // launch-time backup below the ONLY safety net, which is why this migration was rehearsed
        // against a clone of the live store before it shipped rather than trusted.
        // #901: DayOff joins it on the same terms (a new entity, plus two defaulted String? columns on
        // Prospect for the conflict it now carries instead of dropping).
        // #1435: Inquiry joins it (a new independent entity). The model list now lives in AppSchema so
        // the app and the migration dry-run share one source of truth.
        let schema = AppSchema.schema
        var container: ModelContainer? = nil
        var lock: StoreLock? = nil
        var reason: String? = nil
        var shrinkWarning: StoreShrinkCheck.Finding? = nil
        // #1968: set true by the ONE branch below that asks for the single-writer lock and is refused
        // it. Nothing else may claim it, and it starts false on purpose: a route added to this chain
        // later inherits "show the reason" rather than "quit without a word", which is what the branch
        // that stops before the lock is asked for used to inherit by having left `lock` nil.
        var lockHeldByAnotherCopy = false

        if AppEnvironment.isRunningUnderTests {
            // Tests build their own in-memory stores; the host never touches the real store or its lock.
            container = try? ModelContainer(for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        } else if case let .blocked(relocationReason) = StoreRelocation.migrate(
            legacyStoreURL: StoreLocation.legacyStoreURL, newStoreURL: StoreLocation.storeURL
        ) {
            // The one-time move off the shared Application Support root, run BEFORE the lock is taken
            // (the lock lives at the new path) and before anything opens the store. It only blocks
            // when the file left at the old path isn't Overture's or the move couldn't finish; in
            // both cases nothing has been touched, and saying so beats coming up empty.
            reason = relocationReason
        } else if let acquired = StoreLock.acquire(at: StoreLocation.lockURL) {
            // Single-writer guard taken BEFORE opening the store (#264): flock is the real guard.
            lock = acquired
            // #663: confirm the file at this path is actually Overture's own database (or doesn't
            // exist yet) BEFORE anything below touches it. A foreign app's store landing at this
            // exact path (the Downbeat collision incident) wouldn't make ModelContainer throw.
            // It would silently create Overture's missing tables fresh and "succeed" as an empty
            // store. Refuse outright instead, after snapshotting the suspicious file (see
            // StoreSchemaGuard.refusalReason): no open, nothing written beyond that snapshot.
            if let refusal = StoreSchemaGuard.refusalReason(
                storeURL: StoreLocation.storeURL, dataDirectory: StoreLocation.dataDirectory, now: Date()
            ) {
                reason = refusal
            } else {
                // #602: back up the store right here, holding the exclusive lock but before
                // anything (including this process) has it open. That's the one moment it's
                // guaranteed quiescent; SQLite's WAL format is self-describing and crash-safe, so
                // even a snapshot from a not-cleanly-closed prior session is a valid, restorable
                // copy. Only prune old backups once the open below actually succeeds, so an
                // undetected corrupted store never causes its own last-good backups to be
                // rotated away.
                // #821: the same launch-time housekeeping window, for the files Overture writes and then
                // never reads again: the pinned pages the extract run worked from, and the bytes of a run
                // whose results would not parse. Both are kept deliberately, and until now by nobody: a
                // lead pin is written per pasted URL and stayed forever. Fourteen days, so a source
                // behaving oddly can still be checked against the page the app actually read.
                //
                // Before the store opens, like the backup, and for the same reason: this is the quiet
                // moment. It cannot reach a pin an in-flight run is about to read, which is minutes old,
                // never days.
                HandoffCleanup.sweep(handoffDirectory: StoreLocation.handoffDirectory, now: Date())

                // #1409: counted HERE, before the backup below runs, or the freshly taken backup would
                // be the thing it compares against and the two counts would always agree. Read-only,
                // and nothing acts on it: the store still opens normally, and Dan is shown the finding
                // once. The #663 guard above catches a foreign file; this catches Overture's own store
                // having quietly lost most of its rows, which opens perfectly cleanly and looks fine.
                shrinkWarning = StoreShrinkCheck.check(dataDirectory: StoreLocation.dataDirectory)

                container = StoreBackup.performLaunchBackup(
                    dataDirectory: StoreLocation.dataDirectory, now: Date(), keep: 10
                ) {
                    do {
                        return try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema, url: StoreLocation.storeURL,
                                                                cloudKitDatabase: .none)])
                    } catch {
                        reason = "Couldn't open Overture's data: \(error.localizedDescription)"
                        return nil
                    }
                }
            }
        } else {
            // The lock was asked for and refused, so a live copy really is holding it. This is the only
            // place in the app that may say so (#1968).
            lockHeldByAnotherCopy = true
            reason = "Another copy of Overture is already using its data."
        }

        self.modelContainer = container
        self.storeLock = lock
        self.degradedReason = reason
        self.shrinkWarning = shrinkWarning
        // Dan's rule for the update script, 2026-08-03: it deletes itself when it is done. This is the
        // second half of that, for a run that DIED before reaching its own removal: the installer quits
        // Overture partway through, so the app that wrote the file can never be the one to tidy up after
        // a successful run, and the only moment it can clean up a failed one is the next launch.
        UpdateCommandFile.sweep()
        // #1160: classify the launch so a duplicate (another live copy holds the single-writer lock)
        // defers to the resident and quits, instead of lingering on the degraded screen as a second
        // instance. A store that opened badly still shows StoreUnavailableView (see classify's edge).
        // #1968: the duplicate verdict is the branch's own statement, not "did some variable get set".
        // The test branch needs no special case any more: it never asks for the lock, so it never
        // claims another copy holds it, and it classifies on whether its in-memory store opened.
        let outcome = StoreLaunchOutcome.classify(
            lockHeldByAnotherCopy: lockHeldByAnotherCopy,
            storeOpened: container != nil,
            reason: reason)
        self.launchOutcome = outcome
        AppDelegate.launchOutcome = outcome
        // #899: with no store there is no RootView, and so no sheet for the Add-a-Lead command to open.
        // The command lives on the scene and would still be there, still enabled, firing into nothing.
        _addLead = State(initialValue: AddLeadPresenter(store: container))
        // Hand the opened store to the app-level scheduler owner (#265). nil in the degraded state, so
        // the delegate simply doesn't start the scheduler.
        AppDelegate.sharedContainer = container
    }

    // #1413: the two AppKit reads behind UndoRouting, kept to these three lines because nothing in the
    // test bundle can reach the responder chain. The DECISION they feed lives in UndoRouting, which is
    // a pure function and is tested; this only gathers its inputs.
    //
    // `undoManager.canUndo` rather than "is this a text view": the question that matters is whether the
    // focused field has real pending edits, not what class it is. A focused field with an empty undo
    // stack must let the keystroke through to the queue, or an invisible focus (a TextEditor holds it
    // with no visible ring) would silently swallow every Cmd+Z Dan pressed after a dismiss.
    @MainActor private func performUndo() {
        let textEditingCanUndo = NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false
        let destination = UndoRouting.destination(textEditingCanUndo: textEditingCanUndo,
                                                  queueCanUndo: undoStack.canUndo)
        guard UndoRouting.forwardsToResponderChain(destination) else {
            // A queue undo. RootView owns the reversal; this only asks for it.
            undoRequest.request()
            return
        }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    var body: some Scene {
        Window("Overture", id: "main") {
            if let modelContainer {
                RootView().modelContainer(modelContainer).environment(addLead).environment(undoStack).environment(undoRequest).environment(clientRoster)
                    .storeShrinkNotice(shrinkWarning,
                                       backupsPath: StoreShrinkCheck.backupsPath(
                                           dataDirectory: StoreLocation.dataDirectory))
                    // #1808: and the other notice, that this copy is behind the code. It reads the two
                    // records itself, when it is about to show and periodically after (#2065): an
                    // answer worked out here in init raced the installer's own write and lost.
                    .buildFreshnessNotice(directory: StoreLocation.dataDirectory)
            } else if launchOutcome == .duplicateInstance {
                // #1160: this process is a redundant duplicate; AppDelegate terminates it at launch and
                // it defers to the resident copy. Show nothing (no degraded screen) so a duplicate that
                // briefly renders before terminating doesn't flash the "data is unavailable" message.
                Color.clear
            } else {
                StoreUnavailableView(reason: degradedReason ?? StoreLaunchOutcome.defaultUnavailableReason)
            }
        }
        .defaultSize(width: 860, height: 720)
        .windowResizability(.contentMinSize)
        // #799: a REAL menu-bar command, which is the only kind whose keyboard shortcut actually
        // registers. Also more discoverable than a toolbar menu.
        .commands {
            // #1413: Overture's own Undo, replacing the system pair. Cleared by the #1412 spike, which
            // proved on a real Debug run that owning Cmd+Z this way leaves ordinary text editing
            // undoable in the draft body editor, the Add-a-Lead sheet (a separate NSWindow) and the
            // inline rename field. Replacing .undoRedo is mandatory rather than chosen: a .commands key
            // equivalent is matched by NSMenu BEFORE the event reaches the first responder, so a custom
            // item always wins and forwarding is the only way text editing keeps working.
            //
            // Nothing records into the stack yet (#1414), so today this item is always disabled and the
            // whole group exists to keep text undo working. That is deliberate: shipping the trigger
            // separately from the recording keeps each half reviewable.
            CommandGroup(replacing: .undoRedo) {
                // Titled from the top entry ("Undo Dismiss: The Music Shop"), a plain "Undo" when there
                // is nothing to undo. The dynamic title re-evaluates this body whenever the stack
                // changes, which is why only Dan's own actions may record: a background writer pushing
                // entries would re-render the App body on every reconcile tick, and this app has already
                // shipped one recompute-per-render freeze (#1374).
                //
                // Deliberately NEVER disabled, which reverses #1413's own rough direction ("disabled
                // when the stack is empty"). That instruction was written before the #1412 spike showed
                // this same item has to carry TEXT undo as well: a disabled menu item's key equivalent
                // does not fire, so greying it out on an empty queue stack would kill Cmd+Z inside every
                // text field in the app, which is precisely what the gate existed to protect. An enabled
                // item that does nothing when there is nothing to undo is the smaller cost, and matches
                // Dan's "it's fine if it just doesn't work" for the failure case.
                Button(undoStack.undoMenuTitle) {
                    performUndo()
                }
                .keyboardShortcut("z", modifiers: .command)

                // Redo forwards and does nothing else. Dan explicitly declined redo for queue actions,
                // but replacing .undoRedo also removes the system Redo that text fields rely on, so this
                // exists purely to give that back.
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Add a Lead...") { addLead.request() }
                    .keyboardShortcut("l", modifiers: .command)
                    // #899: greyed out when there is no store, because there is then no sheet for it to
                    // open and it would fire into nothing, with no error and no explanation. An action
                    // Dan cannot take must not look available. The rule is AddLeadPresenter's, not this
                    // view's (#863/#885).
                    .disabled(addLead.reasonAddLeadIsDisabled != nil)
                    // #2546: and it says WHY. #899 got the greying right and left the silence, which is
                    // the other half of the same defect: an action Dan cannot take must not look
                    // available, and one he can see is unavailable must say what would make it available.
                    //
                    // Help and hint rather than a sentence on screen, because a menu bar item has no room
                    // beside it and this one sits in the system File menu where a Text row is not ours to
                    // add. It is not the only thing said: this can be false only while the window shows
                    // StoreUnavailableView, which names the same fact in full, so what these supply is the
                    // join between that screen and this grey item.
                    .accessibilityHint(addLead.reasonAddLeadIsDisabled ?? "")
                    .help(addLead.reasonAddLeadIsDisabled ?? "")
            }
        }
        // #336: the styled in-content wordmark is the app's name; hide the redundant
        // title-bar label so "Overture" doesn't appear stacked twice.
        .windowStyle(.hiddenTitleBar)

        // #266: the resident menu-bar presence. With LSUIElement (Info.plist), closing the window
        // leaves the process running here in the menu bar, where the reconciles keep firing and Dan
        // can reopen the queue or quit.
        // #276: Overture's own brand mark (the "O" formed by a paper plane's trail) as a monochrome
        // template image, so macOS tints it for light/dark instead of the earlier SF Symbol stand-in.
        // #474: swapped the hand-drawn placeholder vector for a raster rendering of the real designed
        // mark, trimmed to its bounding box and downsampled straight from the source art rather than
        // re-traced, since the artwork's layered trail strokes are too intricate to approximate by hand.
        // #1966: inserted only on a real launch. The test host is the same app, and a status item that
        // macOS removes takes the whole process down with it (terminationOnRemoval), which is how a
        // crowded menu bar came to block all 4811 Swift tests with no error anyone could read. The rule
        // lives on AppEnvironment beside its sibling for background services, never spelled out here.
        // #2115: the glyph carries the count of work due today beside it, so the resident app says how
        // much is waiting without Dan opening anything. The label is its own small view (MenuBarLabel)
        // because it has to react to the count changing, and a Scene cannot hold that state itself.
        MenuBarExtra(isInserted: .constant(AppEnvironment.showsMenuBarExtra)) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}
