import Testing
import SwiftUI
import AppKit
@testable import Overture

// #4108: nothing of the window behind can show through while a branded confirm is up.
//
// WHAT WAS MEASURED. On 2026-09-21 Dan dismissed a whole night and screenshotted the
// "Dismiss all 7 shows on Oct 4?" sheet sitting over a window that had not finished redrawing: card
// text and oversized heading text from the queue behind, drawn on top of each other, all round the
// sheet. The freeze log recorded 1.38s and 1.88s stalls beside it, both with `passes=0`, so the app
// went quiet without completing a render pass and the half composed frame stayed on screen.
//
// WHAT THIS TEST ASSERTS, and why it is a pixel count rather than a check that a modifier is present.
// "There is a cover" and "nothing shows through it" are different claims, and only the second is the
// requirement (L63). A guard asserting the host says `.overlay { ConfirmBackdrop() }` would pass over
// a backdrop that was transparent, or clipped, or behind the content. So this renders the composition
// and counts pixels of a colour that exists ONLY in the content behind.
//
// THE CONTENT IS A COLOUR NOTHING ELSE USES, deliberately. Measuring "is the surface uniform" would be
// answered by any uniform surface including an all black failure, and measuring total ink would be
// answered by the backdrop's own paint (L141, L146). A single unmistakable colour turns the question
// into "how many pixels of the thing that must be hidden survived", whose right answer is zero and
// whose wrong answer is a number.
@MainActor
@Suite("The confirm backdrop hides the window behind it (#4108)")
struct ConfirmBackdropRendersTests {

    // A colour that appears nowhere in the app's palette, so any pixel of it in the output came from
    // the content this backdrop is supposed to be hiding.
    private static let loud = Color(red: 1, green: 0, blue: 1)

    // Where to put a PNG of what this rendered, when somebody asks. Opt in through the environment on
    // `PrepPickerRendersTests`'s precedent: the assertions below are the test, and the picture is for a
    // person to look at, so a run that nobody asked for writes nothing.
    nonisolated private static var shotsDirectory: String? {
        guard let dir = ProcessInfo.processInfo.environment["OVERTURE_BACKDROP_SHOTS"], !dir.isEmpty
        else { return nil }
        return dir
    }

