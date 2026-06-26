import SwiftUI
import SwiftData

@main
struct OvertureApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([Prospect.self])
        // Local-only storage, like Downbeat: cloud sync off, in-memory under tests
        // so a test run never opens or mutates the real database.
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: AppEnvironment.isRunningUnderTests,
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create local ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        Window("Overture", id: "main") {
            RootView()
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 860, height: 720)
        .windowResizability(.contentMinSize)
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
