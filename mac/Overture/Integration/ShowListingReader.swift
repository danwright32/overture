import Foundation

// #1824: read a show's own listing page, on the app side, and hand the text to the Prep run.
//
// The run cannot do this itself and the 2026-07-30 Alex Syiek run is the proof. Its instinct was already
// right with no prompt change at all: it fetched `sourceListingURL`, got an 11KB shell with no description
// in it, and asked for a browser render. `PREP_ALLOWED_TOOLS` (Read, Write, WebSearch, WebFetch, Bash,
// Skill under `--permission-mode manual`) denied it, and the draft was written without ever learning that
// the show was a cabaret concert of one songwriter's new songs. So this is a missing CAPABILITY, not only
// a missing instruction.
//
// Dan's call (2026-07-30) was to render it here rather than widen the detached run's tool scope: that
// scope exists because #1026 found a detached run auto-approving everything, and a run reading pages
// written by strangers is exactly where a browser tool costs the most. The app already renders pages of
// this class for the scout (`RenderedPage`, #806), so this reuses that and the run keeps its lockdown.
@MainActor
enum ShowListingReader {
    // How the page is loaded. Injected so every path here is a real unit test with no WebKit; production
    // is the same hidden browser the scout falls back to.
    // `@Sendable` because `readAll` renders a window of pages at once and each one crosses into its own
    // child task; without it the fan-out below cannot be expressed at all under Swift 6.
    typealias Render = @Sendable @MainActor (URL) async throws -> String

    // The most page text one queue item may carry. The detached run reads the queue with a line-oriented
    // Read tool, and one oversized line is the shape that left an 82KB page half-read forever (#1056); it
    // is also prompt the run pays for on every item.
    //
    // #2656: the calibration this number was given in 2026-07 is no longer true of the pages it described,
    // and the number is deliberately UNCHANGED anyway. It used to read: "The measured Green Room 42 page is
    // 1,994 characters of visible text in total, chrome included, so this holds a whole listing of that
    // class with room to spare." Measured again on 2026-08-13 across the 40 listings in the archived prep
    // runs, the same venue now runs to 3,836 characters, 96% of the budget, and every 54 Below listing ever
    // read (16 of 16) has hit the cap outright.
    //
    // Raising it was rejected as the same guess again with a bigger number. What was actually wrong is what
    // the budget was spent ON: 49% of the 54 Below page is its navigation menu, repeated four times.
    // `RepeatedBlockStripper` takes the repeats out before the cap applies, which returns the room without
    // asking anybody to guess how much a listing needs.
    static let textLimit = 4000

    // How many pages are rendered at once. Each render is a whole WebKit instance and mostly waiting, so a
    // strictly sequential read would make a twenty show launch take minutes of wall clock for no reason.
    // Kept small: this runs while Dan is watching a progress screen, not in the background.
    static let concurrency = 4

    // Read ONE show's listing.
    //
    // Returns nil when there is nothing to look at (no URL, or one that will not parse). That is
    // deliberately NOT `unreadable`: "there was no page" and "there was a page and we could not read it"
    // are different facts, and the run says a different sentence about each.
    // The production renderer, and the one place that refuses to reach the web from a test (L2). Every
    // existing startPrep test builds prospects that carry a listing URL and passes no renderer, so a bare
    // default would have quietly started loading real pages in a hidden browser the moment this shipped.
    // The seam alone is not enough: it has to be structurally impossible, which means a refusal inside the
    // thing being seamed, not a convention that every future test remembers.
    static let liveRender: Render = { url in
        guard !isUnderTest else { throw ShowListingReadError.refusedUnderTest }
        return try await RenderedPage.html(for: url)
    }

    enum ShowListingReadError: Error { case refusedUnderTest }

    private static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func read(listingURL: String?, render: Render = liveRender) async -> ShowListing? {
        guard let raw = listingURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme != nil, url.host != nil
        else { return nil }

        guard let html = try? await render(url) else {
            // Fail loud in the DATA, not by throwing: one dead page must not cost the run its other
            // listings, and it must never quietly become "this show published no description".
            return ShowListing(status: ShowListing.unreadable, url: raw)
        }

        // #2656: the repeated menu goes BEFORE the budget is spent, not after. Applied here rather than
        // inside `PageNormalizer.visibleText`, which the scout's extract stage also reads through: what the
        // scout sees is a separate question with its own corpus to measure against.
        let text = RepeatedBlockStripper.strip(PageNormalizer.visibleText(PageNormalizer.normalize(html)))
        guard !text.isEmpty else { return ShowListing(status: ShowListing.unreadable, url: raw) }

        if text.count > textLimit {
            return ShowListing(status: ShowListing.read, url: raw, text: cut(text), truncated: true)
        }
        return ShowListing(status: ShowListing.read, url: raw, text: text)
    }

    // Read every listing in a run, keyed by natural key, reporting progress as it goes.
    //
    // Progress is not decoration. This runs between Dan pressing Prep and the run launching, and CLAUDE.md's
    // standing rule is that a slow action must make working, still alive, and failed visibly different; a
    // bare spinner over a dozen renders is exactly the defect that rule names.
    static func readAll(for items: [PrepQueueItem],
                        render: @escaping Render = liveRender,
                        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> [String: ShowListing] {
        let total = items.count
        var done = 0
        var listings: [String: ShowListing] = [:]
        onProgress(done, total)

        // Bounded fan-out, a batch at a time. Batches rather than a sliding window because a window has to
        // be expressed as a task group with an actor-annotated child, which Swift 6's isolation checker
        // refuses to compile here; the batch loses a little wall clock on an uneven batch and costs nothing
        // in correctness. An item with no URL still advances the counter, or a run whose listings are mostly
        // missing would look stuck on a screen whose only evidence of life is that number moving.
        for start in stride(from: 0, to: total, by: concurrency) {
            let batch = items[start..<min(start + concurrency, total)]
            let running = batch.map { item in
                (item.naturalKey, Task { await read(listingURL: item.sourceListingURL, render: render) })
            }
            for (key, task) in running {
                if let listing = await task.value { listings[key] = listing }
                done += 1
                onProgress(done, total)
            }
        }
        return listings
    }

    // Cut at a word boundary where there is one nearby, so the run is not handed a half word it might read
    // as a name. The `truncated` flag, not this, is what tells it the page continued.
    private static func cut(_ text: String) -> String {
        let clipped = String(text.prefix(textLimit))
        guard let lastSpace = clipped.lastIndex(of: " "),
              clipped.distance(from: lastSpace, to: clipped.endIndex) < 40
        else { return clipped }
        return String(clipped[clipped.startIndex..<lastSpace])
    }
}
