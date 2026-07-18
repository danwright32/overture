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
    // #265: an app-level delegate owns the ReconcileScheduler so the safe reconciles run independent of
    // any window. The container is handed to it via AppDelegate.sharedContainer below.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // #799: whether the Add-a-lead sheet is open. Owned here, not in RootView, because the menu-bar
    // command below has to reach it: a keyboardShortcut on a Button inside a TOOLBAR MENU renders the
    // "⌘L" and never registers with the system, so the key did nothing at all (verified with a real
    // key press in the built app). A menu-bar command registers.
    // Built in init() from the store itself (#899), so it cannot claim a store the app does not have.
    @State private var addLead: AddLeadPresenter

    init() {
        // #800: WatchedSource joins the schema. Additive (a new entity plus a defaulted [String] on
        // Prospect), so SwiftData's lightweight migration handles it, which is the only migration this
        // app has ever had: there is no MigrationPlan or VersionedSchema anywhere in it. That makes the
        // launch-time backup below the ONLY safety net, which is why this migration was rehearsed
        // against a clone of the live store before it shipped rather than trusted.
        // #901: DayOff joins it on the same terms (a new entity, plus two defaulted String? columns on
        // Prospect for the conflict it now carries instead of dropping).
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self, DayOff.self, ExcludedTown.self])
        var container: ModelContainer? = nil
        var lock: StoreLock? = nil
        var reason: String? = nil

        if AppEnvironment.isRunningUnderTests {
            // Tests build their own in-memory stores; the host never touches the real store or its lock.
            container = try? ModelContainer(for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
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
            reason = "Another copy of Overture is already using its data."
        }

        self.modelContainer = container
        self.storeLock = lock
        self.degradedReason = reason
        // #899: with no store there is no RootView, and so no sheet for the Add-a-Lead command to open.
        // The command lives on the scene and would still be there, still enabled, firing into nothing.
        _addLead = State(initialValue: AddLeadPresenter(store: container))
        // Hand the opened store to the app-level scheduler owner (#265). nil in the degraded state, so
        // the delegate simply doesn't start the scheduler.
        AppDelegate.sharedContainer = container
    }

    var body: some Scene {
        Window("Overture", id: "main") {
            if let modelContainer {
                RootView().modelContainer(modelContainer).environment(addLead)
            } else {
                StoreUnavailableView(reason: degradedReason ?? "Overture's data is unavailable.")
            }
        }
        .defaultSize(width: 860, height: 720)
        .windowResizability(.contentMinSize)
        // #799: a REAL menu-bar command, which is the only kind whose keyboard shortcut actually
        // registers. Also more discoverable than a toolbar menu.
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add a Lead...") { addLead.request() }
                    .keyboardShortcut("l", modifiers: .command)
                    // #899: greyed out when there is no store, because there is then no sheet for it to
                    // open and it would fire into nothing, with no error and no explanation. An action
                    // Dan cannot take must not look available. The rule is AddLeadPresenter's, not this
                    // view's (#863/#885).
                    .disabled(!addLead.canAddLead)
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
        MenuBarExtra("Overture", image: "MenuBarGlyph") {
            MenuBarContent()
        }
    }
}

enum AppEnvironment {
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // The unit suite hosts itself in the full app (TEST_HOST/BUNDLE_LOADER), so launching for
    // a test run also boots the app's launch-time background work: scouting, Gmail reply
    // checks, reply classification, draft prep, and the Downbeat export watcher. That work
    // hits the network and donates App Intents at launch, adding a single ~30s startup stall
    // to every test run (#195). None of it is needed by the suite (tests build their own
    // in-memory stores and call the logic directly), so skip it under XCTest.
    static var shouldStartBackgroundServices: Bool {
        !isRunningUnderTests
    }
}
