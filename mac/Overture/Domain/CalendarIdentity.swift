import Foundation

// #2377: what makes two addresses the SAME watched calendar.
//
// Dan typed `La MaMa` / `https://ci.ovationtix.com/42` into the Sources sheet and was told "Already
// watching SoHo Playhouse's calendar." SoHo Playhouse is `https://ci.ovationtix.com/35583`: a different
// venue, on the same multi tenant ticketing host, distinguished only by the id in the PATH.
//
// The identity had been the bare DOMAIN, which holds for an organisation publishing its own website and
// fails on a ticketing host, where many unrelated venues share one domain. It was written out three
// times (the Sources sheet's add check, the pasted lead route's copy of the same check, and the source
// id), so this type exists to be the one place that answers the question.
//
// The rule is NOT "compare the whole address". An organisation that publishes /events, /calendar and
// /concerts must still read as ONE calendar and collapse to ONE id, or the same page is fetched, hashed
// and read three times every run. It is the host, plus the tenant segment only on the hosts where the
// path is what scopes the feed to a venue.
enum CalendarIdentity {

    // The identity of a calendar address: `bargemusic.org`, or `ci.ovationtix.com/35583` on a host whose
    // path carries the tenant. nil for anything that is not a usable web address.
    static func key(for urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { return nil }
        // Prefix strip rather than a substring replace: `www.` is only a prefix, and removing it wherever
        // it appears would rewrite a host that merely contains those four characters.
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard let tenant = tenant(in: url) else { return host }
        return "\(host)/\(tenant)"
    }

    // Whether two addresses name one calendar. False when either is unusable, which is what the three
    // host checks this replaces all did: an address we cannot read is not evidence of a match.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a = key(for: a), let b = key(for: b) else { return false }
        return a == b
    }

    // The stable, filename-safe form, used for a source's id and so for the name of its pinned page.
    // "source" for an unusable address, preserving what `newSourceId` has always produced for one.
    static func slug(for urlString: String) -> String {
        ScoutPagePin.safeName(key(for: urlString) ?? "source")
    }

    // The venue-scoping segment of the path, on the hosts that have one. nil everywhere else, which is
    // nearly everywhere: an organisation's own site has no tenants and its path means nothing here.
    private static func tenant(in url: URL) -> String? {
        // OvationTix. The feed is scoped to a venue ONLY by the numeric client id in the path, which is
        // why `clientId(from:)` already exists; reusing it keeps this from becoming a fourth copy of the
        // same URL poking, and finds the id wherever it sits (`ci.ovationtix.com/35583` and
        // `web.ovationtix.com/trs/cal/277` put it at different depths).
        if OvationTixCalendar.handles(url) { return OvationTixCalendar.clientId(from: url) }
        // ChorusConnection, named in #2377 as the same instance waiting to happen. Its tenant is the
        // first path segment and is a NAME rather than a number
        // (`tickets.chorusconnection.com/stonewall/events/1599`), so it cannot ride on the numeric rule
        // above. Covered now rather than when a second chorus is typed in, because the failure is a
        // silently shared identity in the store rather than a message on screen.
        // `pathComponents` leads with the root "/" itself, which is not a segment and would fold every
        // tenant on the host back together (it is only skipped by the numeric rule above by accident of
        // "/" not being a digit).
        if isChorusConnection(url) {
            return url.pathComponents.first { !$0.isEmpty && $0 != "/" }?.lowercased()
        }
        return nil
    }

    // Suffix match, so a look-alike like `chorusconnection.com.evil.com` never routes here. The same
    // shape the feed adapters' own `handles` checks use.
    private static func isChorusConnection(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "chorusconnection.com" || host.hasSuffix(".chorusconnection.com")
    }
}
