import Foundation
import SwiftData

// A discovered, ranked performance Dan reviews. Persisted locally (SwiftData,
// cloud sync off, like Downbeat). Identity is a content-derived natural key
// (group + date + venue) so re-ingesting a fresh results file updates the ranking
// in place and PRESERVES Dan's keep/dismiss decision rather than duplicating rows.

@Model
final class Prospect {
    @Attribute(.unique) var naturalKey: String

    var groupName: String
    var discipline: String
    var venue: String?
    var performanceDate: String?
    var sourceListingURL: String?
    var websiteURL: String?

    var priorRelationship: String
    var production: String
    var profile: String
    var coverage: String

    var fitScore: Int
    var tier: String
    var fitReason: String

    var matchedClientName: String?
    var possibleMatchSource: String?
    var possibleMatchName: String?

    var statusRaw: String
    var dismissReasonRaw: String?
    var ingestedAt: Date

    // Filled by the Prep run (Trigger 2). Defaulted so the scout's inserts are unaffected.
    var contactName: String? = nil
    var contactRole: String? = nil
    var contactEmail: String? = nil
    var contactMethodRaw: String? = nil
    var contactConfidenceRaw: String? = nil
    var contactFormURL: String? = nil

    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftVariant: String? = nil
    var draftEditedByDan: Bool = false

    // Outcome of the outreach. Defaults to no-response (like Dan's sheet), so most
    // prospects need no touch. Set manually by Dan, or automatically later from
    // Gmail (replied) / Downbeat (booked). Only meaningful once sent.
    var outcomeRaw: String = Outcome.noResponse.rawValue
    var outcomeSourceRaw: String? = nil
    var outcomeAt: Date? = nil
    var sentAt: Date? = nil

    init(
        naturalKey: String,
        groupName: String,
        discipline: String,
        venue: String?,
        performanceDate: String?,
        sourceListingURL: String?,
        websiteURL: String?,
        priorRelationship: String,
        production: String,
        profile: String,
        coverage: String,
        fitScore: Int,
        tier: String,
        fitReason: String,
        matchedClientName: String?,
        possibleMatchSource: String?,
        possibleMatchName: String?,
        status: ReviewStatus = .new,
        dismissReason: DismissReason? = nil,
        ingestedAt: Date = Date()
    ) {
        self.naturalKey = naturalKey
        self.groupName = groupName
        self.discipline = discipline
        self.venue = venue
        self.performanceDate = performanceDate
        self.sourceListingURL = sourceListingURL
        self.websiteURL = websiteURL
        self.priorRelationship = priorRelationship
        self.production = production
        self.profile = profile
        self.coverage = coverage
        self.fitScore = fitScore
        self.tier = tier
        self.fitReason = fitReason
        self.matchedClientName = matchedClientName
        self.possibleMatchSource = possibleMatchSource
        self.possibleMatchName = possibleMatchName
        self.statusRaw = status.rawValue
        self.dismissReasonRaw = dismissReason?.rawValue
        self.ingestedAt = ingestedAt
    }

    var status: ReviewStatus {
        get { ReviewStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }

    var contactMethod: ContactMethod? {
        get { contactMethodRaw.flatMap(ContactMethod.init) }
        set { contactMethodRaw = newValue?.rawValue }
    }

    var contactConfidence: ContactConfidence? {
        get { contactConfidenceRaw.flatMap(ContactConfidence.init) }
        set { contactConfidenceRaw = newValue?.rawValue }
    }

    var hasDraft: Bool { draftBody != nil }

    var outcome: Outcome {
        get { Outcome(rawValue: outcomeRaw) ?? .noResponse }
        set { outcomeRaw = newValue.rawValue }
    }

    // True once the email was actually sent (approved-and-sent). Outcomes only count
    // for these in the stats.
    var wasContacted: Bool { sentAt != nil || status == .approved }

    // The content key two results files agree on for "the same performance".
    static func makeNaturalKey(groupName: String, performanceDate: String?, venue: String?) -> String {
        let parts = [groupName, performanceDate ?? "", venue ?? ""]
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }
}
