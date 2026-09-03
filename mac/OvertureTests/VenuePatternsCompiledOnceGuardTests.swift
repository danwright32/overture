import Testing
import Foundation

// #3432: the venue-name cleaning patterns are compiled ONCE, not on every call.
//
// `String.replacingOccurrences(of:options:.regularExpression)` takes its pattern as a STRING, so the
// regex is parsed and compiled on every invocation. VenueNormalization ran four of those per venue name,
// on a path the queue exercises constantly.
//
// Measured 2026-09-02 with a standalone harness over twelve realistic venue strings, 20,000 calls each
// way: 9.7us per call through the string form against 6.3us through compiled `NSRegularExpression`
// statics, a 1.53x difference, with both forms producing identical output on every input.
//
// WHY A SOURCE GUARD RATHER THAN A TIMING ONE. What changed is only how fast identical work happens, so
// no behavioural test can go from red to green here: the equivalence is the whole point, and it is
// already covered, most sharply by `VenueKeyStabilityLiveStoreTests` asserting every stored venue key
// still reproduces under the current fold. A stopwatch assertion would measure what else this Mac is
// running (L224) and would be deleted the first time it flaked. So this asserts the SHAPE that makes it
// fast, which is the thing a later edit can silently undo.
@Suite("The venue-name and draft-lint patterns are compiled once (#3432)")
struct VenuePatternsCompiledOnceGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/Domain/VenueNormalization.swift") }
    // The draft lint got the same fix in the same change, and it is the bigger instance:
    // `DraftCheck.findings` was the single largest symbol in the typing profile at 143 samples, against
    // 76 for `VenueNormalization.fold` and 51 for `strippingParentheticals`. Guarded here rather than in
    // its own file because it is one rule about one shape, and splitting it would leave two guards that
    // can drift about what the rule is.
    private var draftCheck: String { SourceGuardHelper.source("Overture/Domain/DraftCheck.swift") }

    @Test func noPatternIsCompiledPerCall() {
        #expect(!source.isEmpty, "VenueNormalization.swift could not be read, so this measured nothing")
        #expect(!source.contains("options: .regularExpression"),
                Comment(rawValue: "VenueNormalization compiles a regex from a string on every call. "
                        + "Hoist it into a compiled NSRegularExpression static beside the others."))
    }

    // One definition per pattern, which is the other half of #3432: four call sites each carrying their
    // own copy of a pattern is four places the normalisation rule can drift apart (L370).
    @Test func eachPatternIsWrittenExactlyOnce() {
        #expect(!source.isEmpty)
        for pattern in [#"\s*\([^)]*\)"#, #"\s*/\s*"#, #"\s*,\s*"#, #"\s+"#] {
            let occurrences = source.components(separatedBy: pattern).count - 1
            #expect(occurrences == 1,
                    Comment(rawValue: "the pattern \(pattern) appears \(occurrences) time(s) in "
                            + "VenueNormalization.swift. Exactly one definition, so the rule cannot "
                            + "drift between call sites."))
        }
    }

    // The compiled statics really are static. Built inside a function they would be constructed per call
    // and the change would buy nothing while reading as done.
    // The draft lint compiles nothing per call either, by EITHER route. The string form
    // (`options: .regularExpression`) and a bare `try? NSRegularExpression` in a function body are the
    // same defect wearing different spellings, and checking only the first would have missed three sites
    // in this file, including two on per-sentence paths (L247).
    @Test func theDraftLintCompilesNothingPerCall() {
        #expect(!draftCheck.isEmpty, "DraftCheck.swift could not be read, so this measured nothing")
        #expect(!draftCheck.contains("options: .regularExpression"),
                "DraftCheck compiles a regex from a string on every call")

        guard let store = SourceGuardHelper.propertyBody("private enum Patterns {", in: draftCheck) else {
            Issue.record("expected DraftCheck to hold its compiled patterns in a Patterns enum")
            return
        }
        let everywhere = draftCheck.components(separatedBy: "try? NSRegularExpression").count - 1
        let inTheStore = store.components(separatedBy: "try? NSRegularExpression").count - 1
        #expect(everywhere > 0, "no compiled pattern found at all, so this measured nothing")
        #expect(everywhere == inTheStore,
                Comment(rawValue: "\(everywhere - inTheStore) NSRegularExpression(s) are built outside "
                        + "the Patterns store, so they are compiled on every call."))
    }

    // It asks for `CompiledPattern` rather than `NSRegularExpression`, which is what this said first and
    // why it went red: the shared type arrived after the guard was written, and by then neither file
    // names the regex type at all. A guard describing an implementation the code does not have is a
    // second definition of the rule, free to drift from the first.
    @Test func theCompiledPatternsAreStoredStatics() {
        #expect(!source.isEmpty)
        #expect(!draftCheck.isEmpty)
        for file in [source, draftCheck] {
            #expect(file.contains("static let"), "the compiled patterns are held as statics")
            #expect(file.contains("CompiledPattern("),
                    "the patterns are compiled once through the shared CompiledPattern, not per call")
        }
    }
}
