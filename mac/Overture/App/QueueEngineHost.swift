import Foundation
import Observation
import SwiftData

// #4358 slice E4d (plan v7 Phases 4 and 5, the switch): the queue engine the app runs, and what every surface
// reads from it.
//
// WHO OWNS IT. RootView, the view that outlives every sheet, as `@State`, as it owns the freeze watch: the engine
// lives while the main window does, and an app with no window open pays nothing for it (#1774). It is built the first
// time the queue is drawn, from the window's own main context, and started when the window appears.
//
// WHAT IT HANDS OUT, and why there are two things. The queue draws the engine's published pass. Every other surface
// (the sheets, the search bar, the toolbar's counts, Cmd+Z, the bulk actions) reads `rows(of:)`: the shows,
// inquiries and watched sources AS THE ENGINE HELD THEM AT ITS LAST PUBLISH, gathered once per published generation
// and never between. A scout landing publishes once, when it closes (#4369), so every one of those surfaces moves
// once, at the end (#4370, decision 8), and no surface holds a `@Query` or a memo over a table a landing writes
// (`LandingWrittenTypesScanTests`).
//
// WHAT THAT DOES NOT HOLD, said so nobody reads more into it (L400): a sheet still reads its rows' fields in its own
// body, and observation reaches a body that read a field when the field is written in place, so an open Archive can
// redraw mid-landing for a field it drew. Only the queue and its cards draw values (#4371). The surfaces that read
// whole arrays of the members are #4359's to give outputs of their own (`EngineMembersReadWholeTests`).
@MainActor
@Observable
final class QueueEngineHost {
    typealias Engine = QueueEngine<QueueEnginePass>

    @ObservationIgnored private var built: Engine?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var held: (generation: Int, rows: QueueEngineRows)?
    /// The last client window the live reader could work out, for a pass whose read of the sources throws.
    @ObservationIgnored private var lastClients: ClientWindow?

    /// The engine, built once, on the first call. Its context must be the window's main context: every action the
    /// queue takes saves through it, and the engine's trackers are armed on its rows.
    func engine(context: ModelContext, freezeWatch: @escaping @MainActor () -> FreezeWatch?,
                roster: @escaping @MainActor () -> ClientRoster?) -> Engine {
        if let built { return built }
        let engine = Engine(
            context: context,
            derivation: QueueEngineQueue.derivation(freezeWatch: freezeWatch),
            events: .live,
            verifier: QueueEngineVerifierSetup(
                triggers: .automatic,
                log: QueueEngineVerifierLog(url: CardDivergenceLog.url(in: StoreLocation.handoffDirectory),
                                            defaults: .standard)),
            launch: QueueEngineLaunchSetup(),
            contextInputs: { [unowned self] in self.liveContextInputs(context: context, roster: roster()) })
        // The view the queue opens on, before the launch derives, so the first pass is the one the queue draws
        // rather than one a second pass replaces as soon as the queue hands the engine its stage.
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: StageNavigation.openingStage))
        built = engine
        return engine
    }

    /// Starts the built engine, once: its observers, the launch, and the context sources' signals. The session's
    /// verifier count starts here too, so the next launch can say what THIS session checked (`QueueEngineSession`).
    func start(roster: ClientRoster?) {
        guard let built, !started else { return }
        started = true
        QueueEngineSession.begin(defaults: .standard)
        built.start()
        if let roster {
            built.startSignals(QueueContextSignals.Sources(
                gmail: .shared, roster: roster, prep: .prep, check: .check, reply: .replyClassify,
                checkLookups: { PrepQueueService.liveCheckLookups() },
                sleep: { try? await Task.sleep(for: .seconds($0)) }))
        }
    }

    /// #4369: what a landing entry point that does not own the engine holds the queue through (the Add lead sheet's
    /// paste). Nil until the window has built the engine, which is a landing with no queue on screen to hold.
    var landingHold: (any QueueLandingHold)? { built }

    /// What every surface but the queue reads, as of the engine's last publish (see the header).
    func rows(of engine: Engine) -> QueueEngineRows {
        // Read through the observed output, so a body calling this redraws when a pass is published and not before.
        let generation = engine.output?.generation ?? 0
        if let held, held.generation == generation { return held.rows }
        let rows = QueueEngineRows(everyShow: engine.everyShow, everyInquiry: engine.everyInquiry,
                                   everySource: sources(in: engine.modelContext))
        held = (generation, rows)
        return rows
    }

    /// The watched sources in a declared order: by name, then identifier (L343).
    private func sources(in context: ModelContext) -> [WatchedSource] {
        do {
            return try context.fetch(FetchDescriptor<WatchedSource>()).sorted {
                $0.orgName != $1.orgName ? $0.orgName < $1.orgName : $0.persistentModelID < $1.persistentModelID
            }
        } catch {
            // A failed read is not an empty watchlist (L215): what was held stands, and it is said.
            // copy-inventory:ignore-start  developer diagnostic log, never shown to Dan (#4358)
            AgentLog.note("Queue engine could not read the watched sources: \(error.localizedDescription)")
            // copy-inventory:ignore-end
            return held?.rows.everySource ?? []
        }
    }

    /// The reads `QueueView.makeRenderData` made on every pass before the cutover, made now when the engine derives.
    /// The check's start and size only while a check runs, so an idle queue pays nothing for them (#1770).
    func liveContextInputs(context: ModelContext, roster: ClientRoster?) -> QueueEngineContextInputs {
        let now = Date()
        let runStatus = PrepQueueService.slotStatus(now: now)
        let checking = runStatus.inFlight == .reachabilityCheck
        let clients: ClientWindow
        if let roster {
            do {
                clients = roster.window(for: try context.fetch(FetchDescriptor<WatchedSource>()))
                lastClients = clients
            } catch {
                // copy-inventory:ignore-start  developer diagnostic log, never shown to Dan (#4358)
                AgentLog.note("Queue engine could not read the watched sources for the client window: "
                              + error.localizedDescription)
                // copy-inventory:ignore-end
                clients = lastClients ?? .none
            }
        } else {
            // No roster injected answers "nobody is a client", the same answer the queue gave before the cutover
            // when its own roster lookup found none.
            clients = .none
        }
        return QueueEngineContextInputs(
            clients: clients,
            gmailConnected: GmailConnection.shared.isConnected,
            runInFlight: runStatus.inFlight,
            prepSlotRunning: runStatus.prepSlotRunning,
            checkSlotRunning: runStatus.checkSlotRunning,
            checkRunSince: checking ? PrepQueueService.lastRunStartedAt(slot: .check) : nil,
            checkLookups: checking ? PrepQueueService.liveCheckLookups() : nil,
            replyRunAlive: ReplyClassifyService.isRunning(now: now))
    }
}

