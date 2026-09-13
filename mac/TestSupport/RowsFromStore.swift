import SwiftUI
import SwiftData

// #3846: a test's stand-in for the view that HOLDS the app's one live whole-table query.
//
// The queue and the Archive each used to hold their own bare `@Query` over the prospect table, and so
// does `RootView`, which presents both. Two identical bare descriptors held by two live views share
// NOTHING: measured 2026-09-12 on the live store, the second cost 99.6% of the first, 158.8 ms against
// 159.5 ms over 1,238 rows. So those views now RECEIVE their rows and RootView is the only holder.
//
// A test that wants the real store-to-screen path therefore has to play RootView's part, and this is that
// part in ONE place rather than re-spelled in each harness, because a harness that spells the query
// slightly differently from the app is a harness measuring something else (L613, L263).
//
// GENERIC OVER THE MODEL, and that is a constraint rather than a flourish. `mac/TestSupport` is compiled
// into BOTH test targets and they reach the app differently: the unhosted one compiles the app's sources
// in, the hosted one imports the built module. So a shared file cannot NAME an app type at all, which is
// the same reason `LiveDateClustering` beside it returns plain strings. The call site names the type.
//
// Put the container on THIS view or above it: its `@Query` reads the environment of the view it is
// declared in.
struct RowsFromStore<Model: PersistentModel, Content: View>: View {
    @Query private var rows: [Model]
    private let content: ([Model]) -> Content

    init(@ViewBuilder content: @escaping ([Model]) -> Content) {
        self.content = content
    }

    var body: some View { content(rows) }
}
