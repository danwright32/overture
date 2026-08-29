import Foundation

// Bridges stored prospects into OutcomeStats samples for the patterns view (#42): pick a
// dimension to group by, and each prospect becomes a sample carrying whether it was
// contacted and how it turned out. The tallying/rates live in OutcomeStats (tested).
enum OutcomePatterns {
    enum Dimension: String, CaseIterable, Sendable {
        case production, discipline, tier, coverage, profile, venue

        var label: String {
            switch self {
            case .production: return "Production"
            case .discipline: return "Discipline"
            case .tier: return "Fit tier"
            case .coverage: return "Coverage"
            case .profile: return "Profile"
            case .venue: return "Venue"
            }
        }
    }

    // The display rows: a tally per dimension value, only where something was contacted
    // (no 0/0 noise), ranked by bookings then volume. The view just renders these.
    static func rankedTallies(from prospects: [Prospect], by dimension: Dimension) -> [(name: String, tally: OutcomeTally)] {
        OutcomeStats.tallyByDimension(samples(from: prospects, by: dimension))
            .filter { $0.value.contacted > 0 }
            .sorted { ($0.value.booked, $0.value.contacted) > ($1.value.booked, $1.value.contacted) }
            .map { (name: $0.key, tally: $0.value) }
    }

    // Below this many contacted prospects a rate is noise (1 of 1 = 100% reads as a strong
    // signal but isn't), so the view marks the group "too few to tell" instead (#64).
    static let lowSampleThreshold = 4
    static func isLowSample(_ tally: OutcomeTally) -> Bool { tally.contacted < lowSampleThreshold }

    // #885: the two lines Dan reads on this screen, and the rule that suppresses half of one of them.
    //
    // These are statistical claims he is invited to ACT on (pitch more of this discipline, drop that
    // one), and they were assembled in the view body: the low-sample suppression as a ternary, the
    // percentage by a view-private formatter, and "replied" as a bare bit of arithmetic.
    //
    // Below the threshold the percentage is hidden entirely, because a booking rate over two shows is
    // noise wearing the costume of a number, and a number is what he would believe.
    static func bookedLine(_ tally: OutcomeTally) -> String {
        let base = "\(tally.booked) booked of \(tally.contacted)"
        return isLowSample(tally) ? base : base + percentSuffix(tally.bookingRate)
    }

    // "Replied" includes the ones who went on to BOOK: somebody who booked certainly replied. That rule
    // was arithmetic in a view, and it is the difference between an honest response rate and one that
    // silently undercounts every success.
    static func repliedLine(_ tally: OutcomeTally) -> String {
        "\(tally.replied + tally.booked) replied" + percentSuffix(tally.responseRate)
    }

