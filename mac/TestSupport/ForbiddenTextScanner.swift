import Foundation

// One pass over a file's bytes for a whole list of forbidden strings (#3235).
//
// The #2839 privacy guard asks whether any of about 150 scrubbed identities appears anywhere in about
// 1,000 files. Written as `for name in forbidden where text.contains(name)` that is 150 Unicode-aware
// string searches per file, and it measured 216 seconds of a 705 second suite on 2026-08-29: one
// suite, nearly a third of the run.
//
// The needles are indexed by their FIRST BYTE once, and each file is then scanned once: at each
// position only the needles that could possibly start there are compared. The work stops scaling with
// the number of names.
//
// Two details are correctness rather than speed, and the second is why this is not simply a byte
// search.
//
// The comparison is over the UTF-8 of the LOWERCASED text, and lowercasing happens here so a caller
// cannot forget it and quietly narrow what the guard catches.
//
// A needle that is not pure ASCII keeps the original `String.contains`. Swift's own comparison treats
// canonically equivalent spellings as equal, so a name written with a combining accent matches one
// written with a precomposed character, and a byte comparison does not. For a PRIVACY guard that
// difference can only be dangerous in one direction, letting a real person through, so the handful of
// accented needles pay the slow path and the ASCII ones do not. For an ASCII needle the two agree:
// no ASCII string is canonically equivalent to any different sequence.
struct ForbiddenTextScanner {

    private let needles: [String]
    private let needleBytes: [[UInt8]]
    // 256 slots indexed by first byte, holding indices into `needles`. A fixed array rather than a
    // dictionary because this is looked up once per BYTE of every file in the tree: hashing a UInt8
    // that many times was itself most of what remained after the one-pass rewrite.
    private let bucketsByFirstByte: [[Int]]
    private let nonASCII: [String]

    init(needles allNeedles: [String]) {
        var kept: [String] = []
        var bytes: [[UInt8]] = []
        var buckets = [[Int]](repeating: [], count: 256)
        var other: [String] = []
        for needle in allNeedles where !needle.isEmpty {
            let utf8 = Array(needle.utf8)
            if needle.allSatisfy({ $0.isASCII }) {
                buckets[Int(utf8[0])].append(kept.count)
                kept.append(needle)
                bytes.append(utf8)
            } else {
                other.append(needle)
            }
        }
        self.needles = kept
        self.needleBytes = bytes
        self.bucketsByFirstByte = buckets
        self.nonASCII = other
    }

    // Every needle that occurs in `text`, each named once however often it occurs, sorted so a report
    // reads the same way twice.
    func matches(in text: String) -> [String] {
        // A file holding only ASCII takes the fast path: its bytes are scanned as they are, with A to Z
        // folded during the comparison, so the Unicode `lowercased()` never runs. That is most of the
        // remaining cost, and most of the tree is pure ASCII.
        //
        // A file holding ANYTHING else falls back to exactly what this replaced: `lowercased()` and
        // then the same scan. That is a correctness line rather than caution. Unicode lowercasing is
        // not a per-character map, and a character like U+0130 lowercases INTO an ASCII letter plus a
        // combining mark, so a folded-bytes scan and a lowercased one can genuinely disagree. For a
        // privacy guard the disagreement can only be dangerous in one direction, letting a real person
        // through, so the rare file pays the old price.
        let raw = Array(text.utf8)
        var sawNonASCII = false
        for byte in raw where byte >= 0x80 { sawNonASCII = true; break }

        if !sawNonASCII {
            return report(scan(raw, fold: true))
        }

        let lowered = text.lowercased()
        let hits = scan(Array(lowered.utf8), fold: false)
        var accented: [String] = []
        for needle in nonASCII where lowered.contains(needle) { accented.append(needle) }
        return (report(hits) + accented).sorted()
    }

    private func report(_ hits: [Bool]) -> [String] {
        var out: [String] = []
        for (index, hit) in hits.enumerated() where hit { out.append(needles[index]) }
        return out.sorted()
    }

    // One pass. At each position only the needles that could start there are compared, and nothing in
    // this loop hashes anything.
    private func scan(_ bytes: [UInt8], fold: Bool) -> [Bool] {
        var found = [Bool](repeating: false, count: needles.count)
        var remaining = needles.count
        guard !bytes.isEmpty, remaining > 0 else { return found }

        for start in 0..<bytes.count {
            if remaining == 0 { break }
            let first = fold ? lowerASCII(bytes[start]) : bytes[start]
            let candidates = bucketsByFirstByte[Int(first)]
            if candidates.isEmpty { continue }
            for index in candidates where !found[index] {
                let needle = needleBytes[index]
                let end = start + needle.count
                guard end <= bytes.count else { continue }
                var matched = true
                var offset = 0
                while offset < needle.count {
                    let here = fold ? lowerASCII(bytes[start + offset]) : bytes[start + offset]
                    if here != needle[offset] { matched = false; break }
                    offset += 1
                }
                if matched {
                    found[index] = true
                    remaining -= 1
                }
            }
        }
        return found
    }

    private func lowerASCII(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }
}
