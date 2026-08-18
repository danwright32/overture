import Testing
import Foundation

// Built is not wired (L3). The rule in `AnsweredReplyNoteTests` is a sentence the app never says unless
// the surfaces that draw an OPEN PITCH actually ask for it.
//
// Its own file rather than a second suite beside the rule, for the reason #2816 recorded: #629's
// meta-guard sweeps a test file's array literals for the function names a `named:` loop stands for, and a
// suite whose assertions compare against fixture strings reads as a list of function names to it.
//
// The helper below takes its function name under the label `named:` deliberately, because that is the
// shape #629's meta-guard can read. Written first as `ofFunction:`, it failed with "this guard found no
// referenced function name in it", which is the meta-guard working: it must be able to tell, in one
// place, when a function this file names has moved to another file.
@Suite("The surfaces that work an open pitch actually say a reply was answered (#2919)")
struct AnsweredReplyNoteWiringTests {

    private func leadingColumn(named name: String, in path: String, opening: String) throws -> String {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty)
        let body = try String(SourceGuard.functionBody(named: name, in: source))
        return try #require(SourceGuardHelper.between(opening, and: "Spacer(minLength: OVSpacing.sm)",
                                                      in: body),
                            "\(name)'s leading column was not found where the guard expects it")
    }

    // The reached-out row: the surface the issue was filed from.
    @Test func theReachedOutRowDrawsTheAnsweredLine() throws {
        let leading = try leadingColumn(named: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                       opening: "VStack(alignment: .leading, spacing: 3) {")
        #expect(leading.contains("AnsweredReplyNote.line("),
                "the reached-out row no longer says that a reply arrived and was answered (#2919)")
    }

    // The class, not the instance. Follow-ups' post-event row asks how the show ended and offers the
    // endings, which is the surface where a conversation nobody mentioned costs the most.
    @Test func theFollowUpsPostEventRowDrawsTheAnsweredLine() throws {
        let leading = try leadingColumn(named: "postEventRow", in: "Overture/UI/FollowUpsView.swift",
                                       opening: "VStack(alignment: .leading, spacing: 3) {")
        #expect(leading.contains("AnsweredReplyNote.line("),
                "the post-event row asks how a show ended with no sign a conversation happened (#2919)")
    }

    // It sits with the CONVERSATION, under the people it is about, and never among the show's own facts
    // (the group name, the show's date and the source listing, which #2816 grouped together deliberately).
    @Test func theLineSitsWithTheConversationRatherThanWithTheShow() throws {
        let leading = try leadingColumn(named: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                       opening: "VStack(alignment: .leading, spacing: 3) {")
        let link = try #require(leading.range(of: "RowSourceLink("))
        let audience = try #require(leading.range(of: "ReplyIdentity.rowAudience"))
        let answered = try #require(leading.range(of: "AnsweredReplyNote.line("))
        #expect(link.lowerBound < answered.lowerBound,
                "the answered line splits the show's own facts, which belong together (#2816)")
        #expect(audience.lowerBound < answered.lowerBound,
                "the answered line draws above the people it is about")
    }

    // The predicate is shared, not re-derived (#2921's rule). Two definitions of "has this been dealt
    // with" is how a row asserts somebody is waiting hours after Dan wrote back.
    @Test func theAnsweredPredicateIsWrittenOverTheUnhandledOne() throws {
        let source = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        let body = try #require(SourceGuardHelper.propertyBody("var replyIsAnswered: Bool {", in: source),
                                "replyIsAnswered was not found on Recipient")
        #expect(body.contains("hasUnhandledReply"),
                "replyIsAnswered no longer shares hasUnhandledReply, so the two can now disagree (#2921)")
    }
}
