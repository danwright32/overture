import Foundation
import SwiftData

// #2688: what Dan's genre corrections can teach the classifier.
//
// His question, 2026-08-13: "does it learn from it at all?" It did not. `EventClassifier` is a fixed
// keyword matcher with no input but its own vocabulary, so a correction locked one row and moved one
// cell of the outcomes report, and the same unreadable title shape came back the following week.
//
// A fully independent entity, on the `RefusedContactAddress` / `OrgReachabilityAnswer` precedent (#2392,
// #1598): no `@Relationship` to Prospect, so the migration is purely additive and a show being dismissed,
// re-keyed or swept away can never quietly delete the lesson its correction taught.
@Model
final class GenreCorrection {
    // The show, so a second correction on the same row REPLACES the first rather than counting as two
    // votes. Unique at the STORE layer rather than only in the code that writes it.
    @Attribute(.unique) var id: String

    // What the classifier read, and what Dan said instead. Raw strings rather than the enum, like every
    // other stored vocabulary here, so a value written by a future build decodes as unknown rather than
    // being invented at the read.
    var classifierRead: String
    var danSaid: String

    // THE TEXT THE CLASSIFIER WAS ACTUALLY JUDGING, which is the whole reason the report can tell a
    // missing WORD from missing INPUT. Dan reading a genre off a page the classifier never saw is not a
    // gap in its vocabulary, and grouping on anything other than what it read would propose words for
    // titles that genuinely do not contain them.
    var title: String
    var presenter: String?
    var venue: String?

    var correctedAt: Date

    init(id: String, classifierRead: String, danSaid: String, title: String,
         presenter: String?, venue: String?, correctedAt: Date) {
        self.id = id
        self.classifierRead = classifierRead
        self.danSaid = danSaid
        self.title = title
        self.presenter = presenter
        self.venue = venue
        self.correctedAt = correctedAt
    }

    static func all(in context: ModelContext) -> [GenreCorrection] {
        ((try? context.fetch(FetchDescriptor<GenreCorrection>())) ?? [])
            .sorted { $0.correctedAt < $1.correctedAt }
    }

    // Record one correction, or update the one already standing for this show.
    //
    // A correction that AGREES with the classifier records nothing: it teaches no missing word, and
    // counting it would pad every group with rows where the vocabulary already worked.
    //
    // `classifierRead` is captured from the row as it stands BEFORE the write, which is the only moment
    // it is knowable. `classificationOverriddenByDan` is a bare boolean, and re-running the classifier
    // over the row later would answer with whatever the rules say THEN, which is a different question.
    static func record(_ p: Prospect, danSaid: Discipline, now: Date, in context: ModelContext) {
        let read = p.discipline
        guard read != danSaid.rawValue else { return }
        let existing = existingRow(id: p.naturalKey, in: context)
        guard let existing else {
            context.insert(GenreCorrection(id: p.naturalKey, classifierRead: read,
                                           danSaid: danSaid.rawValue, title: p.groupName,
                                           presenter: p.presenter, venue: p.venue, correctedAt: now))
            return
        }
        // He changed his mind. What the CLASSIFIER read is left exactly as it was: that is a fact about
        // the classifier at the moment it ran, and overwriting it with his own previous answer would turn
        // the record into a history of his opinions rather than of its gaps.
        existing.danSaid = danSaid.rawValue
        existing.correctedAt = now
    }

