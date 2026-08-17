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
}

// The newest commit on main, as the merge path recorded it.
struct ShippedCommit: Codable, Equatable, Sendable {
    let commit: String
    let commitDate: Date
}

enum BuildFreshness {
    static let installedRecordFilename = "installed-build.json"
    static let shippedRecordFilename = "shipped-commit.json"

    // Why the question cannot be answered. Named rather than folded into one "unknown", because the two
    // say different things to whoever has to fix them: no installed record means this copy did not come
    // from the installer, and no shipped record means nothing has recorded a merge on this Mac.
    enum Unknown: Equatable, Sendable {
        case noInstalledRecord
        case noShippedRecord
    }

    enum Verdict: Equatable, Sendable {
        case upToDate
        case behind(installedAt: Date, shippedAt: Date)
        // Never "assume fresh". A silent up-to-date is indistinguishable from no check at all, which is
        // exactly the state #1808 exists to end (L11: a message may only claim what its check measured).
        case cannotTell(Unknown)
    }

    static func verdict(installed: InstalledBuild?, shipped: ShippedCommit?) -> Verdict {
        guard let installed else { return .cannotTell(.noInstalledRecord) }
        guard let shipped else { return .cannotTell(.noShippedRecord) }
        // The same commit is the exact answer and never goes through the clock: two records OF one commit
        // cannot disagree about how old it is, whatever either machine's time says.
        guard installed.commit != shipped.commit else { return .upToDate }
        guard installed.commitDate < shipped.commitDate else { return .upToDate }
        return .behind(installedAt: installed.commitDate, shippedAt: shipped.commitDate)
    }

    // The same question against a directory. The directory is passed in rather than resolved here, so a
    // test can never read or write Dan's real Application Support folder (L2).
    static func verdict(in directory: URL) -> Verdict {
        verdict(installed: installedRecord(in: directory), shipped: shippedRecord(in: directory))
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