    private func write(_ rep: NSBitmapImageRep, name: String) {
        guard let dir = Self.shotsDirectory,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func render(_ view: some View, dark: Bool) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(width: 300, height: 200).environment(\.colorScheme, dark ? .dark : .light)))
        hosting.appearance = window.appearance
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.setContentSize(hosting.frame.size)
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Waits on the layout having settled rather than on a fixed duration where it can: the render
        // is synchronous once the subtree has laid out, and the short run loop turn below is the one
        // thing AppKit gives no condition for.
        let settleBy = Date().addingTimeInterval(0.2)
        while Date() < settleBy { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    // How many pixels of two renders differ. This is the measurement, and it replaces a colour guess
    // that was SEEN TO SURVIVE its own mutation.
    //
    // The first version counted pixels of the loud colour, with a predicate of "red high, green low,
    // blue high". Mutating the backdrop to `OVColor.canvas.opacity(0.6)`, which is exactly the dimmed
    // scrim this issue rules out, left the suite GREEN: a 60% canvas over magenta composites to about
    // (0.43, 0.06, 0.43), which is unmistakably magenta contamination to a person and fails a
    // "red > 0.6" test. A filter identifying what it must catch by a shape somebody guessed at will
    // miss the neighbouring case, and the pass reads exactly like the real thing (L104, L1).
    //
    // So nothing is guessed now. The claim is that the covered render is INDISTINGUISHABLE from the
    // backdrop drawn over nothing at all, which is what opaque means and is true at no other opacity.
    // It needs no colour constant, so it cannot drift from the token, and it fails at 0.99 as surely as
    // at 0.6.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                // A tolerance of one part in 255, so colour management rounding is not a difference
                // while any real blend is.
                let apart = abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent)
                if apart > 0.004 { differing += 1 }
            }
        }
        return differing
    }

    @ViewBuilder private func content() -> some View {
        ZStack {
            Self.loud
            Text("SEVEN SHOWS").font(.largeTitle).foregroundStyle(.white)
        }
    }

    // THE POSITIVE CONTROL, and it comes first. A test asserting two renders are IDENTICAL is satisfied
    // by a fixture where they could never have differed, so the same comparison without the backdrop
    // has to be shown to produce a difference (L159).
    @Test func theContentBehindReallyDoesShowWhenNothingCoversIt() throws {
        let bare = try #require(render(ConfirmBackdrop(), dark: true))
        let uncovered = try #require(render(content(), dark: true))
        write(uncovered, name: "backdrop-absent-dark")
        let differing = differingPixels(bare, uncovered)
        #expect(differing > 0, Comment(rawValue:
            "the uncovered content rendered identically to the bare backdrop, so this fixture could "
            + "never show the backdrop hiding anything and the assertion below would pass over a "
            + "cover that does nothing"))
    }

    @Test func nothingOfTheWindowBehindSurvivesTheBackdrop() throws {
        let bare = try #require(render(ConfirmBackdrop(), dark: true))
        let covered = try #require(render(content().overlay { ConfirmBackdrop() }, dark: true))
        write(covered, name: "backdrop-present-dark")
        let differing = differingPixels(bare, covered)
        #expect(differing == 0, Comment(rawValue:
            "\(differing) pixel(s) of the covered window differ from the backdrop drawn over nothing, "
            + "so the content behind is showing through and a window that has not finished redrawing "
            + "can still be read around a confirmation that buries seven shows (#4108)"))
    }

    // BOTH THEMES, because a surface token is one half of a pair with what sits behind it and checking
    // one says nothing about the other (L569, L69).
    @Test func nothingSurvivesTheBackdropInTheLightThemeEither() throws {
        let bare = try #require(render(ConfirmBackdrop(), dark: false))
        let covered = try #require(render(content().overlay { ConfirmBackdrop() }, dark: false))
        write(covered, name: "backdrop-present-light")
        let differing = differingPixels(bare, covered)
        #expect(differing == 0, Comment(rawValue:
            "\(differing) pixel(s) of the covered window differ from the backdrop drawn over nothing "
            + "in the light theme, so the cover is theme dependent"))
    }

    // AND THE TWO THEMES REALLY ARE DIFFERENT SURFACES, so neither assertion above is quietly measuring
    // the same render twice. Without this a backdrop that ignored the theme entirely would satisfy both
    // (L70).
    @Test func theTwoThemesDrawDifferentBackdrops() throws {
        let dark = try #require(render(ConfirmBackdrop(), dark: true))
        let light = try #require(render(ConfirmBackdrop(), dark: false))
        #expect(differingPixels(dark, light) > 0, Comment(rawValue:
            "the backdrop renders identically in both themes, so one of the two assertions above is "
            + "measuring the other theme and the pair proves only that the renders agree"))
    }

    // THE PICTURE A PERSON NEEDS, which the three assertions above do not produce. They prove the cover
    // works over a synthetic loud background; this renders the REAL sheet over the REAL cover so the
    // look can be judged rather than inferred. It asserts nothing about pixels, deliberately: it is a
    // shot, and a shot nobody looks at should not be able to fail a suite for a reason nobody can name.
    //
    // GATED ON THE DIRECTORY BEING SET, on `PrepPickerRendersTests`'s precedent and because the first
    // version was not: it PASSED while writing nothing at all, because the env var needs the runner's
    // `TEST_RUNNER_` prefix to reach the test process and without it `shotsDirectory` is nil. A test
    // that reports success having done nothing is indistinguishable from one that did the work (L98).
    // Skipped says "nobody asked for a picture"; passed now means a picture was written.
    @Test(.enabled(if: shotsDirectory != nil, "opt in: set TEST_RUNNER_OVERTURE_BACKDROP_SHOTS"))
    func theConfirmOverItsBackdropCanBeLookedAt() throws {
        for dark in [true, false] {
            let composed = ZStack {
                content().overlay { ConfirmBackdrop() }
                SelfBookingConfirmSheet(
                    title: "Dismiss all 7 shows on Oct 4?",
                    message: "Seven shows play that night. Dismissing them all as Not a fit also ends "
                        + "two runs that continue past it, so their later dates go too.",
                    proceedLabel: "Dismiss all 7",
                    symbol: "archivebox",
                    onProceed: {}, onCancel: {})
            }
            let rep = try #require(render(composed, dark: dark))
            write(rep, name: "confirm-over-backdrop-\(dark ? "dark" : "light")")
        }
    }
}
