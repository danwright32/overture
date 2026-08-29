import Testing
import Foundation

// #1927: the queue has three ONE-SHOT channels, and this holds all three to one pattern.
//
// A one-shot channel is a piece of state a handler watches with `.onChange` in order to DO something once:
// jump the scroll, land on a show, enter a focused leads list. `.onChange` fires on a CHANGE, so a channel
// that carries only WHERE to go cannot express "the same request, again", which is a real thing a person
// does: search a show, scroll away, search it again. Dan found that on the scroll channel on 2026-08-01
// and it was fixed there (#1774) by giving each request its own identity.
//
// The other two carried a bare destination and were correct only because their handlers cleared them back
// to nil afterwards. That is what this suite exists to stop coming back, and it is invisible without one:
// delete a reset and a repeat tap dies while NO test anywhere goes red, which is how #1774 shipped in the
// first place. Enforced over the CLASS rather than over the instance that was reported, so the third
// channel is covered by the same lines as the two this issue named (L30).
@Suite("Every one-shot queue channel carries an identity (#1927)")
struct OneShotChannelGuardTests {
    private let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")

    // The three channels, each with the declaration that must be present. Hand-written, so what it cannot
    // see is a channel nobody listed here (L96); the count below is what makes adding a fourth a
    // deliberate act rather than a silent omission.
    private static let channels: [(name: String, declaration: String)] = [
        ("jumpTarget", "@State private var jumpTarget: QueueJumpRequest?"),
        ("deepLinkedKey", "@Binding var deepLinkedKey: LeadDeepLink?"),
        ("deepLinkedKeys", "@Binding var deepLinkedKeys: LeadsDeepLink?"),
    ]

    // The path has to be right or SourceGuardHelper returns "", and every check below would then fail for
    // a reason that has nothing to do with the code, or pass vacuously. This is what tells those apart.
    @Test func theSourceIsActuallyRead() {
        #expect(!queueView.isEmpty, "QueueView.swift did not resolve; every guard below is unmeasured")
        #expect(Self.channels.count == 3, "a fourth channel needs a line above, or it is exempt from all of this")
    }

    // Each channel holds a REQUEST, never a bare destination.
    //
    // Worth being straight about what this one is and is not. The COMPILER already enforces most of it:
    // putting `String?` back here does not build, because RootView hands these bindings request values. So
    // this is not the load-bearing guard, and a mutation proving it fail is a build failure rather than a
    // red test. What it adds is that the three declarations are named in one place and read as a set, so
    // swapping one for a different type that happens to compile is refused rather than passed.
    @Test func everyChannelIsDeclaredWithARequestTypeRatherThanADestination() {
        for channel in Self.channels {
            #expect(queueView.contains(channel.declaration),
                    "\(channel.name) must be declared holding a request, not its bare destination")
        }
    }

    // This is the load-bearing one, and the rule that had no enforcement at all before #1927. A handler
    // clearing its channel back to nil is the OLD mechanism for making a repeat request fire. Leaving one
    // in place means the request's identity is never the thing actually being relied on, so removing the
    // reset later looks safe and is not, which is exactly the state #1774 was found in.
    @Test func noHandlerClearsAChannelBackToNil() {
        for channel in Self.channels {
            #expect(!queueView.contains("\(channel.name) = nil"),
                    "\(channel.name) is cleared somewhere; the request's own identity is what should make a repeat fire")
        }
    }
}
