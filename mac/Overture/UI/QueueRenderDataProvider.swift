import Foundation

// #4106 Step V: a RenderData `QueueView` draws INSTEAD of the queue engine's published pass.
//
// WHY A SEAM. Phase 0c.8 times the queue's body plus a forced layout and display pass over a RenderData that is
// SERVED, so the derivation is not inside the measurement and the number is the view's own cost (L472).
//
// #4358 slice E4d: the app's queue draws the engine's published pass (`QueueEngineHost`), and hands no provider.
// The memo provider that served nothing, so the body derived through its own render memo, went with that memo:
// there is no derivation in the body left to serve around. A provider belongs in a test target and nowhere else,
// and `QueueRenderDataProviderWiringTests` holds both halves of that: `RootView` passes none, and no type in the
// app conforms (L718).
@MainActor
protocol QueueRenderDataProvider {
    // A RenderData to draw instead of the engine's pass, or nil to draw the engine's.
    func servedRenderData() -> QueueView.RenderData?
}
