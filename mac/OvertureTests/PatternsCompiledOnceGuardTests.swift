import Testing
import Foundation

// #3886: no NEW place in the app compiles a regular expression on every call.
//
// #3432 converted two files to `CompiledPattern` and shipped no scan, so nothing stopped the next per-call
// pattern, and there were 38 of them across 20 files when this was written. #3886 converted the ones on a
// per-row or per-comparison path; this is the half that keeps them converted (L613).
//
// WHAT THE ALLOW LIST IS. Every remaining site, with a written reason, and its COUNT. The count is what
// gives it teeth: a file already on the list cannot quietly gain a new per-call pattern, which is the
// realistic way this comes back. It fails in both directions on purpose. Upward means a new one landed.
// Downward means an entry went stale after somebody converted a site, and a stale allow list is how a
// list stops being read (L233, L182).
//
// THE REASONS ARE OF EXACTLY THREE KINDS, and saying which kind matters more than the prose:
//   PARAMETER  the pattern is a parameter or is built from data at call time, so it cannot be a fixed
//              static as written. Converting these needs a cache keyed on the pattern, which is a
//              different change with a different risk, and none of them is on a per-row path.
//   COLD       a literal pattern on a path that runs once per fetched page, per email or per draft,
//              never per row, per comparison or per render. #3886's own measurement is what separates
//              these from the rest: the cost that showed up in a sample was normalize(), reached once
//              per name per comparison.
//   THE TYPE   `CompiledPattern` itself, whose one construction IS the compile that happens once.
@Suite("No pattern is compiled per call outside the allow list (#3886)")
struct PatternsCompiledOnceGuardTests {

    struct Allowed {
        let file: String
        let sites: Int
        let reason: String
    }

    static let allowList: [Allowed] = [
        .init(file: "AlgoliaCalendar.swift", sites: 2,
              reason: "COLD: the cancelled-title prefix and the date in a calendar URL, once per event in a fetched feed payload."),
        .init(file: "CalendarMonthIndex.swift", sites: 3,
              reason: "COLD: href and month extraction from a fetched index page, once per page."),
        .init(file: "CompiledPattern.swift", sites: 1,
              reason: "THE TYPE: this construction is the compile that happens once, and every other site here exists to reach it."),
        .init(file: "DraftCheck.swift", sites: 3,
              reason: "PARAMETER for two (the pattern arrives as an argument to a per-sentence helper) and one built inside the static Patterns store across lines; VenuePatternsCompiledOnceGuardTests already asserts every NSRegularExpression in this file sits inside that store."),
        .init(file: "DraftGreeting.swift", sites: 5,
              reason: "COLD: greeting and ATTN shapes read once per drafted email, and one pattern interpolates the openers vocabulary."),
        .init(file: "EventClassifier.swift", sites: 3,
              reason: "PARAMETER: matches(_:_:) takes the pattern as an argument, and the word lists it is called with are data. The two wordSeparated patterns are literals on the scout's per-event path and are the strongest candidates for the next conversion."),
        .init(file: "EventDateInDraft.swift", sites: 1,
              reason: "PARAMETER: the pattern is built from the date being looked for."),
        .init(file: "ExtractedEventGuard.swift", sites: 1,
              reason: "COLD: a trailing parenthetical stripped once per extracted event."),
        .init(file: "FragmentMatchCorrection.swift", sites: 1,
              reason: "PARAMETER: the pattern is an argument, and the caller passes a stored profile string."),
        .init(file: "GmailMessage.swift", sites: 1,
              reason: "COLD: header parsing, once per message decoded."),
        .init(file: "GmailSignatureHealth.swift", sites: 1,
              reason: "PARAMETER: the pattern interpolates the keyword being searched for. Every fixed pattern in this file is already a compiled static."),
        .init(file: "OrgIdentity.swift", sites: 1,
              reason: "PARAMETER: the pattern is an argument to a shared helper."),
        .init(file: "Prospect.swift", sites: 1,
              reason: "COLD: the unicode-space fold in canonicalize, whose other two patterns were converted in #3886."),
        .init(file: "RecurringEventDate.swift", sites: 3,
              reason: "PARAMETER: two interpolate a weekday name; the third is a literal read once per extracted event."),
        .init(file: "SourceFetcher.swift", sites: 6,
              reason: "COLD: HTML normalisation and date sniffing, once per fetched page. The five whitespace and tag strips in this file were converted in #3886."),
        .init(file: "TicketLink.swift", sites: 1,
              reason: "COLD: anchor extraction from a fetched page, once per page."),
        .init(file: "TicketTailor.swift", sites: 1,
              reason: "PARAMETER: the pattern is an argument to the JSON field reader."),
        .init(file: "VenueParser.swift", sites: 1,
              reason: "PARAMETER: the pattern is an argument."),
        .init(file: "VenuePlaces.swift", sites: 1,
              reason: "COLD: an address newline folded to a comma, once per venue parsed."),
        .init(file: "VoiceGuidanceGuard.swift", sites: 1,
              reason: "PARAMETER: the pattern is built per forbidden term, from the term itself."),
    ]

