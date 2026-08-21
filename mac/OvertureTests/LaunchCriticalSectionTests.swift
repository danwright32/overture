import Testing
import Foundation

// #3011, phase 2 of the revised #2765 plan. Reading what the OTHER run holds, deciding what this run may
// take, claiming this slot's marker and publishing this run's coverage must be ONE indivisible step.
// Without that, two launches a second apart each read before the other wrote and both take the same show
// (assume it runs twice).
//
// THE PLAN'S FIRST ANSWER WAS A LOCK FILE, AND IT WAS WRONG. `run-launch-lock`, created
// `.withoutOverwriting` and released on every exit path, was rejected by an independent red-team for a
// decisive reason: `PrepQueueService` is `@MainActor`, both launch functions are MainActor-isolated, and
// only the app process ever launches a run. There is no cross-process contention to solve, so a file
// sentinel would import a persistent-state failure mode into a problem that has none. A crash between
// taking it and releasing it leaves a zero-byte file with no owner, no staleness rule and no sweep, and
// BOTH launches are then refused for ever, with no way for Dan to clear it from inside the app.
// `clearDeadRun`'s own header records the last time exactly that happened: "It cleared only when the
// files were deleted by hand in Application Support, which Dan has no way to do from inside the app."
//
// So the critical section is not built, it is PROVED. Swift already guarantees it: main-actor isolated
// code cannot be interleaved with other main-actor code except at a suspension point. A span containing
// no `await` is therefore atomic against the other launch by construction, and costs nothing, leaks
// nothing on a crash, and needs no recovery path.
//
// That is a property of the SOURCE, and it is quiet: a future `await` added anywhere inside the span
// silently reopens the race, with nothing failing and nothing on screen. Hence this guard. It is the only
// thing standing between the two launches and the check-then-act window #480 exists to close.
@Suite("Each launch decides and claims without suspending (#3011)")
struct LaunchCriticalSectionTests {

    private static var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OvertureTests
            .deletingLastPathComponent()      // mac
            .appendingPathComponent("Overture/Integration/PrepQueueService.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // The span from the exclusion check to the moment this run's coverage is on disk, comments and string
    // bodies stripped so prose ABOUT `await` cannot satisfy or trip the rule (L103).
    private static func criticalSection(opening: String, closing: String) -> [(line: Int, code: String)] {
        let lines = SwiftSource.scannableLines(in: source)
        guard let start = lines.firstIndex(where: { $0.code.contains(opening) }) else { return [] }
        guard let end = lines[start...].firstIndex(where: { $0.code.contains(closing) }) else { return [] }
        return Array(lines[start...end])
    }

    private static let launches = [
        (name: "the reachability check",
         opening: "runInFlightRefusal(slot: .check, now: now, support: support",
         closing: "RunCoverage.write(keys: coveredKeys, slot: .check"),
        (name: "the Prep run",
         opening: "runInFlightRefusal(slot: .prep, now: now, support: support",
         closing: "RunCoverage.write(keys: Set(queue.items.map(\\.naturalKey)), slot: .prep"),
    ]

    @Test func neitherLaunchSuspendsBetweenDecidingAndClaiming() {
        for launch in Self.launches {
            let span = Self.criticalSection(opening: launch.opening, closing: launch.closing)

            // The scope really selected something. A range that matches nothing passes every assertion
            // beneath it for the wrong reason, and the commonest way this guard would rot is one of the
            // two anchors being reworded (L98, L100).
            #expect(!span.isEmpty,
                    "could not find \(launch.name)'s critical section, so this checked NOTHING: an anchor has moved")
            #expect(span.count > 3,
                    "\(launch.name)'s critical section collapsed to \(span.count) line(s), which is not a span")

            let suspensions = span.filter { $0.code.range(of: #"\bawait\b"#, options: .regularExpression) != nil }
            #expect(suspensions.isEmpty,
                    """
                    \(launch.name) suspends between checking the exclusion and publishing what it holds, at \
                    \(suspensions.map { "line \($0.line): \($0.code.trimmingCharacters(in: .whitespaces))" }
                        .joined(separator: "; ")). \
                    The other launch can run at that point, so both can read before either writes and both \
                    take the same show. Move the awaited work after the coverage is published.
                    """)
        }
    }

    // The POSITIVE CONTROL for the rule itself, in the same file (L159). The guard above asserts an
    // ABSENCE, which any broken extraction satisfies. This proves the same scan really does find an
    // `await` when one is there: both launches contain the slow listing read, deliberately placed AFTER
    // the coverage is published, and it must still be inside the function.
    @Test func theSameScanDoesFindTheAwaitThatComesAfterwards() {
        let lines = SwiftSource.scannableLines(in: Self.source)
        let listingReads = lines.filter {
            $0.code.contains("await ShowListingReader.readAll")
        }
        #expect(listingReads.count == 2,
                "expected both launches to await the listing read outside their critical section; found \(listingReads.count)")
    }

    // The ordering the section depends on: the exclusion is checked, THEN the marker is claimed, THEN the
    // coverage is published. A coverage write before the marker would publish a hold for a run that may
    // lose the marker race a line later.
    @Test func eachLaunchChecksThenClaimsThenPublishes() {
        let lines = SwiftSource.scannableLines(in: Self.source)
        func firstLine(after index: Int, containing needle: String) -> Int? {
            lines[index...].first { $0.code.contains(needle) }?.line
        }
        for launch in Self.launches {
            guard let startIdx = lines.firstIndex(where: { $0.code.contains(launch.opening) }) else {
                Issue.record("could not find \(launch.name)'s exclusion check, so this checked nothing")
                continue
            }
            let refusal = lines[startIdx].line
            let claim = firstLine(after: startIdx, containing: ".withoutOverwriting")
            let publish = firstLine(after: startIdx, containing: launch.closing)
            #expect(claim != nil && publish != nil,
                    "could not find \(launch.name)'s marker claim or coverage publish")
            if let claim, let publish {
                #expect(refusal < claim, "\(launch.name) claims its marker before checking the exclusion")
                #expect(claim < publish, "\(launch.name) publishes what it holds before claiming its marker")
            }
        }
    }
}
