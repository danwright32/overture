import Testing
import Foundation

// #3885: a run's progress heartbeat is never a view's own `@State`.
//
// WHAT IT COST. `RootView` held `@State private var scoutNativeSnapshot`, written from the scout's
// `onNativeProgress` and `onNativeStep` callbacks several times a second for the length of a run.
// Writing to `@State` invalidates the view WHETHER OR NOT its body reads the value, so every heartbeat
// re-evaluated `RootView`, and `RootView` evaluates `queueSurface`, which is the `QueueView` sitting
// under whatever sheet is open.
//
// Measured with `sample 53819` at 1 ms for 25 seconds on 2026-09-13, against the installed Release build
// `214a65f`, with the Follow-ups sheet open and a scout running. Main thread, 19,748 samples:
//
//     SwiftUI graph update (GraphHost.flushTransactions)   10,647
//     QueueView.body, UNDER the sheet                       5,724
//     FollowUpsView.body, the sheet Dan was looking at       2,274
//
// More of the main thread went on the screen he could not see than on the one he could. Over the same
// window `freeze-log.ndjson` holds 20 stalls on `followUps`, and they stop when the scout stops: 53 a
// minute while it ran, 1.3 a minute after (#3885).
//
// THE RULE, written as the reason rather than as the one case. A progress snapshot is written at a rate
// set by the WORK, not by what is on screen, so it belongs to something only the views that DRAW it
// observe. An `@Observable` object invalidates only the views that read one of its properties during
// their own body evaluation, which is the difference that matters here: `RootView` reaches the snapshot
// only inside the closure it hands to `RunProgressView`, and a closure called later registers nothing.
//
// WHAT IT CANNOT SEE. It matches the TYPE in a `@State` declaration, so a view that wrapped the same
// value in a struct of its own would pass. That is the honest limit of a source rule, and it is the
// cheap half of a pair: the dear half is `RootViewCountsItsOwnDrawsTests` plus the `rootDraws` field
// #3813 puts on every stall record, which is what will say whether this actually moved on Dan's Mac.
@Suite("A run's progress heartbeat is never a view's own @State (#3885)")
struct RunProgressIsNotViewStateGuardTests {

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")
    private static let fileFloor = 100

    /// The types whose values arrive on a heartbeat rather than on a store change.
    static let heartbeatTypes = ["RunProgressView.Snapshot"]

    @Test func noViewHoldsARunProgressSnapshotInItsOwnState() {
        let files = AppSourceWalk.files(underAll: [Self.appRoot], floor: Self.fileFloor)

        var holders: [String] = []
        var offenders: [String] = []
        for file in files {
            let lines = SwiftSource.scannableLines(in: file.text).map(\.code)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let type = Self.heartbeatTypes.first(where: { trimmed.contains($0) }) else { continue }
                holders.append(file.name)
                guard trimmed.contains("@State") else { continue }
                offenders.append("\(file.name): \(trimmed)")
            }
        }

        // Cannot pass vacuously: with the type named nowhere this has measured nothing, and that must
        // not read as everything being fine (L98).
        #expect(!holders.isEmpty, Comment(rawValue: """
            no file under mac/Overture names \(Self.heartbeatTypes.joined(separator: " or ")), so this \
            guard checked nothing at all
            """))
        #expect(offenders.isEmpty, Comment(rawValue: """
            \(offenders.joined(separator: "; ")). A heartbeat written to `@State` invalidates that view \
            on every beat whether or not its body reads the value, and a view that derives the whole \
            store then pays a pass per beat: measured at 5,724 main thread samples in a covered \
            QueueView against 2,274 in the sheet on top of it (#3885). Hold it on an @Observable object \
            that only the views drawing it read.
            """))
    }
}
