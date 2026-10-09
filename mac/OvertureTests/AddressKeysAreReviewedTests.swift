import Testing
import Foundation

// #4612: every key the app takes from an object's ADDRESS is a recorded decision, file by file.
//
// An `ObjectIdentifier` names an address, and an address names an object only while that object lives
// (L1019). A key taken from one is sound exactly where something holds the object for as long as the key is
// compared: the map keeps the row beside the key, the set is local to a function whose rows are all held, or
// the identity is checked again on the way out. Where nothing does, a freed object's address can be handed to a
// new one and the key answers for the wrong object with no error. #4609 found that in `StoreSaveCount` (a fresh
// store inherited a dead one's foreign save flag) and #4612 in `ScopeFingerprint` (a memo kept the hash and not
// the rows it hashed).
//
// So the app's uses are DERIVED from its source (L96), counted per file on lines of code, and each file's count
// is held to the one recorded below with the reason it is sound. A new use, or one moved into a new file, fails
// here until somebody writes down what keeps its objects alive, which is the question the two defects above
// never had asked of them. A use REMOVED fails too, so the count can never carry headroom for an unreviewed one.
//
// Prefer, in order: the object's `persistentModelID` where the rows are saved (an unsaved row's identifier
// describes itself as every other unsaved one's does, `InquiryIdentity.rowID`), the object held beside the key
// and checked with `===` (`StoreSaveCount`), or the rows held for as long as the key is (`ScopeMemo`).
@Suite("Every key taken from an object's address says what keeps the object alive (#4612)")
struct AddressKeysAreReviewedTests {

    /// File name to the number of code lines naming `ObjectIdentifier`, and why those keys are sound.
    static let reviewed: [String: (lines: Int, reason: String)] = [
        "ScopeMemo.swift": (1, """
            `ScopeFingerprint` hashes row addresses. The memo holds the rows its key was taken over \
            (`keyRows`) until the next build, so no other object can be made at one of their addresses while \
            that key is compared (#4612).
            """),
        "ScopeObservation.swift": (4, """
            The `seen` set of one `armAll` walk, local to that call. Every row it names is reached from rows \
            the caller holds for the whole walk.
            """),
        "StoreSaveCount.swift": (5, """
            Each record holds its store weakly and a lookup checks `found.store === store`, so a container \
            made at a dead one's address never inherits its record (#4609).
            """),
        "QueueEngine.swift": (4, """
            The engine's save observer compares a saved context's container and the context itself against \
            the container and context the engine holds for its whole life, so neither address can be reused \
            while the observer runs.
            """),
        "QueueSendAwareViews.swift": (4, """
            `ReachedOutRowInputs` compares a show and a contact by address, and the row's content closure \
            holds both objects for as long as the inputs are compared.
            """),
        "IngestedAtStamp.swift": (14, """
            Every identifier keys `entries`, whose `Entry` holds the row itself; the bucket sets are kept in \
            step with `entries` and every read of one goes back through `entries`, so a key never outlives \
            the row it names.
            """),
        "ScoutLandingStore.swift": (42, """
            The landing's working set holds every row it keys in `loaded` (or the map holds the row beside \
            the key: `rank`, `keysToCheck`, `tableRows`, `unstamped`) for the landing's life, and \
            `discarded` removes a row from every map in the same call that drops it from `loaded`.
            """),
        "LandingBatchTables.swift": (1, """
            Its rows are keyed for `ScoutLandingStore`, which holds each one in `tableRows` beside the tables \
            and removes it from both together.
            """),
        "ScoutExtractIngest.swift": (5, """
            `landedEarlier` is local to one ingest, over sources the ingest holds for the whole call.
            """),
        "ScoutService.swift": (3, """
            `setAside` is local to one sweep, over sources the sweep holds for the whole call.
            """),
        "DriftedRunMerge.swift": (3, """
            `tokensByRow` is local to one merge, over rows the merge holds for the whole call.
            """),
        "InquiryIdentity.swift": (1, """
            An unsaved inquiry's row id is its address, and a press resolving it is refused unless the \
            inquiry found also carries the `createdAt` the row was drawn with, so a newer inquiry made at a \
            freed one's address is refused as not the one drawn.
            """),
    ]

    /// What the source says: file name to the number of code lines naming `ObjectIdentifier`.
    static func derived() -> [String: Int] {
        var found: [String: Int] = [:]
        for file in AppSourceWalk.appFiles() {
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [])
            let count = lines.filter { $0.code.contains("ObjectIdentifier") }.count
            if count > 0 { found[file.name, default: 0] += count }
        }
        return found
    }

    @Test func everyAddressKeyIsInAReviewedFileAtItsRecordedCount() {
        let found = Self.derived()
        // A walk that found nothing would pass every comparison below on an empty dictionary (L98).
        #expect(found.count >= 5, Comment(rawValue:
            "the scan found ObjectIdentifier in \(found.count) app files, which is a broken scan, not a clean app"))
        for (file, count) in found.sorted(by: { $0.key < $1.key }) {
            guard let recorded = Self.reviewed[file] else {
                Issue.record(Comment(rawValue: "\(file) names ObjectIdentifier on \(count) line(s) and is not "
                    + "in AddressKeysAreReviewedTests.reviewed. An address names an object only while it lives, "
                    + "so key on persistentModelID, or hold the object beside the key, and record here what "
                    + "keeps it alive (#4612, L1019)"))
                continue
            }
            #expect(count == recorded.lines, Comment(rawValue: "\(file) names ObjectIdentifier on \(count) "
                + "line(s) and \(recorded.lines) are recorded. Check the new or removed use against the reason "
                + "recorded for this file, then update the count (#4612)"))
        }
        for file in Self.reviewed.keys.sorted() where found[file] == nil {
            Issue.record(Comment(rawValue: "\(file) is recorded as naming ObjectIdentifier and no longer does, "
                + "so its entry in AddressKeysAreReviewedTests.reviewed reviews nothing; delete it"))
        }
    }

    // Every reason begins with a word, so an entry cannot be waved through with an empty string (L675).
    @Test func everyRecordedFileSaysWhy() {
        for (file, entry) in Self.reviewed {
            #expect(entry.reason.first?.isLetter == true || entry.reason.first == "`",
                    Comment(rawValue: "\(file)'s reason does not begin with a word"))
        }
    }
}
