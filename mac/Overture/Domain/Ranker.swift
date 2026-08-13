import Foundation

// Fit-score ranker. Pure, deterministic scoring of an already-classified candidate. Used to be
// kept identical to a TypeScript mirror (ranker.ts); that mirror was retired in #493 once the
// app was confirmed to scout natively, so RankerFixtureTests (fixtures/ranker/cases.json) is now
// this logic's only locked spec, not a cross-language drift guard. See PLAN.md section 4.

enum Production: String, Decodable, Sendable { case selfProduced = "self", agency, unknown }
enum Profile: String, Decodable, Sendable { case strong, neutral, weak }
enum Coverage: String, Decodable, Sendable { case likelyUncovered = "likely_uncovered", unknown, likelyCovered = "likely_covered" }
enum PriorRelationship: String, Decodable, Sendable {
    case booked
    case declinedByYou = "declined_by_you"
    case warm
    case lostSoft = "lost_soft"
    case contacted
    case lostHard = "lost_hard"
    case none
}
enum Discipline: String, Decodable, Sendable, CaseIterable {
    case dance, opera, theater, music, band, comedy, other

    // #1657: what this genre is CALLED, in one place, because three surfaces show it (the row's genre
    // line, the genre editor's picker, and the fit reason's sentence) and they were free to disagree.
    //
    // `other` is not a genre. It is the classifier finding no genre word in the title or the presenter,
    // which is true of 53% of the queue, and the line said "Performance": a genre the app never read,
    // stated as though it had. That line is also the button that opens the genre editor (#1662), so on
    // more than half the queue the app invited a correction while arguing there was nothing to correct.
    var label: String {
        switch self {
        case .dance: return "Dance"
        case .opera: return "Opera"
        case .theater: return "Theater"
        case .music: return "Music"
        case .band: return "Band"
        case .comedy: return "Comedy"
        case .other: return "No genre read"
        }
    }
}
enum Tier: String, Decodable, Sendable { case high, longshot }

// #1648: whether Dan can reach ANYBODY about this show, as a scoring axis. Named for contacts on
// purpose: `Candidate.reachable` below is a completely different thing (the hard exclusion flag), and
// two meanings of "reachable" in one file is how a later edit goes wrong quietly.
//
// `unchecked` is the common case and must stay scoreless: 536 of the 559 untriaged shows have never
// been checked, and a show must not be punished for a question nobody asked it. It mirrors
// Reachability.ProbeResult, whose nil means exactly this.
enum ContactRoute: String, Decodable, Sendable, CaseIterable {
    case unchecked
    case emailFound = "email_found"
    case contactFormOnly = "contact_form_only"
    case socialOnly = "social_only"
    case weakContactOnly = "weak_contact_only"
    case noEmailFound = "no_email_found"

    // The one mapping from a stored probe result. nil (never checked) is not a verdict.
    init(probeResult: Reachability.ProbeResult?) {
        switch probeResult {
        case .none: self = .unchecked
        case .some(.emailFound): self = .emailFound
        case .some(.contactFormOnly): self = .contactFormOnly
        case .some(.socialOnly): self = .socialOnly
        case .some(.weakContactOnly): self = .weakContactOnly
        case .some(.noEmailFound): self = .noEmailFound
        }
    }
}

struct Candidate: Decodable, Sendable {
    var reachable: Bool
    var priorRelationship: PriorRelationship
    var production: Production
    var profile: Profile
    var coverage: Coverage
    var discipline: Discipline
    // #384: Dan already passed on THIS show (same org, same venue). Its own axis, NOT a
    // priorRelationship value, because the two are orthogonal: he can have booked an org happily and
    // still not want their particular annual show. As a relationship it would just be outranked by
    // "booked" and never apply to the orgs he works with most.
    var passedOnThisShow: Bool = false
    // #1648: deliberately has NO default, unlike passedOnThisShow above. A default is what let the
    // masthead's merit split hand-build a Candidate, silently omit an axis, and go on miscounting for
    // months (#1669). Without one, every Swift construction site is forced to answer, so the same class
    // of bug cannot recur on this axis. JSON still defaults, see init(from:) below.
    var contactRoute: ContactRoute
    // #2622: WHO was found, when an address was. Defaulted nil so every fixture and every caller written
    // before this scores exactly as it did, which is also the honest reading of the 113 contacts already
    // in the store: nobody has said who they are.
    var contactTier: ContactTier? = nil

    // Spelled out because providing init(from:) below stops Swift synthesising these. A nested enum
    // does not suppress the memberwise init, so every existing Candidate(...) call site is unaffected.
    enum CodingKeys: String, CodingKey {
        case reachable, priorRelationship, production, profile, coverage, discipline, passedOnThisShow,
             contactRoute
    }
}

