import Foundation

// #1808: whether the copy of Overture Dan is looking at is behind what has shipped.
//
// He installs Release by hand (`mac/build-install.sh`), so the gap between "merged" and "what is in front
// of him" is routinely days wide, and until now it was invisible from inside the product: nothing in the
// app read a build date at all. The cost is not abstract. More than once he has reported a bug in
// behaviour that had already been fixed, because the fix was not in the app he was looking at.
//
// The app cannot run git, so it does not try to work this out for itself. It reads two small records
// written by the two things that genuinely know, each with exactly one writer:
//
//  - `installed-build.json`, written by `mac/build-install.sh`: the commit it just installed, that
//    commit's date, and the path of the checkout it built from (which is also what makes the panel's
//    Update button possible, since the app otherwise has no idea where the code lives).
//  - `shipped-commit.json`, written by `scripts/record-shipped-commit.sh` from the merge path: the
//    newest commit on main.
//
// Both live in Overture's own data directory beside the handoff files, and both are in
// `docs/contracts.md`. Pure: given two records (or their absence) this decides, so every branch below is
// reachable from a test without a build, an install, or a merge.

// What the installer put in /Applications, as it recorded it.
struct InstalledBuild: Codable, Equatable, Sendable {
    let commit: String
    let commitDate: Date
    // The checkout the installer built from. Read by UpdateCommandFile so the panel's button can run the
    // installer where the code actually is.
    let repoPath: String
    // #2553: whether that commit was on main when it was installed, decided by the installer, which is
    // the only thing here that can run git. nil means the record was written before Overture stamped
    // this, which is a different fact from the installer being unable to tell and is kept apart below.
    let provenance: BuildFreshness.Provenance?
}

// The newest commit on main, as the merge path recorded it.
struct ShippedCommit: Codable, Equatable, Sendable {
    let commit: String
    let commitDate: Date
}

enum BuildFreshness {
    // #2553: where the installed build came from, as `mac/scripts/lib/build-provenance.sh` decided it.
    //
    // The panel used to compare the installed bundle's commit DATE against the newest shipped commit's
    // date. A build made from an unmerged branch is NEWER than everything on main, so it reported "up to
    // date" in exactly the words a correct install uses. That is the one state nobody would notice,
    // because the live app holds the real store and the panel actively says everything is current.
    enum Provenance: String, Codable, Equatable, Sendable {
        case main
        case branch
        // A real answer, not a failure: no origin, an unreachable remote, a directory that is not a
        // repository. Never reported as `branch`, because an accusation made from an index that is
        // merely incomplete would tell Dan his ordinary install came from an unmerged branch, and
        // re-installing would not clear it (L119).
        case unknown

