import Foundation

// #3645: one render pass of the SOURCES SHEET, lifted out of the SwiftUI body so that what it COSTS can
// be measured instead of reasoned about.
//
// WHY THIS SURFACE GOT ITS OWN PASS RATHER THAN A SHARE OF THE QUEUE'S. #3645 was opened because the
// app's own watchdog recorded 30 freezes on this sheet in one day, median 1.34 s, which is WORSE than
// the queue's median of 0.97 s, and the queue is the surface every performance issue before it was
// about. The two surfaces cost their time in different places: the queue's is per-card construction over
// rows it never renders, and this sheet renders every row it has and pays for whole-store sweeps plus an
// O(clients x sources) fuzzy match that sat on its render path. The queue's fix does nothing for this
// one and this one does nothing for the queue, which #3645 states in its own body so that "one pattern
// applied everywhere" does not send the repair to the wrong layer.
//
// A SwiftUI body cannot be evaluated in a unit test (`SourcesView` has five `@Query` properties and
// needs a live container), so the derivation lives here as a plain function over values and the view's
// body does nothing but gather those values and call it. That is what makes the cost measurable at all,
// and it is deliberately the REAL function the app runs rather than a copy of it in a test: a test that
// measured a reimplementation would sit green while the shipping pass grew a new sweep (L1).
//
// THE COUNTERS ARE THE QUEUE'S, REUSED RATHER THAN RE-IMPLEMENTED. A second `Corpus` and a second
// `CostTally` would be two things doing one job, and the day one of them learned something the other did
// not is the day a sweep on this surface stopped being counted. `QueueRenderPass` owns them, the types
// have nothing queue-specific in them (a counted `[Prospect]` and a sweep counter), and the reason the
// work counter works at all, that a new call site is counted whether or not whoever adds it thinks about
// the cost, is a property of there being ONE of it.
enum SourcesRenderPass {
    // Reused, not re-declared. See the header: two of these would be two answers to "how many times did
    // this pass read the store".
    typealias Corpus = QueueRenderPass.Corpus
    typealias CostTally = QueueRenderPass.CostTally
    typealias WorkTally = QueueRenderPass.WorkTally

    // Everything one pass derives FROM. Values only: every file-backed answer (the Downbeat roster, the
    // extract run's in-flight markers) is READ BY THE CALLER and handed in, so the pass itself cannot
    // reach the filesystem. `SourcesRenderPassIsPureTests` holds it to that.
    @MainActor
    struct Inputs {
        // The whole store, through the counted accessor. Nothing here can reach a prospect any other way,
        // so a sweep added later is counted whether or not whoever adds it thinks about the cost.
        var prospects: Corpus
        var sources: [WatchedSource]
        var searchQuery: String
        // #3645: the day, the instant and Dan's geography refusals as ONE value, carrying the client
        // window the room list's lead-time gate reads.
        //
        // THE CLIENT WINDOW INSIDE IT IS THE POINT OF THIS ISSUE. `SourcesView` used to build this whole
        // context as an ARGUMENT to the room derivation, which means SwiftUI evaluated it on every body
        // pass, and constructing a `ClientWindow` runs `ClientHorizon.clientSourceIds`, an
        // O(clients x sources) fuzzy match over the whole watchlist and the whole Downbeat roster. #1429
        // measured that same match, run per row, freezing this very sheet. The verdict is decided once
        // when its inputs change and handed in here as a value; `SourcesRenderPassCostTests` pins that a
        // pass runs zero of those matches, with a positive control so the zero is a measured one.
        var context: StageContext
    }

    // What one pass decided the sheet should draw. Every list the body renders, and nothing the body can
    // derive for itself, so a section cannot quietly start sweeping the store again from inside a
    // `@ViewBuilder` where no counter can see it.
    @MainActor
    struct RenderData {
        // Whether Dan is searching, which decides whether the two WHOLE-WATCHLIST panels are on screen at
        // all. Carried rather than recomputed in the body: it also decides whether this pass paid for the
        // room list, and those two must be one answer.
        var isSearching: Bool
        var visible: [WatchedSource]
        var needsALook: [WatchedSource]
        var sections: [(grade: SourceGrade, sources: [WatchedSource])]
        var tallies: [String: SourceYield.Tally]
        var rooms: [UnplacedRooms.Room]
    }

    @MainActor
    static func make(_ i: Inputs) -> RenderData {
        let isSearching = SourceSearch.isSearching(i.searchQuery)
        // #1432: matching is `SourceSearch`'s decision. An empty query returns every source unchanged, so
        // an unsearched sheet renders exactly what it always did.
        let visible = SourceSearch.filter(i.sources, query: i.searchQuery)

        // The two screens that draw no list: an empty watchlist, and a search that matched nothing. The
        // body renders a sentence in each case, so the pass must derive NOTHING, and that is asserted
        // rather than left to be read off this guard: a pass that swept the store to draw one sentence
        // would be a cost nobody could see from the screen.
        guard !i.sources.isEmpty, !visible.isEmpty else {
            return RenderData(isSearching: isSearching, visible: visible, needsALook: [],
                              sections: [], tallies: [:], rooms: [])
        }

        // #1541: the rows the toolbar badge counts come FIRST, lifted OUT of `visible` so nothing is
        // listed twice. `now` comes from the pass's one context rather than from a fresh `Date()`, so
        // every decision in one pass is made against one instant (#2365).
        let attention = SourceAttention.split(visible, now: i.context.now)

        // #3656: ONE pass over the store for the whole list, threaded into every row. This is where
        // #1429's O(1)-per-row property comes from.
        let tallies = SourceYield.tallies(in: i.prospects.all)

        // #1752: the rooms no table can place. Skipped entirely while searching, which is not an
        // optimisation but the shape the sheet already had: the panel is a fact about the WHOLE queue
        // rather than a search result, so it is not on screen, and a surface must not pay for a list it
        // is not drawing.
        let rooms = isSearching ? [] : UnplacedRooms.from(i.prospects.all, context: i.context)

        return RenderData(isSearching: isSearching, visible: visible,
                          needsALook: attention.needsALook,
                          sections: SourceGrade.sections(attention.rest),
                          tallies: tallies, rooms: rooms)
    }
}
