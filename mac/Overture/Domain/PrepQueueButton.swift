import Foundation

// #1129: a discoverable "Prep these N" button in the Prep stage view, so a first-time user does not
// have to know the Cmd+P shortcut or find the toolbar menu to start a Prep run. The show/hide decision
// and its label are pure so they can be tested (the #863 lesson: logic inside a SwiftUI view is
// untestable).
enum PrepQueueButton {
    // Shown only while the Prep stage is focused, there are kept shows to prep, and no run is already
    // in flight (RootView's canStartPrep gates the actual start too; the button simply should not appear
    // while Prep is running).
    static func shouldShow(stage: StageFocus?, keptToPrep: Int, prepRunning: Bool) -> Bool {
        stage == .prep && keptToPrep > 0 && !prepRunning
    }

    static func label(count: Int) -> String {
        count == 1 ? "Prep this 1 show" : "Prep these \(count) shows"
    }
}

// #2546: why "Prep kept" is refusing, beside the rule that decides whether it is.
//
// The toolbar menu gated it on `!toPrep.isEmpty && !PrepQueueService.isRunning(...)` and said nothing,
// so two states Dan can do opposite things about arrived as one grey item: go and keep a show, versus
// wait for the run already going. A single "not yet" would be wrong for whichever of the two fired
// (L11), which is why this is a value with a case per cause rather than a boolean.
//
// The rule is here rather than in RootView for the reason the rest of this file exists: logic inside a
// SwiftUI view is logic no test can reach (#863). RootView's `canStartPrep` now asks this.
enum PrepStartGate {
    enum Refusal: Equatable {
        // #2614: which run, because this sentence is read from inside the open menu where the toolbar's
        // own (correct) label is not in view, and during a check it used to say a prep run was going.
        case runInFlight(RunKind)
        case nothingKept

        // True BEFORE any press: what is standing in the way, never what became of a press (#2544).
        var reason: String {
            switch self {
            // Not "Prepping", which is what the toolbar already says while a run is going. This is the
            // answer to a different question (why this item will not start another one), and it is read
            // from inside the open menu where that label is not in view.
            case .runInFlight(let kind): return "A \(kind.runNoun) is already going"
            // Names the step that clears it. Keeping a show is one click away in the Queue behind this
            // menu, so this is advice that actually changes the state he is stuck in (L111).
            case .nothingKept: return "Keep a show first, then prep it"
            }
        }
    }

    // A run in flight is named first when both are true. It is the state that clears itself, and telling
    // him to go and keep a show would have him queue work into a run that cannot start anyway.
    // #3015: `ownSlotRunInFlight` is the run in THIS control's own slot, never "any run". Renamed rather
    // than just re-pointed, because the old name is what made the wrong caller look right: a gate that
    // refuses whenever anything is running is correct only while the two runs exclude each other, and
    // that premise is exactly what this phase removes (L176).
    static func refusal(keptToPrep: Int, ownSlotRunInFlight: RunKind?) -> Refusal? {
        if let kind = ownSlotRunInFlight { return .runInFlight(kind) }
        if keptToPrep == 0 { return .nothingKept }
        return nil
    }

    static func reason(keptToPrep: Int, ownSlotRunInFlight: RunKind?) -> String? {
        refusal(keptToPrep: keptToPrep, ownSlotRunInFlight: ownSlotRunInFlight)?.reason
    }

    static func canStart(keptToPrep: Int, ownSlotRunInFlight: RunKind?) -> Bool {
        refusal(keptToPrep: keptToPrep, ownSlotRunInFlight: ownSlotRunInFlight) == nil
    }
}