        // A spelling this app does not know maps to `unknown` rather than throwing, so one unrecognised
        // word cannot fail the WHOLE record and be read as "this copy did not come from the installer",
        // which is a different and much louder claim. Guessing at `main` or `branch` would be inventing
        // an answer (L113).
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Provenance(rawValue: raw) ?? .unknown
        }
    }

    static let installedRecordFilename = "installed-build.json"
    static let shippedRecordFilename = "shipped-commit.json"

    // Why the question cannot be answered. Named rather than folded into one "unknown", because the two
    // say different things to whoever has to fix them: no installed record means this copy did not come
    // from the installer, and no shipped record means nothing has recorded a merge on this Mac.
    enum Unknown: Equatable, Sendable {
        case noInstalledRecord
        case noShippedRecord
        // #2553: the two ways provenance can be missing, kept apart because they need different things
        // done about them. `provenanceNotRecorded` is a record written before Overture stamped this and
        // is fixed by the next install; `provenanceUnknown` is an installer that could not reach the
        // remote, and re-installing offline will not clear it.
        case provenanceNotRecorded
        case provenanceUnknown
    }

    enum Verdict: Equatable, Sendable {
        case upToDate
        case behind(installedAt: Date, shippedAt: Date)
        // #2553: installed from code that was not on main. Its own verdict rather than a flavour of
        // `behind`, because it is not merely old: it is not what shipped at all, and it is running
        // against the real store.
        case builtFromABranch
        // #2077: this copy was BUILT FROM SOURCE and never installed, so no question about an installed
        // copy applies to it. Its own answer rather than suppressing the panel, because suppressing
        // would leave the verdict still saying something false: a Debug build reads its own data folder,
        // which never holds the installer's records, so it answered `cannotTell(.noInstalledRecord)` on
        // every single launch. It is not a copy that failed to come from the installer, it is one that
        // was never meant to (L11).
        case runFromSource
        // Never "assume fresh". A silent up-to-date is indistinguishable from no check at all, which is
        // exactly the state #1808 exists to end (L11: a message may only claim what its check measured).
        case cannotTell(Unknown)
    }

    // `isRunFromSource` is passed in rather than read here, so this stays a pure function over values
    // and so there is ONE definition of "is this the Debug build": `StoreLocation.isDebugBuild`, the same
    // constant that decides which data folder this copy reads. Two definitions is how the panel and the
    // store could come to disagree about which copy is running (L263).
    static func verdict(installed: InstalledBuild?, shipped: ShippedCommit?,
                        isRunFromSource: Bool = false) -> Verdict {
        // #2077: asked FIRST, because every answer below is a claim about an installed copy and there is
        // not one. It outranks even `upToDate`, which a build from source could otherwise reach by
        // holding the same commit as the last merge while being an entirely different bundle.
        if isRunFromSource { return .runFromSource }
        guard let installed else { return .cannotTell(.noInstalledRecord) }
        guard let shipped else { return .cannotTell(.noShippedRecord) }
        // The same commit is the exact answer and never goes through the clock: two records OF one commit
        // cannot disagree about how old it is, whatever either machine's time says. It outranks
        // provenance too (#2553): a copy that IS the shipped commit is current whatever ref it was built
        // from, and a warning there would be about a bundle byte for byte identical to what shipped.
        guard installed.commit != shipped.commit else { return .upToDate }

        // #2553: not on main is its own answer, and it is given whether or not the dates also say behind.
        // Both are true then, and this is the one that explains the copy in front of him; "behind" alone
        // invites him to read an unmerged build as ordinary lag.
        if installed.provenance == .branch { return .builtFromABranch }

        // Older is older, and that is settled by the two dates alone, so it is still reported even when
        // provenance was never stamped. Withholding it would refuse to say something this check measured.
        if installed.commitDate < shipped.commitDate {
            return .behind(installedAt: installed.commitDate, shippedAt: shipped.commitDate)
        }

        // What is left is a DIFFERENT commit that is newer than the newest recorded merge. With
        // provenance of `main` that is a shipped record which has not caught up, and it is current. It is
        // also the exact shape a branch build takes, so without provenance this check has not measured
        // enough to say either, and saying "up to date" here is what #2553 was filed about.
        switch installed.provenance {
        case .main: return .upToDate
        case .unknown: return .cannotTell(.provenanceUnknown)
        case .branch: return .builtFromABranch   // unreachable: handled above, and never a silent default
        case .none: return .cannotTell(.provenanceNotRecorded)
        }
    }

    // The same question against a directory. The directory is passed in rather than resolved here, so a
    // test can never read or write Dan's real Application Support folder (L2).
    static func verdict(in directory: URL, isRunFromSource: Bool = false) -> Verdict {
        verdict(installed: installedRecord(in: directory), shipped: shippedRecord(in: directory),
                isRunFromSource: isRunFromSource)
    }

    static func installedRecord(in directory: URL) -> InstalledBuild? {
        decode(InstalledBuild.self, at: directory.appendingPathComponent(installedRecordFilename))
    }

    static func shippedRecord(in directory: URL) -> ShippedCommit? {
        decode(ShippedCommit.self, at: directory.appendingPathComponent(shippedRecordFilename))
    }

    // A file that is present but unreadable comes back nil, and so reads as "cannot tell" above. That is
    // deliberate and is the same answer for the same reason: a record that cannot be decoded says nothing
    // about what is installed, so treating it as up to date would be inventing an answer.
    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        // #2879: through the shared reader, so a record that is THERE and cannot be decoded is recorded
        // as such rather than being indistinguishable from one that was never written. The ANSWER is
        // unchanged, deliberately: nil still means "cannot tell", which is the honest reading either way.
        return HandoffFile.read(at: url) { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        }.value
    }
}
