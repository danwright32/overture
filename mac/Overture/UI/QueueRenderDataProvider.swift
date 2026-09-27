import Foundation

// #4106 Step V: where `QueueView` gets the RenderData its body draws.
//
// WHY A SEAM. Phase 0c.8 has to time the queue's body plus a forced layout and display pass over a
// RenderData that is SERVED, so the whole-store derivation is not inside the measurement and the number
// is the view's own cost (L472). The body could not be handed one: it derived its own, through the render
// memo in `makeRenderData`, on every evaluation.
//
// SO THE PRODUCTION PROVIDER SERVES NOTHING. `QueueMemoRenderData` answers nil, and `makeRenderData` then
// runs exactly the path it always ran: the freeze stamp, the memo, its key and its `savesIn` invalidation,
// none of which moved. A provider that serves a prebuilt RenderData belongs in a test target and nowhere
// else, and `QueueRenderDataProviderWiringTests` holds both halves of that: `RootView` passes this one,
// and no other type in the app conforms (L718).
@MainActor
protocol QueueRenderDataProvider {
    // A RenderData to draw INSTEAD of deriving one, or nil to derive it through the render memo.
    func servedRenderData() -> QueueView.RenderData?
}

// The only provider the app has: derive, as the queue always did.
struct QueueMemoRenderData: QueueRenderDataProvider {
    func servedRenderData() -> QueueView.RenderData? { nil }
}
