import SwiftUI

// #3876: the button that closes a sheet OWNS the dismiss read, so the sheet around it does not.
//
// WHY THIS IS A COMPONENT AND NOT A THREE LINE EDIT REPEATED SIX TIMES.
//
// `@Environment(\.dismiss)` is revised by SwiftUI when the window's key status changes. A view that
// reads it at VIEW level therefore re-evaluates its whole body every time focus moves, in either
// direction, and every one of these sheets derives over the whole prospect table in its body. So a click
// away from Overture and back cost two whole-store passes per open sheet, for no data change.
//
// Measured on `ArchiveView` at 120 rows of 120 on each key transition, with a null control reading zero
// and a positive control reading a full pass in the same fixture, in `ExternalRebuildProbeTests`. The
// trigger is proven generic rather than inferred: `DismissProbe` in that file holds no `@Query` at all,
// does nothing but derive and read `dismiss`, and rebuilds on a key change.
//
// Six sheets carried the identical shape and were found by code review on #3878, after that PR's own
// sibling sweep was scoped to three function names and could not see them (L30, L96). A private button
// nested in one view would have left the other five unable to reuse it, which is how a class fix becomes
// an instance fix (L613).
//
// WHAT THIS DOES NOT FIX, stated so it is not mistaken for the whole answer. It removes ONE cause of a
// body evaluation. The derivations are still unconditional per evaluation, so any other cause still pays
// a whole pass, and those causes cannot be enumerated from the data (L471). #3879 is that half.
//
// `SourcesView` deliberately does NOT use this. It calls `dismiss()` from two places besides its Done
// button (`SourcesView.swift:533` and `:1152`), so it needs the value at view level and cannot be fixed
// by moving the read. It is the one surface of the seven this approach cannot reach, and #3879 is what
// covers it.
struct DoneButton: View {
    // Some sheets make Done the default action and some do not, and that difference is theirs to keep:
    // folding it in either direction here would silently add or remove a keyboard shortcut on a surface
    // nobody was changing.
    var isDefaultAction: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Done") { dismiss() }
            .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
    }
}
