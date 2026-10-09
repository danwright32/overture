import Foundation
import SwiftData
import Testing
@testable import Overture

// #4358 slice E4d: the queue engine a hosted test hands `QueueView`, built the way `QueueEngineHost` builds the app's
// and differing only where a test must (L472): notification centres of its own, so no real wake or day change
// reaches it; a private save counter; the verifier only when asked; the launch's two reads in a scheduled turn
// rather than on the launch thread; no divergence log, so nothing is written to Dan's support folder; and the
// context inputs read from nothing live, so a test is not judged on whether Gmail is connected on the machine.
//
// The queue's own derivation and the app's schedule (the next main actor turn), so every pass a hosted test sees is
// a pass the app would make. The freeze watch is the hosted view's own, when the test hands one in.
@MainActor
enum HostedQueueEngine {
    struct NotReady: Error, CustomStringConvertible {
        let launch: String
        var description: String { "the hosted queue engine did not finish its launch: \(launch)" }
    }

    static func make(context: ModelContext, freezeWatch: FreezeWatch? = nil,
                     clients: ClientWindow = .none,
                     contextInputs: (@MainActor () -> QueueEngineContextInputs)? = nil) -> QueueEngineHost.Engine {
        let engine = QueueEngineHost.Engine(
            context: context,
            derivation: QueueEngineQueue.derivation(freezeWatch: { freezeWatch }),
            saves: StoreSaveCount(),
            events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
            verifier: QueueEngineVerifierSetup(triggers: .byHand),
            launch: QueueEngineLaunchSetup(reads: .inTurn),
            contextInputs: contextInputs ?? { QueueEngineContextInputs(clients: clients) })
        // The view the queue opens on, as the app's host hands it (`QueueEngineHost.engine`).
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: StageNavigation.openingStage))
        return engine
    }

    /// An engine never started, over an empty store kept for the whole run, for a test that builds `QueueView` only
    /// to call one of its row or masthead builders and draws nothing from the engine.
    static func idle() -> QueueEngineHost.Engine {
        make(context: ModelContext(idleStore))
    }

    private static let idleStore: ModelContainer = {
        do {
            return try TestModelContainer.inMemory(AppSchema.models)
        } catch {
            fatalError("an in-memory store for an idle queue engine could not be made: \(error)")
        }
    }()

    /// Built, started, and waited on until the launch fill has taken every row in, so a test acts on a queue the
    /// engine fully holds (the fill's fallback reads are the app's first second, not the subject of these tests).
    static func started(context: ModelContext, freezeWatch: FreezeWatch? = nil, clients: ClientWindow = .none,
                        contextInputs: (@MainActor () -> QueueEngineContextInputs)? = nil)
        async throws -> QueueEngineHost.Engine {
        let engine = make(context: context, freezeWatch: freezeWatch, clients: clients, contextInputs: contextInputs)
        engine.start()
        let done = await waitUntil("the hosted queue engine's launch fill", timeout: .seconds(60)) {
            if case .done = engine.launch.fill { return engine.output != nil }
            return false
        }
        guard done else { throw NotReady(launch: "\(engine.launch)") }
        return engine
    }
}