// #1669 / #1648 Phase A2: the ONE place that turns a row's stored strings into a scoreable candidate.
// Every caller that scores an already-classified row goes through this, so an axis added later cannot
// be silently forgotten by one of them. It was forgotten once: the masthead's merit split hand-built a
// Candidate, omitted passedOnThisShow, and so measured a show Dan had turned down as if he never had.
//
// String-to-enum defaults when a raw value doesn't match any case:
//   Production -> .unknown, PriorRelationship -> .none, Profile -> .neutral,
//   Coverage -> .unknown, Discipline -> .other
extension Candidate {
    // Any row that reached the store is reachable (unreachable events are never inserted), so
    // `reachable` is not a parameter. Note it is the hard EXCLUSION flag, nothing to do with whether
    // a contact address was found.
    init(rawDiscipline: String, rawProduction: String, rawPriorRelationship: String,
         rawProfile: String, rawCoverage: String, passedOnThisShow: Bool,
         contactRoute: ContactRoute, contactTier: ContactTier? = nil) {
        self.init(reachable: true,
                  priorRelationship: PriorRelationship(rawValue: rawPriorRelationship) ?? .none,
                  production: Production(rawValue: rawProduction) ?? .unknown,
                  profile: Profile(rawValue: rawProfile) ?? .neutral,
                  coverage: Coverage(rawValue: rawCoverage) ?? .unknown,
                  discipline: Discipline(rawValue: rawDiscipline) ?? .other,
                  passedOnThisShow: passedOnThisShow,
                  contactRoute: contactRoute,
                  contactTier: contactTier)
    }
}

// Decoded in an EXTENSION so the memberwise init survives (declaring init(from:) in the body would
// suppress it). passedOnThisShow is decodeIfPresent, so every ranker fixture written before #384
// still decodes rather than throwing on a missing key.
extension Candidate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try c.decode(Bool.self, forKey: .reachable)
        priorRelationship = try c.decode(PriorRelationship.self, forKey: .priorRelationship)
        production = try c.decode(Production.self, forKey: .production)
        profile = try c.decode(Profile.self, forKey: .profile)
        coverage = try c.decode(Coverage.self, forKey: .coverage)
        discipline = try c.decode(Discipline.self, forKey: .discipline)
        passedOnThisShow = try c.decodeIfPresent(Bool.self, forKey: .passedOnThisShow) ?? false
        // #1648 follows #384's precedent exactly: decodeIfPresent, so every ranker fixture written
        // before this axis existed still decodes and keeps its expected score, rather than throwing on
        // a missing key. `.unchecked` scores zero, which is what "this case never had an answer" means.
        contactRoute = try c.decodeIfPresent(ContactRoute.self, forKey: .contactRoute) ?? .unchecked
    }
}

struct FitResult: Equatable, Sendable {
    var excluded: Bool
    var score: Int
    var tier: Tier
}

enum Ranker {
    // A strong cold prospect clears this; a flat-neutral or dead-zone one does not.
    static let highTierThreshold = 5

    // Prior warm relationship is the top weight: a prior booking dominates every
    // other signal combined. A prior cold contact is only a mild nudge.
    static func priorPoints(_ r: PriorRelationship) -> Int {
        switch r {
        case .booked: return 20
        // #1362: a past decline is usually just an old date conflict, irrelevant to a future pitch.
        // Kept as a distinct status (it still exists in booking history) but weighted neutral, like a
        // cold lead, so it neither floats a declined show to the top nor auto-corrects a warm lead.
        case .declinedByYou: return 0
        case .warm: return 10
        case .lostSoft: return 3
        case .contacted: return 0   // #70: a bare send that got silence is not warm
        case .lostHard: return -20
        case .none: return 0
        }
    }
    static func productionPoints(_ p: Production) -> Int {
        switch p { case .selfProduced: return 2; case .unknown: return 0; case .agency: return -2 }
    }
    static func profilePoints(_ p: Profile) -> Int {
        switch p { case .strong: return 2; case .neutral: return 0; case .weak: return -2 }
    }
    static func coveragePoints(_ c: Coverage) -> Int {
        switch c { case .likelyUncovered: return 2; case .unknown: return 0; case .likelyCovered: return -2 }
    }
    // #350: Choral folded into Music, merged at Choral's former score (Dan's call) rather than
    // demoting it to Music's old baseline. "other" (no discipline signal) is the sole baseline.
    // Dance highest.
    //
    // #970 Phase 0 made `other` REACHABLE for the first time: the classifier used to fall back to
    // `.music`, so "no idea" scored 1 and this 0 applied to nothing. It stays 0 because Phase 0 also
    // taught the classifier real music words, which is what keeps the change invisible: every live row
    // that scores at or above the high-tier threshold carries a music word (piano, orchestra, concert)
    // and stays `.music`, so nothing is demoted. Only genuinely unreadable titles land here, and they
    // already score at or below 3. Do NOT "fix" this to 1 to hold scores still: it would shift every
    // case in the shared ranker fixture spec by a point for no reason.
    static func disciplinePoints(_ d: Discipline) -> Int {
        switch d {
        case .dance: return 3
        case .opera, .theater: return 2
        case .music, .band, .comedy: return 1
        case .other: return 0
        }
    }