    private static var allowed: [String: Allowed] {
        Dictionary(uniqueKeysWithValues: allowList.map { ($0.file, $0) })
    }

    // What the app actually holds, walked once. AppSourceWalk refuses out loud on a short walk, so this
    // cannot report a clean app because the path broke (#2311).
    private static func measured() -> [String: [PerCallPattern.Site]] {
        var out: [String: [PerCallPattern.Site]] = [:]
        for file in AppSourceWalk.appFiles() {
            let sites = PerCallPattern.sites(in: file.text)
            if !sites.isEmpty { out[file.name] = sites }
        }
        return out
    }

    @Test func noFileCompilesAPatternPerCallWithoutAWrittenReason() {
        let found = Self.measured()
        #expect(!found.isEmpty, "the scan found nothing at all, which means it measured nothing")
        for (name, sites) in found.sorted(by: { $0.key < $1.key }) where Self.allowed[name] == nil {
            Issue.record(Comment(rawValue: """
                \(name) compiles a regular expression on every call, at line(s) \
                \(sites.map { String($0.line) }.joined(separator: ", ")), and is not on this guard's \
                allow list. Hold the pattern in a `CompiledPattern` static, or add an entry here saying \
                which of the three kinds of reason applies to it (#3886).
                """))
        }
    }

    @Test func everyAllowedFileHoldsExactlyTheSitesItIsAllowed() {
        let found = Self.measured()
        for entry in Self.allowList {
            let sites = found[entry.file] ?? []
            if sites.count > entry.sites {
                Issue.record(Comment(rawValue: """
                    \(entry.file) now compiles \(sites.count) patterns per call, up from the \
                    \(entry.sites) this guard allows, at line(s) \
                    \(sites.map { String($0.line) }.joined(separator: ", ")). A file already on the \
                    allow list is the easiest place for a new one to land unnoticed (#3886).
                    """))
            }
            if sites.count < entry.sites {
                Issue.record(Comment(rawValue: """
                    \(entry.file) now compiles \(sites.count) patterns per call, fewer than the \
                    \(entry.sites) this guard allows. Lower the count, or remove the entry if it is \
                    now zero: an allow list that over-states what it permits stops being read (#3886).
                    """))
            }
        }
    }

    // An entry naming a file that is no longer there permits nothing and reads as though it does.
    @Test func noAllowListEntryNamesAFileTheAppNoLongerHas() {
        let names = Set(AppSourceWalk.appFiles().map(\.name))
        for entry in Self.allowList where !names.contains(entry.file) {
            Issue.record(Comment(rawValue: "the allow list names \(entry.file), which is not in the app"))
        }
    }

    // A reason, and one that says WHICH KIND. An entry carrying no reason while its neighbours each
    // carry one is evidence it was never reasoned about (L233).
    @Test func everyAllowListEntryCarriesAReasonOfAStatedKind() {
        #expect(!Self.allowList.isEmpty)
        for entry in Self.allowList {
            let kind = ["PARAMETER", "COLD", "THE TYPE"].first { entry.reason.hasPrefix($0) }
            #expect(kind != nil,
                    Comment(rawValue: "the allow list entry for \(entry.file) does not begin with one "
                            + "of PARAMETER, COLD or THE TYPE, so it does not say why it is allowed"))
            #expect(entry.reason.count > 40,
                    Comment(rawValue: "the allow list entry for \(entry.file) has no real reason written"))
        }
    }

    // The file #3886 was filed about, asserted directly rather than only through the count above, because
    // this is the site the measurement named and the one a later edit would most plausibly undo.
    @Test func theNameMatcherCompilesNothingPerCall() {
        let source = SourceGuardHelper.source("Overture/Domain/GroupNameMatch.swift")
        #expect(!source.isEmpty, "GroupNameMatch.swift could not be read, so this measured nothing")
        #expect(PerCallPattern.sites(in: source).isEmpty,
                "GroupNameMatch compiles a pattern per call again, on the scout's per-comparison path")
        #expect(source.contains("CompiledPattern("),
                "GroupNameMatch holds its own patterns as compiled statics")
    }
}
