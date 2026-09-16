import Foundation

// #3347 and #2258. How a listing BILLS somebody, which is the thing a tier is supposed to be judged
// against and the one thing a run can carry across from a person's own site instead.
//
// `primary` is defined in `docs/prep-runbook.md` as whoever could actually hire Dan, and the runbook
// says the rank must be judged "from the page you actually read". On "An Evening of Chills and Thrills" the
// run emitted two people with the identical role string "Producer and performer" at `primary`, while the
// page bills both of them under a bare `Featuring:` and credits neither as producing anything. The names
// here and in the tests are STAND-INS with the same shape: the real ones are performers on a real show,
// this repository is public, and what the rule turns on is where a name sits relative to a cast marker
// and a credit clause rather than who it is (L155, L222). For one of them there is at least a basis, since her own site
// names a production company; for the other there is none in the listing at all.
//
// THE SIGNAL WAS CHOSEN BY MEASUREMENT, not by reading the issue. #3347 proposes treating an identical
// role string across two people as the tell: across every archived run on this Mac (2026-09-06) 20 of 68
// show-answers with two or more contacts share a role string and 6 carry more than one `primary` sharing
// one, and at least half of those six are real co-producing pairs the listing names as such, so that
// rule fires on the ordinary case (L93). This rule fires on 2 of 108 `primary` contacts across the same
// archives, and those two are exactly the pair #3347 reports.
//
// EVERY UNANSWERABLE CASE IS FALSE, which is what makes it safe to hold a tier down on. No listing, no
// name, a page that draws no hierarchy, a person the page does not name, or a page that was CUT: each is
// a question this could not answer, and reading any of them as "billed as cast" would overrule the run
// on the strength of a page nobody read (L98, L11).
enum BilledHierarchy {

    // The markers a listing uses to start its cast list. Anything after one of these is billed as being
    // ON the show; what makes somebody a decision maker is a CREDIT, wherever on the page it sits.
    // copy-inventory:ignore-start  parser tokens matched against a listing page, never Overture's voice
    private static let castMarkers = ["featuring:", "starring:", "with:", "cast:",
                                      "featuring ", "starring "]

    // The credit verbs, in the shape a credit takes: a verb, then at most a short span, then "by".
    // Deliberately the same family `ProducerShapedName` reads, and deliberately NOT that function: this
    // asks whether a PERSON is credited, which is a different question from what the credited party's
    // name is, and sharing one implementation would make each answer for the other (L342).
    private static let creditVerbs = ["produced", "directed", "created", "curated", "presented",
                                      "music directed", "music direction", "written"]
    // copy-inventory:ignore-end

    // How far before a name a credit may end and still be crediting THEM. Set from the real corpus,
    // where the longest gap between a credit and the name it credits is a role phrase plus a connector
    // ("Produced and directed by Showpeople Resident Artist Colby Thompson", 44 characters).
    private static let creditReach = 80

    // #2625: whether a tier is an answerable question about this contact at all.
    //
    // A tier says who could actually hire Dan. A bare shared inbox with no person attached cannot be
    // judged on that, and the run was judging it anyway: measured across every archived run, 2026-09-06,
    // 22 of 447 contacts carry no name and THIRTEEN of those carry `primary`, every one a
    // `generic_inbox`. That is the strongest available claim made about the weakest available finding,
    // and it lifted the fit score on 13 real shows.
    //
    // Dan's call, 2026-09-06, shown the measurement and told it moves those shows down his queue: no
    // tier at all. `ContactTier` already means exactly that by nil, so this needs no fourth case and no
    // default, which is the L113 trap the issue names: a missing entry that silently takes a fallback
    // branch is indistinguishable from a deliberate choice.
    //
    // It lives HERE, beside the billing rule, because both answer one question: is the rank the run
    // declared supported by anything. One is about the page and one is about the contact, and a caller
    // that asked only one of them would be applying half a rule (L247).
    static func tierIsAnswerable(name: String?) -> Bool {
        !(name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func billedAsCastOnly(name: String?, inListingText text: String?,
                                 truncated: Bool = false) -> Bool {
        // A page that was CUT cannot support this, for #2698's reason: the credit is often the last block
        // on a listing, which is exactly what a cut removes, so a name appearing only in the cast on a cut
        // page says nothing about whether it was also credited.
        guard !truncated else { return false }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let text, !text.isEmpty
        else { return false }

        let haystack = text.lowercased()
        let needle = name.lowercased()
        guard let marker = firstCastMarker(in: haystack) else { return false }

        // EVERY occurrence, not the first. A page that credits somebody and then lists them in the cast is
        // the ordinary shape for a self-producing performer, who is the single most valuable contact
        // Overture can find, so one occurrence above the marker is enough to say they are not cast only.
        var occurrences: [Range<String.Index>] = []
        var from = haystack.startIndex
        while let found = haystack.range(of: needle, range: from..<haystack.endIndex) {
            occurrences.append(found)
            from = found.upperBound
        }
        guard !occurrences.isEmpty else { return false }
        guard occurrences.allSatisfy({ $0.lowerBound >= marker.upperBound }) else { return false }

        // A credit naming them anywhere on the page, including BELOW the cast list, which the live corpus
        // shows is where 54 Below routinely puts it.
        return !occurrences.contains { isCredited(at: $0, in: haystack) }
    }

    private static func firstCastMarker(in haystack: String) -> Range<String.Index>? {
        castMarkers.compactMap { haystack.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func isCredited(at occurrence: Range<String.Index>, in haystack: String) -> Bool {
        let start = haystack.index(occurrence.lowerBound, offsetBy: -creditReach,
                                   limitedBy: haystack.startIndex) ?? haystack.startIndex
        let before = haystack[start..<occurrence.lowerBound]
        // The credit has to END in this window, and it ends at "by": a window holding "produced" with the
        // "by" beyond the name is a credit of somebody else that this name happens to follow.
        guard let by = before.range(of: "by", options: .backwards) else { return false }
        let clause = before[before.startIndex..<by.lowerBound]
        guard creditVerbs.contains(where: { clause.contains($0) }) else { return false }
        // What sits BETWEEN the credit's "by" and this name decides whether the credit reaches it. A
        // sentence end or a cast marker in there means the credit named somebody else and this name
        // merely follows it, which is the ordinary shape on a self-produced show:
        // "Produced by Marlowe Fenn. Featuring: Marlowe Fenn, Rennick Slade" credits the first name
        // and not the second, and a window measured in characters alone reads both as credited.
        let between = before[by.upperBound...]
        guard !between.contains(".") else { return false }
        return !castMarkers.contains { between.contains($0) }
    }
}