    // #384: Dan already told us he doesn't want this show. A nudge below the high-fit cutoff (5), not
    // a burial (Dan's call): a typical strong show scores 9, so this lands it at 4, stopping it being
    // promoted while leaving it near the top of the longshots, where a change of heart next season
    // costs nothing. Deliberately much lighter than a hard loss (-20): his taste is not the same thing
    // as a client's rejection.
    static func passedPoints(_ passed: Bool) -> Int { passed ? -5 : 0 }

    // #1648, Dan's weights (2026-07-28), chosen against the measured live distribution rather than by
    // feel. Scores pile up on a few values: 58 high rows sit at exactly 8 and 280 longshots at exactly
    // 0, so a penalty of 4 demotes 86 of 124 high rows and a bump of 5 promotes 403 of 435 longshots.
    // Both of those cliffs are avoided deliberately.
    //
    // A dead end costs the same as a show Dan passed on, which is the honest comparison: both mean this
    // one is not worth his attention now, neither is a permanent judgment on the org. It carries his
    // rule ("it's not a high fit if I can't email anybody about it") as far as a score can, dropping an
    // ordinary strong show out of high fit, while deliberately NOT dislodging a past client whose
    // details he already holds in Downbeat. He chose the penalty alone over a hard tier floor.
    //
    // `unchecked` and `weakContactOnly` both score zero, for different reasons: nobody asked, versus
    // asked and got a front desk, which is not evidence he can reach the act.
    // #2622, Dan's weights (2026-08-13), chosen against the measured live distribution the same way
    // #1648's were rather than by feel. Over the 29 shows then sitting at `email_found`, the scores pile
    // up either side of the high-fit line: 11 shows at exactly 4 and 5 at exactly 5, so both directions
    // are violent and both were chosen deliberately.
    //
    //   primary    3   promotes the four shows one point below the line whose check found somebody who
    //                  can say yes. That is the intended behaviour, not a side effect.
    //   secondary  2   unchanged: today's flat weight, so a co-performer's address is worth what an
    //                  address has always been worth.
    //   tertiary  -1   Dan set this himself, over the 0 that was recommended. A nudge, not a burial, the
    //                  same shape as `noEmailFound`'s -5 being deliberately lighter than a tier floor.
    //                  Measured effect: Operation Mincemeat 8 to 5 (stays exactly on the line), We've Been
    //                  Here Before 6 to 3 (leaves high fit), Jordan Smart 4 to 1, Marcus Monroe 2 to -1.
    //   unknown    2   every contact stored before this shipped, and any the run declines to judge. It
    //                  scores what it scored yesterday, so nothing moves under a show on the strength of
    //                  a fact nobody has established (the issue's open question 4, left honest).
    static func contactRoutePoints(_ r: ContactRoute, tier: ContactTier? = nil) -> Int {
        switch r {
        case .emailFound:
            switch tier {
            case .primary: return 3
            case .secondary: return 2
            case .tertiary: return -1
            case nil: return 2
            }
        case .contactFormOnly: return 1
        // #2612: BELOW a contact form, and no longer the -5 of a dead end. Dan's call, 2026-08-13, asked
        // directly after the first version scored it level with a form: "social dm is worth less than a
        // contact form. I probably won't use it unless it's a really good fit in other ways like I
        // mentioned." Zero says exactly that. It neither lifts a show nor buries it, so an Instagram-only
        // show reaches high fit only when the rest of it is strong, which is the behaviour he described.
        //
        // It shares that zero with `weakContactOnly` and `unchecked`, which is not a collapse of three
        // meanings into one: those two score zero for their own reasons (asked and got a front desk,
        // versus nobody asked), and the three stay distinct everywhere it matters, in the verdict, the
        // badge and what the card offers.
        case .socialOnly: return 0
        case .weakContactOnly: return 0
        case .noEmailFound: return -5
        case .unchecked: return 0
        }
    }

    static func scoreFit(_ c: Candidate) -> FitResult {
        let score = priorPoints(c.priorRelationship)
            + productionPoints(c.production)
            + profilePoints(c.profile)
            + coveragePoints(c.coverage)
            + disciplinePoints(c.discipline)
            + passedPoints(c.passedOnThisShow)
            + contactRoutePoints(c.contactRoute, tier: c.contactTier)
        let tier: Tier = score >= highTierThreshold ? .high : .longshot
        return FitResult(excluded: !c.reachable, score: score, tier: tier)
    }
}
