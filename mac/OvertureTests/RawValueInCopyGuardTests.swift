import Testing
import Foundation

// #2734: the stored word must never reach Dan by accident.
//
// #1657 made `Discipline.label` the one place a genre is NAMED, precisely so the surfaces showing it
// cannot disagree, and two sentences bypassed it and interpolated the raw stored value instead. Each
// read fine alone, so nothing caught it: the card could call one genre two different names on one
// screen, which is what #2733 had to work around when it renamed Theater to Performing Arts.
//
// Both of those sites were fixed by #2733. What was missing, and is the durable half of this issue, is
// the guard that catches the NEXT one. It is not hypothetical: a third instance was written into
// `GenreCorrectionReportCopy` in #2688 the same week, and was caught only by reading the generated copy
// inventory cold.
//
// The rule is broader than genres on purpose. A raw value is a database word in any enum, and a sentence
// built from one says `never_heard_back` where it meant to say something a person wrote (L118).
@Suite("A stored raw value never reaches a sentence by accident (#2734)")
struct RawValueInCopyGuardTests {

    // The literals that legitimately hold a raw value today. Every one was READ before being
    // listed, and each is here for a different reason, so this is a set of decisions rather than a
    // silence.
    //
    // Kept as (file, fragment) pairs rather than whole literals, because a whole-literal match breaks on
    // any edit to the surrounding text and would be quietly dropped the next time somebody reformatted a
    // line. `everyExemptionStillMatchesSomething` below is the other direction (L96): an entry that has
    // stopped matching is deleted rather than left to hide a real one behind it.
    private struct Exemption {
        let file: String
        let fragment: String
        let why: String
    }

    private static let exemptions: [Exemption] = [
        Exemption(file: "QueueView.swift", fragment: "\\(dateLabel)|",
                  why: "a date group's SwiftUI identity, so two nights' rows are told apart in a list"),
        Exemption(file: "RunNightDrop.swift", fragment: "\\(Self.separator)",
                  why: "#2691's dropped night, stored self-describing and parsed back by DroppedNight"),
        Exemption(file: "BlockedCalendar.swift", fragment: "\\(Day.separator)",
                  why: "a blocked day's stable key, parsed back by BlockedCalendar.Day(key:)"),
        Exemption(file: "GeoRefusals.swift", fragment: "\\(discipline.rawValue)",
                  why: "a refusal's key, joined on a control character precisely so it cannot be prose"),
        Exemption(file: "WatchedSource.swift", fragment: "verdict_",
                  why: "a source failure's stored token, which SourceFailure.raw parses back"),
        // The two that ARE sentences, and are deliberate.
        Exemption(file: "OutcomePatterns.swift", fragment: "\\(outcome.countedPhrase ?? outcome.rawValue)",
                  why: "a deliberately UGLY fallback: it reads as broken so somebody fixes it, where a "
                      + "slightly-off menu label would be ignored. Unreachable, and two gates keep it "
                      + "that way: countedPhrase's switch is exhaustive, so a new ending breaks the "
                      + "build, and CountedPhraseHasNoDefaultTests judges the decision that break forces"),
        Exemption(file: "WatchedSource.swift", fragment: "The page came back as",
                  why: "unreachable by construction: SourceFailure.init(verdict:) routes only "
                      + "noDatedContent, unreadable and notRead into .verdict, and all three are named "
                      + "above this line. That init's switch is exhaustive over PageVerdict, so a fourth "
                      + "verdict breaks the build there before it could ever reach this sentence"),
    ]

    private static func offendingLiterals() throws -> [(file: String, text: String)] {
        let files = AppSourceWalk.urls(under: RepoRoot.app)
        #expect(files.count > 100, "found almost no app sources, which is a broken read")
        var found: [(file: String, text: String)] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SwiftSource.literals(in: source) where literal.text.contains(".rawValue") {
                found.append((file.lastPathComponent, literal.text))
            }
        }
        return found
    }

    private static func isExempt(_ hit: (file: String, text: String)) -> Bool {
        exemptions.contains { $0.file == hit.file && hit.text.contains($0.fragment) }
    }

    @Test func noSentenceIsBuiltFromAStoredRawValue() throws {
        let offenders = try Self.offendingLiterals()
            .filter { !Self.isExempt($0) }
            .map { "\($0.file): \($0.text)" }

        #expect(offenders.isEmpty, """
        A string is built from a stored raw value, so Dan reads the database word rather than the one \
        somebody wrote: \(offenders.joined(separator: " | ")). Name it through the type's own display \
        label (`Discipline.label` is the worked example, #1657). If the literal is an id, a storage key, \
        or a deliberately ugly fallback that cannot be reached, add it to `exemptions` above WITH the \
        reason and with what still reviews it.
        """)
    }

    // The other direction, so this cannot rot into a list of notes about code that no longer exists
    // (L96). An exemption that has stopped matching is one that could be hiding a real instance behind
    // its file name.
    @Test func everyExemptionStillMatchesSomething() throws {
        let hits = try Self.offendingLiterals()
        let stale = Self.exemptions.filter { e in
            !hits.contains { $0.file == e.file && $0.text.contains(e.fragment) }
        }

        #expect(stale.isEmpty, """
        An exemption matches nothing any more, so it is a note about code that has gone and it would let \
        a real instance in that file through unread: \(stale.map { "\($0.file) \($0.fragment)" }
            .joined(separator: " | ")). Delete it.
        """)
    }

    // And the exemptions say WHY, because an exclusion with no reviewer named is how copy ends up with
    // nobody reading it (L129).
    @Test func everyExemptionExplainsItself() {
        let unexplained = Self.exemptions.filter { $0.why.count < 30 }

        #expect(unexplained.isEmpty,
                "an exemption with no real reason is a silence: \(unexplained.map(\.file))")
    }
}
