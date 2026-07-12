import Foundation

// #802, Dan's 3rd decision (2026-07-11): show him the do-not-contact guard working.
//
// When an org asks Dan to stop, their own calendar comes off the watchlist. But their shows can still
// appear on a VENUE's calendar he legitimately keeps watching (Carnegie is the obvious one), and the
// #769 record suppresses each of those, one at a time, so no email can go out.
//
// That protection is real, and it is silent, and silent is the problem. On the one mistake that cannot
// be taken back, Dan would rather SEE the guard working than trust that it is. His words settled it.
//
// So the tone here matters as much as the fact. This is NOT a warning: nothing is wrong, nothing needs
// fixing, and nobody has to do anything. It is a receipt.
enum SuppressionReport {
    static func summary(for orgs: [ScoutService.SuppressedOrg]) -> String? {
        guard !orgs.isEmpty else { return nil }

        let lines = orgs.map { org -> String in
            let shows = org.showCount == 1 ? "1 show" : "\(org.showCount) shows"
            return "\(org.orgName) (\(shows))"
        }
        let who = lines.joined(separator: ", ")
        let subject = orgs.count == 1 ? "An organization that asked" : "Organizations that asked"
        return "\(subject) you to stop still turn up on calendars you watch: \(who). "
             + "Nothing was added and nothing will go out to them."
    }
}
