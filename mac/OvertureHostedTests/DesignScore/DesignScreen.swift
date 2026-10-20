import Foundation
import SwiftUI

// What every settled screen's snapshot test shares (#4691), so each one is a few lines naming its view,
// its fixture and its checks. `DesignScoreCapture.swift` beside this is claude-config's SwiftUI adapter,
// copied VERBATIM (`scripts/design-score.sh` refuses to run when it has drifted), so nothing Overture
// needs is added to it: it goes here instead.
//
// THE RUN is `scripts/design-score.sh <screen>`, never this test on its own. The script draws the design's
// side first, then runs exactly one test here with four variables (the capture folder, the commit, whether
// the checkout is dirty, and the negative control), and xcodebuild hands each to the test
// with its `TEST_RUNNER_` prefix STRIPPED (the trap StoredMoreThanOnceLooksRightTests describes): exported
// as TEST_RUNNER_DESIGN_SCORE_CAPTURE, read here as DESIGN_SCORE_CAPTURE.
enum DesignScoreRun {
    nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The capture folder the design side was drawn into, or nil when this is an ordinary suite run.
    nonisolated static var captureFolder: String? {
        environment["DESIGN_SCORE_CAPTURE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The negative control (L1): `--perturb` asks for the build drawn wrong on purpose, so a run that
    /// matches is seen to be able to fail. The web adapter's `--perturb <css>` is the same idea.
    nonisolated static var perturbed: Bool { environment["DESIGN_SCORE_PERTURB"] == "1" }

    /// How far the negative control shifts every colour: 0.06 is about 15 levels out of 255, past the
    /// score's 8 a channel, which is what claude-config measured its own SwiftUI adapter with.
    static let perturbation = 0.06
}

enum DesignFixtureError: Error, CustomStringConvertible {
    case missing(String)
    case unreadable(String, String)

    var description: String {
        switch self {
        case .missing(let path):
            return "the design fixture \(path) is not there: a settled screen's data is committed at fixtures/design/<screen>.json, the same file its design draws"
        case .unreadable(let path, let why):
            return "the design fixture \(path) could not be read: \(why)"
        }
    }
}

/// A settled screen's committed data, the one file BOTH sides of the score draw from: the settled design
/// was made from it (make-settled.py embeds it), and the snapshot test builds the view's model from it.
enum DesignFixture {
    static func url(screen: String, root: URL = RepoRoot.url) -> URL {
        root.appendingPathComponent("fixtures/design/\(screen).json")
    }

    static func load<T: Decodable>(_ type: T.Type, screen: String, root: URL = RepoRoot.url) throws -> T {
        let url = url(screen: screen, root: root)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw DesignFixtureError.missing(url.path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DesignFixtureError.unreadable(url.path, String(describing: error))
        }
    }
}

@MainActor
enum DesignScreen {
    /// The view as it is scored: in the theme the frame is drawn in, and shifted on purpose when the run
    /// asked for the negative control. Light and dark are set here rather than left to the Mac's own
    /// appearance, so a score never depends on which theme the machine running it was in.
    static func scored(_ view: some View, scheme: ColorScheme, perturbed: Bool = DesignScoreRun.perturbed) -> AnyView {
        let themed = view.environment(\.colorScheme, scheme)
        return perturbed ? AnyView(themed.brightness(DesignScoreRun.perturbation)) : AnyView(themed)
    }

    /// Draws the built side of every frame into the run's capture folder. Throws when there is no folder,
    /// so a test reached without the script fails loudly rather than drawing nowhere.
    static func capture(build: String, view: (String) throws -> AnyView,
                        checks: (String) -> [DesignScoreCheck]) throws {
        guard let folder = DesignScoreRun.captureFolder else {
            throw DesignScoreCaptureError.unreadable("DESIGN_SCORE_CAPTURE is not set; run scripts/design-score.sh <screen>")
        }
        // The capture names what drew it, so a perturbed score can never be mistaken for the real one.
        let name = DesignScoreRun.perturbed ? "\(build), perturbed on purpose" : build
        var failure: Error?
        try DesignScoreCapture.capture(
            folder: URL(fileURLWithPath: folder), build: name,
            view: { frame in
                do {
                    return try view(frame)
                } catch {
                    failure = failure ?? error
                    return AnyView(EmptyView())
                }
            },
            checks: checks)
        // The adapter's view closure cannot throw, so a frame whose view could not be built is thrown here,
        // after the adapter wrote its capture, and the script reads the failed test as no score.
        if let failure { throw failure }
    }
}
