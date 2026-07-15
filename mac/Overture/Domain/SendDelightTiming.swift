import Foundation

// #361: the timing of the post-send delight (a gold "Sent" seal, a thin gold line drawing once
// along the row, then the row gliding up and fading). Kept as a tested value, not computed inside
// the SwiftUI view, so the two rules that matter cannot silently drift: the whole moment finishes
// under a second, and Reduced Motion drops the drawn line and the glide (an opacity fade only).
struct SendDelightTiming: Equatable {
    let sealIn: Double         // the gold Sent seal fades/springs in
    let lineDraw: Double       // the thin gold line draws once (0 under Reduced Motion)
    let holdBeforeExit: Double // how long the row lingers, sealed, before it starts leaving
    let exit: Double           // the row glides up and fades out
    let translateUp: Bool      // whether the exit glides up (false under Reduced Motion: fade only)

    // The total wall-clock the just-sent row stays on screen: it lingers (covering the seal-in and
    // the line draw), then leaves. Must stay under a second.
    var total: Double { holdBeforeExit + exit }

    static func plan(reduceMotion: Bool) -> SendDelightTiming {
        if reduceMotion {
            return SendDelightTiming(sealIn: 0.12, lineDraw: 0, holdBeforeExit: 0.28, exit: 0.30, translateUp: false)
        }
        return SendDelightTiming(sealIn: 0.16, lineDraw: 0.5, holdBeforeExit: 0.55, exit: 0.42, translateUp: true)
    }
}
