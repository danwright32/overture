import Foundation

// #3751: the one place the assumed viewport size lives.
//
// The cost instrument narrows its shipping arm to this many rows, and `ViewportSizeTests` asserts the
// number covers what the tallest window Archive allows actually realizes. Both read THIS, rather than
// each holding a copy: a guard whose expected value and actual value come from one lookup can only prove
// the lookup is self consistent, and two copies of a constant is the other half of that mistake, where
// the guard passes while the instrument uses a different number (L70).
//
// In `TestSupport` because the two readers are in DIFFERENT targets: the instrument is in the pure suite
// and the layout measurement needs the app host.
enum QueueViewportAssumption {
    // MEASURED 2026-09-10 by `ViewportSizeTests`, which lays Archive out and counts the rows realized:
    // 3 at its ideal window (780 by 720) and 4 at the tallest its own frame allows (960 by 900). An
    // Archive card is a tall thing, so a window holds few of them.
    //
    // KEPT AT 12 RATHER THAN TIGHTENED TO 4, deliberately. The margin costs the instrument about eight
    // extra cards, which at the measured 0.22 ms each is under 2 ms of a 175 ms pass, and it means the
    // narrowed arm stays honest if a card gets shorter, a window gets taller, or the queue's rows (which
    // are denser than Archive's) are measured instead. Tightening it to today's exact reading would make
    // the instrument fragile to a design change that has nothing to do with cost.
    //
    // So the number is unchanged and what changed is that it is now a measurement with a margin rather
    // than a guess: the claim its comment always made, that the narrowed arm is the conservative reading,
    // is asserted rather than asserted-in-prose (L407).
    static let rows = 12
}
