import Testing
import Foundation

// #1613/#2105: Foundation caches resource values on a URL VALUE, so a URL asked once keeps answering with
// the reading it got then, for the life of that value, even after the file is deleted.
//
// Every test below passes the SAME URL twice, which is the only shape that can catch this. One that
// rebuilds the URL between reads passes whether the bug is there or not, which is exactly why five of the
// six readers in this app were "fine" for months: each happened to build its URL from a computed property
// on every call, and that is luck rather than a design.
@Suite("Reading when a file was last written (#2105)")
struct FileTimestampTests {

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-2105-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        return url
    }

    // The defect itself, in the direction that matters: the file is GONE and the same URL must say so.
    // This is what turned "the marker is gone" into "the marker is still there and stale", a dead run
    // reporting itself over and over.
    @Test func aDeletedFileReadsAsGoneThroughTheSameURL() throws {
        let url = try tempFile()
        #expect(FileTimestamp.modifiedAt(url) != nil, "it exists to start with")

        try FileManager.default.removeItem(at: url)

        #expect(FileTimestamp.modifiedAt(url) == nil,
                "the same URL value still reported the old date, which is the whole defect")
    }

    // And the other direction: a file REPLACED after the first read must report the new time, or an
    // export that has changed reads as unchanged and the reconcile it gates silently does not run.
    @Test func aRewrittenFileReportsItsNewTimeThroughTheSameURL() throws {
        let url = try tempFile()
        let first = try #require(FileTimestamp.modifiedAt(url))

        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let second = try #require(FileTimestamp.modifiedAt(url))
        #expect(second > first, "the same URL value reported the reading it took the first time")
    }

    // A file that never existed has no date, rather than throwing.
    @Test func aMissingFileHasNoDate() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-2105-never-\(UUID().uuidString)")
        #expect(FileTimestamp.modifiedAt(url) == nil)
    }

    // The caller's own URL is untouched. The helper takes it by value and clears the cache on its copy,
    // so passing a URL somebody else is holding cannot quietly change what THEY see next.
    @Test func theCallersOwnURLIsNotMutated() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = url

        _ = FileTimestamp.modifiedAt(url)

        #expect(url == before)
    }
}

// The audit itself (#2105). Five readers were never checked, and each decides something: whether a run
// produced results, whether the export changed, whether the export is healthy. They are one implementation
// now, so a reader added later gets the right answer without knowing this defect exists (L30).
@Suite("Every file-timestamp read goes through the shared one (#2105)")
struct FileTimestampAuditTests {

    @Test func nothingReadsTheModificationDateItself() {
        let offenders = AppSourceWalk.appFiles()
            .filter { $0.name != "FileTimestamp.swift" }
            .filter { $0.text.contains("contentModificationDateKey") }
            .map(\.name)
            .sorted()

        #expect(offenders.isEmpty, """
            These read a file's modification date directly, so they get Foundation's per-URL cache and \
            can report a date for a file that has been deleted or replaced. Use \
            FileTimestamp.modifiedAt: \(offenders.joined(separator: ", "))
            """)
    }

    // The audit is worth nothing if the walk found nothing to audit, which is how #1967 failed silently.
    @Test func theSharedReadIsActuallyUsed() {
        let users = AppSourceWalk.appFiles()
            .filter { $0.text.contains("FileTimestamp.modifiedAt(") }
            .map(\.name)
            .sorted()

        #expect(users.count >= 4, "found \(users.count) callers, which is fewer than the audit named")
        #expect(users.contains("DownbeatExport.swift"),
                "the one site genuinely exposed rather than safe by luck, since its URL is a parameter")
    }
}
