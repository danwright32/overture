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
}