/// The shows, inquiries and watched sources as the engine held them at one publish, each in a declared order (L343).
/// Built by `QueueEngineHost.rows(of:)` in the app; a test builds one from rows it fetched itself.
struct QueueEngineRows {
    let everyShow: [Prospect]
    let everyInquiry: [Inquiry]
    let everySource: [WatchedSource]
}

/// #4358 slice E4d (plan item 10): the verifier's match count PER SESSION, which the launch notice says for the session
/// before, because `CardDivergenceLog.verifierMatchCountKey` counts over the app's whole life. A session's count is the
/// lifetime count now minus the lifetime count when it began, so nothing but the start of a session is written here.
enum QueueEngineSession {
    static let startCountKey = "queueVerifierSessionStartCount"
    static let previousMatchesKey = "queueVerifierPreviousSessionMatches"
    static let previousLastMatchedKey = "queueVerifierPreviousSessionLastMatchedAt"

    /// Called once when a session's engine starts: the session that ended is closed (its matches kept for the notice)
    /// and this one is opened at the current lifetime count. A first launch has no earlier session, and records 0.
    static func begin(defaults: UserDefaults) {
        let lifetime = defaults.integer(forKey: CardDivergenceLog.verifierMatchCountKey)
        let started = defaults.object(forKey: startCountKey) as? Int
        defaults.set(max(0, lifetime - (started ?? lifetime)), forKey: previousMatchesKey)
        // The last match as of the session that ended, taken now, before this session's first match moves it.
        defaults.set(defaults.object(forKey: CardDivergenceLog.verifierLastMatchedKey) as? Date,
                     forKey: previousLastMatchedKey)
        defaults.set(lifetime, forKey: startCountKey)
    }

    /// When the session before this one last matched, or nil when it never did.
    static func previousLastMatchedAt(defaults: UserDefaults) -> Date? {
        defaults.object(forKey: previousLastMatchedKey) as? Date
    }

    /// How many matches the session before this one completed. Zero is "never checked", never "clean" (L557).
    static func previousMatches(defaults: UserDefaults) -> Int {
        defaults.integer(forKey: previousMatchesKey)
    }
}

/// #4369 (#4358 slice E4d): a landing generation, opened by every landing entry point before it writes and closed in a
/// `defer` (L514, L515), so the queue and every surface reading the engine redraw once, when it closes.
/// `LandingEntryPointsHoldTheQueueTests` holds every entry point to it.
@MainActor
protocol QueueLandingHold: AnyObject {
    func openLanding() -> QueueEngineLanding
    func closeLanding(_ landing: QueueEngineLanding)
}

extension QueueEngine: QueueLandingHold {}
