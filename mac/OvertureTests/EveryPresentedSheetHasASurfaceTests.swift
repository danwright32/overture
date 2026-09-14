import Testing
import Foundation

// #3859: every sheet Dan can have on screen has a `StallSurface` case, so a stall while one is up is not
// recorded as a queue stall.
//
// Seven of the twelve sheet flags `RootView` declares fell through to `.queue`. That was a deliberate
// decision, recorded on `presentedSurface`'s own header, and it was defensible while the field was read
// one record at a time: an unknown sheet left the answer as whatever was underneath it, which is a true
// statement about a real surface. It stopped being defensible when milestone #80 began reading the
// DISTRIBUTION of the field. Measured 2026-09-12, that reading split 1,562 `queue` against 97
// `followUps`, and under the old rule the 1,562 was the queue OR any of seven unnamed sheets over it:
// two populations in one number, with nothing able to say which (L216, L542).
//
// THE FLAG LIST IS DERIVED FROM THE SOURCE, never written down here. A hand-kept list only ever checks
// what somebody remembered, and the thing being checked is whether somebody remembered (L96).
@Suite("Every sheet on screen has a surface of its own (#3859)")
struct EveryPresentedSheetHasASurfaceTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // Every `@State private var show<Name> = false` this view declares, which is how a sheet flag is
    // written here, and how #3859 enumerated them in the first place.
    private static func sheetFlags(in source: String) -> [String] {
        SwiftSource.scannableLines(in: source, skipping: []).compactMap { line in
            let code = line.code.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("@State private var show"), code.contains("= false") else { return nil }
            guard let varRange = code.range(of: "var ") else { return nil }
            let name = code[varRange.upperBound...].prefix { $0.isLetter || $0.isNumber }
            return name.isEmpty ? nil : String(name)
        }
    }

    private static func presentedSurfaceBody(in source: String) -> String? {
        SourceGuardHelper.propertyBody("private var presentedSurface: StallSurface {", in: source)
    }

    @Test func everySheetFlagIsNamedByPresentedSurface() throws {
        #expect(!rootView.isEmpty, "RootView.swift could not be read, so this measured nothing")
        let flags = Self.sheetFlags(in: rootView)
        // The positive control: a derivation that found nothing would pass every claim below while
        // checking none of them (L98).
        #expect(flags.count >= 10, Comment(rawValue:
            "the derivation found \(flags.count) sheet flags in RootView, fewer than the twelve measured "
            + "on 2026-09-12, so it has stopped being able to see them rather than the app having lost any"))

        let body = try #require(Self.presentedSurfaceBody(in: rootView),
                                "presentedSurface could not be found, so this measured nothing")
        let unnamed = flags.filter { !body.contains($0) }
        #expect(unnamed.isEmpty, Comment(rawValue:
            "\(unnamed.sorted().joined(separator: ", ")) can be on screen and presentedSurface does not "
            + "name any of them, so a stall while one is up is recorded as a stall on whatever is "
            + "underneath it. Milestone #80 reads this field's distribution, and a surface that stands in "
            + "for seven others is two populations in one number (#3859)"))
    }

    // And each one resolves to a DIFFERENT case, because naming them all and mapping several onto one
    // case would reproduce the mixed population the fix exists to end (L11).
    @Test func noTwoSheetsShareASurfaceCase() throws {
        let body = try #require(Self.presentedSurfaceBody(in: rootView))
        let returned = body.components(separatedBy: "return .")
            .dropFirst()
            .map { $0.prefix { $0.isLetter || $0.isNumber } }
            .map(String.init)
        #expect(returned.count >= 10, Comment(rawValue:
            "presentedSurface returns \(returned.count) cases, which is too few to be naming every sheet"))
        #expect(returned.count == Set(returned).count, Comment(rawValue:
            "presentedSurface returns the same case for more than one sheet: \(returned.sorted())"))
    }

    // The record says which vocabulary it was written under, which is what keeps the records already on
    // Dan's Mac readable rather than silently redefined (L683).
    @Test func aFreshRecordStampsTheVocabularyItWasWrittenUnder() {
        let record = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 0),
                                 seconds: 1, surface: .queue, load: .baseline, loadAverage: nil,
                                 passes: nil)
        #expect(record.surfaceVocabulary == StallSurface.allCases.count)
        #expect(record.surfaceVocabulary ?? 0 > 6,
                "the vocabulary this build writes must be larger than the six surfaces #3859 found")
    }

    // A record from before this shipped carries NOTHING there, and nothing is not a number: it is what
    // says its `queue` is the mixed population.
    @Test func anOlderRecordDecodesWithNoVocabularyAtAll() throws {
        let json = """
            {"session":"s","sequence":1,"at":"2026-09-01T00:00:00Z","seconds":1.5,\
            "surface":"queue","load":"baseline"}
            """
        let decoder = FreezeLog.decoder()
        let record = try decoder.decode(StallRecord.self, from: Data(json.utf8))
        #expect(record.surfaceVocabulary == nil)
        #expect(record.surface == .queue)
    }

    // A surface spelling this build does not know reads as `notRecorded` rather than failing the whole
    // record. The same rule the windows field already carried, applied to its siblings (L30).
    @Test func anUnknownSurfaceOrLoadDoesNotDestroyTheRecord() throws {
        let json = """
            {"session":"s","sequence":2,"at":"2026-09-01T00:00:00Z","seconds":2.5,\
            "surface":"somethingLater","load":"somethingElse","surfaceVocabulary":99}
            """
        let decoder = FreezeLog.decoder()
        let record = try decoder.decode(StallRecord.self, from: Data(json.utf8))
        #expect(record.surface == .notRecorded)
        #expect(record.load == .unmeasured)
        #expect(record.seconds == 2.5, "the rest of the record survived a field this build cannot read")
        #expect(record.surfaceVocabulary == 99, "and it says which vocabulary wrote it")
    }
}
