import Testing
import Foundation

// #2365 follow-up: the client roster is LOADED, not merely loadable.
//
// The gap this closes was real and shipped: `ClientRoster` existed, the queue read it, and the only
// thing that ever asked it to load was the Sources sheet. So on any launch where Dan never opened that
// sheet, the roster was empty, and an empty roster is not a neutral state. It answers "nobody is a
// client", which holds every one of his clients' far-out shows to the ordinary 90 day window, which is
// exactly the thing #2365 was built to stop.
//
// Every test passed the whole time, because a test hands the client list straight in. That is L3: built
// is not wired, and wired is not proven. So this suite proves the wiring in the shipping view, not the
// behaviour of the type.
@MainActor
@Suite("The client roster is actually loaded (#2365)")
struct ClientRosterWiringTests {

    static var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    static func client(id: String, name: String) -> DownbeatClient {
        DownbeatClient(id: id, displayName: name, shortName: nil, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    static func code(in source: String) -> String {
        SwiftSource.scannableLines(in: source, skipping: []).map(\.code).joined(separator: "\n")
    }

    // The load itself. Asserted on the shipping view rather than on `ClientRoster`, because the type was
    // already correct and the app was still wrong.
    @Test("RootView loads the roster at launch")
    func loadedAtLaunch() {
        let source = Self.code(in: Self.rootView)
        #expect(!source.isEmpty, "RootView could not be read, so this guard checked nothing")
        #expect(source.contains(".task { clientRoster?.reload() }"), Comment(rawValue:
            "nothing loads the client roster at launch, so the queue decides who is a client from an "
            + "empty list until the Sources sheet is opened"))
    }

    // And again when the export moves, so a client added in Downbeat reaches the queue without a relaunch.
    @Test("RootView reloads the roster when the Downbeat export changes")
    func reloadedOnExportChange() {
        let source = Self.code(in: Self.rootView)
        #expect(source.contains("onChange(of: feedClientCount) { clientRoster?.reload() }"), Comment(rawValue:
            "nothing reloads the client roster when the export changes, so a client added in Downbeat "
            + "would not widen their shows' window until the next launch"))
    }

    // The reason both of the above matter, stated as behaviour rather than left to the comments: an empty
    // roster is a real answer with real consequences, not a harmless default.
    @Test("an empty roster says nobody is a client, which is a decision and not a neutral state")
    func anEmptyRosterIsNotNeutral() {
        let roster = ClientRoster(load: { _ in ([], .missing) })
        #expect(roster.window(for: []) == .none)
        #expect(roster.clients.isEmpty)
    }

    // The load goes through the injected seam, so a test never reads Dan's real export (L2), and a reload
    // genuinely replaces what is held rather than appending to it.
    @Test("reloading replaces the roster from its injected source")
    func reloadReplacesFromTheSeam() {
        var handed = [Self.client(id: "1", name: "DCINY")]
        let roster = ClientRoster(load: { _ in (handed, .ok) })
        roster.reload()
        #expect(roster.clients.map(\.displayName) == ["DCINY"])

        handed = [Self.client(id: "2", name: "TENET Vocal Artists")]
        roster.reload()
        #expect(roster.clients.map(\.displayName) == ["TENET Vocal Artists"])
    }
}