    private static func existingRow(id: String, in context: ModelContext) -> GenreCorrection? {
        var descriptor = FetchDescriptor<GenreCorrection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

enum GenreCorrectionReportCopy {
    // "Nobody has corrected anything yet" and "corrections came in and no pattern emerged" are different
    // facts, and only the second says anything about the classifier (L98).
    static let title = "What your genre corrections are teaching"

    // Names the genre and the number, because "add this word" without either is not something Dan can
    // act on: which list it goes in and whether it is worth the edit are the two things he needs.
    // Through `Discipline.label`, never the raw value. Caught by reading the generated inventory cold:
    // #2733 renamed the Theater genre to "Performing Arts" for display while deliberately KEEPING
    // `theater` as the stored value, so printing the raw value here would have shown Dan a genre name
    // that appears nowhere else in the app. One word must name one thing across the product (L118), and
    // `label` is the one place that decision lives (#1657).
    static func suggestion(discipline: Discipline, count: Int) -> String {
        "would have read \(count) show\(count == 1 ? "" : "s") as \(discipline.label)"
    }

    static let nothingRecordedYet =
        "No genre corrections recorded yet, so there is nothing to learn from."

    static func noPattern(correctionsSeen: Int) -> String {
        "\(correctionsSeen) genre correction\(correctionsSeen == 1 ? "" : "s") recorded, and no word "
            + "appears often enough yet to be worth adding to the classifier."
    }

    static func found(suggestions: Int, correctionsSeen: Int) -> String {
        "\(suggestions) word\(suggestions == 1 ? "" : "s") worth adding to the classifier, from "
            + "\(correctionsSeen) correction\(correctionsSeen == 1 ? "" : "s")."
    }

    // The report says what it CANNOT know, rather than presenting a partial history as a complete one
    // (L11). Corrections made before this shipped are not recoverable: the row recorded only THAT Dan
    // corrected it, never what the classifier had said.
    static let provenance =
        "Only counts corrections made since this started recording them. Earlier ones were never kept, "
            + "and re-reading those rows now would answer with today's rules rather than the ones that "
            + "got them wrong."
}

// The report. A list a PERSON reads and turns into a change to `EventClassifier`'s word lists, which
// then goes through the ordinary test suite.
//
// Deliberately nothing automatic. An automatic vocabulary would be a second writer of the genre with no
// reviewer, and the whole reason the current classifier is trustworthy is that its rules can be read.
enum GenreCorrectionReport {

    struct Suggestion: Equatable, Sendable {
        let word: String
        let discipline: Discipline
        let count: Int
    }

    struct Report: Equatable, Sendable {
        let suggestions: [Suggestion]
        let correctionsSeen: Int
        let provenance: String
        let summary: String
    }

    // A word has to appear on at least this many corrections to the SAME genre before it is proposed.
    //
    // Two, not one, and the reason is the second thing the issue asked to settle: a correction is not
    // always a classifier failure. Dan reading a genre off a page the classifier never saw is missing
    // INPUT, not a missing word, and at a floor of one every such correction would propose the words of
    // a title that genuinely does not carry the signal.
    static let floor = 2

    static func build(from corrections: [GenreCorrection]) -> Report {
        var counts: [String: [Discipline: Int]] = [:]
        for c in corrections {
            guard let said = Discipline(rawValue: c.danSaid) else { continue }
            // The title and the presenter, and deliberately NOT the venue.
            //
            // The venue is part of what the classifier judges, and it is stored on the record for exactly
            // that reason, but it is useless AS VOCABULARY and actively harmful in a count: every show at
            // one room shares its name, so a room Dan corrects five shows at would put its own name at the
            // top of the report ahead of every real signal. Measured on the very first run of this: with
            // the venue in, "merkin" and "hall" outranked the word the test existed to find.
            //
            // A room name is a fact about the room, never about the genre, which is the same reasoning
            // `EventClassifier.titleNamesTheRoom` already applies one layer down.
            let text = [c.title, c.presenter ?? ""].joined(separator: " ")
            for word in Set(words(in: text)) {
                counts[word, default: [:]][said, default: 0] += 1
            }
        }

        var suggestions: [Suggestion] = []
        for (word, byDiscipline) in counts {
            // A word Dan corrects to two different genres is not vocabulary for either. Proposing it
            // would make the classifier confidently wrong half the time, which is worse than leaving the
            // row unread.
            guard byDiscipline.count == 1, let (discipline, count) = byDiscipline.first else { continue }
            guard count >= floor else { continue }
            suggestions.append(Suggestion(word: word, discipline: discipline, count: count))
        }
        // Ranked by how much each would pay off, then alphabetically so two equal counts do not change
        // places between runs.
        suggestions.sort { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }

        let summary: String
        if corrections.isEmpty {
            summary = GenreCorrectionReportCopy.nothingRecordedYet
        } else if suggestions.isEmpty {
            summary = GenreCorrectionReportCopy.noPattern(correctionsSeen: corrections.count)
        } else {
            summary = GenreCorrectionReportCopy.found(suggestions: suggestions.count,
                                                      correctionsSeen: corrections.count)
        }
        return Report(suggestions: suggestions, correctionsSeen: corrections.count,
                      provenance: GenreCorrectionReportCopy.provenance, summary: summary)
    }

    // Words that name no genre. Short on purpose: the two filters that do the real work are the floor
    // above and the classifier's own vocabulary below, and a long list would start removing the very
    // words being looked for.
    // TRIMMED back to words that genuinely name nothing. The first version had grown several entries
    // ("signal", "thing", "off", "all") that existed only to make one fixture come out empty, and that
    // padding is what made the floor untestable: the fixture had no candidate words left for the floor
    // to reject. A stopword list shaped around a test rather than around the language is a list that
    // hides the rule it sits beside.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "of", "at", "in", "on", "for", "with", "to", "by", "from", "or",
        "evening", "night", "afternoon", "presents", "present", "featuring", "live", "new",
        "one", "two", "three", "four", "programme", "program", "gala", "bill", "double", "show",
    ]

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            // Two characters cannot be a useful signal and would match inside everything.
            .filter { $0.count > 2 && !stopwords.contains($0) }
            // A word the classifier ALREADY matches on is not a missing word. Telling Dan to add
            // something that is there, every time, is how a report stops being read.
            .filter { !EventClassifier.alreadyReads($0) }
    }
}
