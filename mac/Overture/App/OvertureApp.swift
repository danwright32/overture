import SwiftUI
import SwiftData

@main
struct OvertureApp: App {
    // Optional now (#264): nil means the store couldn't be opened (another copy holds the lock, or
    // open failed). The app degrades instead of crashing — a fatalError under the future launchd
    // agent would become a crash-respawn loop on a transiently locked store.
    let modelContainer: ModelContainer?
    private let storeLock: StoreLock?      // held for the process lifetime to keep the single-writer lock
    private let degradedReason: String?
    // #265: an app-level delegate owns the ReconcileScheduler so the safe reconciles run independent of
    // any window. The container is handed to it via AppDelegate.sharedContainer below.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let schema = Schema([Prospect.self])
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
            do {
                container = try ModelContainer(for: schema,
                    configurations: [ModelConfiguration(schema: schema, url: StoreLocation.storeURL,
                                                        cloudKitDatabase: .none)])
            } catch {
                reason = "Couldn't open Overture's data: \(error.localizedDescription)"
            }
        } else {
            reason = "Another copy of Overture is already using its data."
        }

        self.modelContainer = container
        self.storeLock = lock
        self.degradedReason = reason
        // Hand the opened store to the app-level scheduler owner (#265). nil in the degraded state, so
        // the delegate simply doesn't start the scheduler.
        AppDelegate.sharedContainer = container
    }

    var body: some Scene {
        Window("Overture", id: "main") {
            if let modelContainer {
                RootView().modelContainer(modelContainer)
            } else {
                StoreUnavailableView(reason: degradedReason ?? "Overture's data is unavailable.")
            }
        }
        .defaultSize(width: 860, height: 720)
        .windowResizability(.contentMinSize)

        // #266: the resident menu-bar presence. With LSUIElement (Info.plist), closing the window
        // leaves the process running here in the menu bar, where the reconciles keep firing and Dan
        // can reopen the queue or quit.
        // A monochrome template symbol so it matches the other menu-bar icons (the brand is an
        // airplane; the full color app icon rendered far too large and off-style up here).
        MenuBarExtra("Overture", systemImage: "paperplane.fill") {
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