    // #2251: how the lost ones ended, with a confirmed SILENCE named apart from a refusal.
    //
    // #2112 gave a closed-out silence its own value precisely because a silence and a no are different
    // results, and until now nothing read it: `lostReasons` was written on every pass and had no reader
    // anywhere in the app, which is exactly the shape L46 names. The data only accumulates from the day
    // it is read, so the reader is the point.
    //
    // Counts, never a rate, so this is NOT suppressed at low sample the way the booking rate is: two
    // shows is a noisy percentage but an honest pair of numbers.
    static func lostSplitLine(_ tally: OutcomeTally) -> String? {
        guard tally.lost > 0 else { return nil }
        let parts = ShowOutcome.pitched
            .filter { $0 != .booked }
            .compactMap { outcome -> String? in
                let count = tally.lostReasons[outcome] ?? 0
                return count > 0 ? lostFragment(count: count, outcome: outcome) : nil
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // #2586: one row of that split, extracted so the case it exists for can be reached from a test.
    //
    // An ending with no counted phrase is a GAP in the vocabulary, not a row to drop. Dropping it would
    // leave the show inside the lost TOTAL this line claims to break down while removing it from the
    // breakdown, so the count and the rows it promises would disagree (L16), and a missing row is far
    // harder to notice than an ugly one. The raw value is deliberately not prose: it reads as broken, so
    // somebody fixes it, where the menu label read as very slightly off and nobody would.
    //
    // Unreachable for the endings this line walks, and two gates keep it that way: the exhaustive switch
    // on `countedPhrase` breaks the build when a case is added, and `CountedPhraseHasNoDefaultTests`
    // fails if a pitched ending ships without a phrase.
    static func lostFragment(count: Int, outcome: ShowOutcome) -> String {
        "\(count) \(outcome.countedPhrase ?? outcome.rawValue)"
    }

    static func percentSuffix(_ rate: Double?) -> String {
        guard let rate else { return "" }
        return " · \(Int((rate * 100).rounded()))%"
    }

    // The dimension values are short slugs ("self", "agency", "music", "high"); a readable cap is enough.
    static func slugLabel(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func samples(from prospects: [Prospect], by dimension: Dimension) -> [OutcomeSample] {
        prospects.map { p in
            // Phase F: with the A3 rollup gone, a reply lives on the contact, not the lead outcome.
            // Count an otherwise-unresolved lead as replied when a contact wrote back.
            // #2226: booked FIRST, and asked of the show rather than of its `outcome` field. The only
            // way Dan can record a booking by hand is the Mark… menu, which writes the CONTACT, so the
            // show's own outcome stayed `noResponse` with a reply on a contact and the line below turned
            // every hand-recorded booking into a reply. That is every booking there has been, inside the
            // report whose headline number is the booking rate.
            let effectiveOutcome: Outcome = p.isBooked ? .booked
                : (p.outcome == .noResponse && p.recipients.contains(where: \.replied)) ? .replied : p.outcome
            return OutcomeSample(wasContacted: p.wasProvablyContacted, outcome: effectiveOutcome,
                                 dimension: dimensionValue(of: p, by: dimension),
                                 // And the source from wherever the booking was recorded, or the auto and
                                 // manual halves stop summing to the total they split.
                                 outcomeSource: p.isBooked ? p.bookingSource
                                     : p.outcomeSourceRaw.flatMap(OutcomeSource.init),
                                 // #2399: the ending itself, from the one field. This is what the three
                                 // groups are counted from, and it is why the lost count is no longer
                                 // structurally zero: it used to be read off `Outcome.lostSoft`/`.lostHard`,
                                 // which nothing in the app has ever written (#2401).
                                 //
                                 // A booking detected from Downbeat writes the legacy outcome without
                                 // touching the one field, so `isBooked` is folded in here rather than left
                                 // to a second reader: a show booked automatically must count as booked.
                                 showOutcome: p.isBooked ? .booked : p.showOutcome,
                                 aContactReplied: p.recipients.contains(where: \.replied))
        }
    }

    // #1670, then #1715 for the four beside it: EVERY axis this report groups by reads the value the
    // pitch actually went out under, falling back to the live value only for a row that was never sent,
    // which is the one case where nothing was frozen.
    //
    // The live value can move after the send on all five: a genre correction moves the discipline, a
    // producer correction moves the production, a contact check (#1648) moves the coverage, the profile
    // and the tier. Grouping by it buckets a show under something it did not have when Dan pitched it,
    // and the report then mixes two scoring bases with nothing marking the change.
    //
    // #1715 is what that cost. #1670 fixed the tier and the four frozen fields beside it stayed
    // write-only: they were stamped on every send and read by nothing anywhere in the app, so the data
    // they exist to protect was collected and thrown away, while this report went on reading the values
    // the scout keeps refreshing (L46, L30).
    //
    // `venue` has no frozen counterpart and is therefore live, deliberately: nothing freezes it, and a
    // fallback that invented one would be worse than the honest live read. `fitScoreAtSend` is the one
    // frozen field with no consumer here, because this report has no score dimension; see #1715.
    private static func dimensionValue(of p: Prospect, by dimension: Dimension) -> String {
        switch dimension {
        case .production: return p.productionAtSend ?? p.production
        case .discipline: return p.disciplineAtSend ?? p.discipline
        case .tier: return p.tierAtSend ?? p.tier
        case .coverage: return p.coverageAtSend ?? p.coverage
        case .profile: return p.profileAtSend ?? p.profile
        case .venue: return p.venue ?? "No venue"
        }
    }

    // One auto-detected booking behind a segment's "auto-detected" count (#212), so Dan can
    // open the count and audit which Downbeat matches were booked on his behalf.
    struct AutoBookedBooking: Equatable, Identifiable {
        let groupName: String
        let performanceDate: String?
        let venue: String?
        var id: String { "\(groupName)|\(performanceDate ?? "")|\(venue ?? "")" }
    }

    // The auto-detected bookings for one dimension value, oldest performance first. Only
    // outcome == booked with an auto source counts; manual confirmations and other segments
    // are excluded, matching the count shown in the patterns row.
    static func autoBookedBookings(from prospects: [Prospect], by dimension: Dimension,
                                   value: String) -> [AutoBookedBooking] {
        prospects
            .filter {
                $0.outcome == .booked
                    && $0.outcomeSourceRaw == OutcomeSource.auto.rawValue
                    && dimensionValue(of: $0, by: dimension) == value
            }
            .sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            .map { AutoBookedBooking(groupName: $0.groupName, performanceDate: $0.performanceDate,
                                     venue: $0.venue) }
    }
}

// #885 (guard sweep): the booking split's two lines. "Auto-detected" versus "confirmed by you" is a
// provenance claim about where a booking came from (#117), and Dan audits it by clicking through.
extension OutcomePatterns {
    static func autoDetectedLine(_ tally: OutcomeTally) -> String { "\(tally.bookedAuto) auto-detected" }

    static func confirmedByYouLine(_ tally: OutcomeTally) -> String { "\(tally.bookedManual) confirmed by you" }
}
