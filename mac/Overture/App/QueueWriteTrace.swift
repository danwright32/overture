import Foundation

// #1930: the screen that builds the queue holds five live objects, and a write to any of them re-renders
// it, which rebuilds QueueView and pays a whole-store derivation of every prospect.
//
// The queue's own fingerprint cannot see them. It reports which of the inputs it READS moved before each
// derivation, and those objects are deliberately absent from it (#1922: reading one to report it would
// create the very dependency being measured), so every render one of them caused reported `nothing this
// view reads`, the answer trusted to mean "the invalidation came from outside". Two idle observations and
// a launch burst were read against that answer while it was blind to its most likely cause.
//
// So each object says so WHERE IT IS WRITTEN, which depends on nothing and is observed by nothing. The
// screen's fingerprint reads the counts, and a render that follows a write names the object.
//
// Every call compiles to nothing in Release, where the counter it feeds does not exist: a count nobody
// reads, ticking shared state on the main thread, is exactly what the counter's own header refuses.
enum QueueWriteTrace {
    static let feedback = "feedback"
    static let dayOffOffer = "dayOffOffer"
    static let undoStack = "undoStack"
    static let undoRequest = "undoRequest"
    static let addLead = "addLead"

    static func note(_ label: String) {
        #if DEBUG
        QueueRenderCounter.noteWrite(label)
        #endif
    }
}
