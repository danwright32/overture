import Foundation

// #2365: the ambient facts every stage question is asked against, carried as ONE value.
//
// `StageNavigation` answers a family of questions that all need the same background: which stage holds
// this show, how many are in each, will the Queue show me this at all, which shows may the search bar
// find. Each of them used to take `today`, `now` and `geo` as three separate arguments, each defaulted,
// repeated at eleven shipping call sites and a hundred test ones. Two defects follow from that shape,
// and neither is a matter of taste.
//
// ONE CLOCK. `today` and `now` are two spellings of one instant. As separate arguments a caller could
// pass a day derived from one clock beside a time taken from another, and nothing could notice: the
// call still compiles, still runs, and answers a question about a day that is not the day it is
// reasoning in. Deriving the day from the instant inside this value makes that unrepresentable rather
// than merely unlikely. `EasternDate` is asked for the derivation, because Overture's whole date
// vocabulary is Eastern (#177) and a window judged a day early drops a show Dan could still pitch.
//
// NOTHING DEFAULTS TO OFF. `geo` defaulted to `.none` at every call site, and a surface that SHOULD
// have applied Dan's geography refusals and did not is indistinguishable from one that had none to
// apply. #901 wrote this rule down here already, about the conflict gate the Prep pill forgot and the
// Prep run then honoured: "a default is how a caller forgets a gate invisibly". #1570 is the same
// story about this very gate, which had two homes that disagreed about 4 of 588 shows. So the context
// is required, and because it is one argument rather than four that is a cheap requirement to meet.
//
// WHY A VALUE RATHER THAN MORE ARGUMENTS. Every new fact the stage predicate needs would otherwise be
// a fourth, then a fifth argument threaded through all eleven call sites and every test. #2365 adds
// exactly such a fact (whether a show is a past client's, which decides how far ahead it is offered
// for triage), and it lands here without touching a single call site.
struct StageContext: Equatable, Sendable {
    // Overture's day, in New York, as "yyyy-MM-dd". Derived from `now` unless a test pins it.
    let today: String
    let now: Date
    // Dan's standing geography refusals. Not optional and not defaulted: see above.
    let geo: GeoRefusals
    // #2365: which of Dan's watched calendars are a past client's, so the stage predicate can offer a
    // returning client's season a year ahead while holding everyone else to 90 days. Required for the
    // same reason `geo` is: a surface that built one without it would quietly answer "nobody is a
    // client", and its Scout list would be short by exactly the shows Dan most wants to see.
    let clients: ClientWindow

    // `today` is deliberately the LAST parameter and deliberately optional, so the ordinary spelling at
    // a call site is `StageContext(now:geo:)` and the derivation is what happens unless somebody goes
    // out of their way. `StageContextTests.noProductionCallSitePinsTheDay` fails if a shipping file ever
    // does go out of its way, which is what keeps the one-clock property true of the APP rather than
    // only of this type.
    init(now: Date = Date(), geo: GeoRefusals, clients: ClientWindow, today: String? = nil) {
        self.now = now
        self.geo = geo
        self.clients = clients
        self.today = today ?? EasternDate.today(now)
    }

    // #1962's memo, lifted to the context: a copy whose geography has already worked out the verdict for
    // every distinct place these shows sit in, built once per render pass and shared by every sweep in it.
    // Resolving the place table was the single most expensive thing the queue's rebuild did, about 1,270
    // of 14,856 main-thread samples on the live store, because three sweeps each asked about every show
    // and none reused the others' answer.
    //
    // It hands back a whole context rather than a bare `GeoRefusals` so the render pass carries ONE value
    // through its sweeps. Unpacking the geography to resolve it and then passing the pieces around
    // separately is how the day and the instant came apart in the first place.
    //
    // The day is carried across explicitly and NOT re-derived: re-deriving would silently discard a day a
    // caller had pinned, which is the one thing a memoisation step must not do.
    func resolvingPlaces(of prospects: [Prospect]) -> StageContext {
        StageContext(now: now, geo: geo.resolving(prospects), clients: clients, today: today)
    }
}
