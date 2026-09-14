import Testing
import Foundation

// #3886: the scanner behind the per-call pattern guard, exercised against source this test writes.
//
// A source guard's scanner is the one part of it that can be wrong in the silent direction: a scanner
// that finds nothing makes the guard report a clean app (L98). So each spelling it must catch, and each
// shape it must NOT call a finding, is driven here rather than being watched not to happen.
@Suite("The per-call pattern scanner (#3886)")
struct PerCallPatternTests {

    @Test func findsTheStringForm() {
        let source = """
            enum Fold {
                static func tidy(_ s: String) -> String {
                    s.replacingOccurrences(of: "x+", with: " ", options: .regularExpression)
                }
            }
            """
        let sites = PerCallPattern.sites(in: source)
        #expect(sites.count == 1)
        #expect(sites.first?.form == .stringForm)
    }

    // The option can arrive inside an ARRAY with another one, which is how SourceFetcher writes two of
    // its own and how the first version of this scanner walked straight past them.
    @Test func findsTheStringFormWhenTheOptionTravelsInAnArray() {
        let source = """
            enum Fold {
                static func tidy(_ s: String) -> Bool {
                    s.range(of: "x+", options: [.regularExpression, .caseInsensitive]) != nil
                }
            }
            """
        #expect(PerCallPattern.sites(in: source).first?.form == .stringForm)
    }

    @Test func findsAnObjectBuiltInsideAFunction() {
        let source = """
            enum Fold {
                static func tidy(_ s: String) -> Bool {
                    guard let re = try? NSRegularExpression(pattern: "x+") else { return false }
                    return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) > 0
                }
            }
            """
        let sites = PerCallPattern.sites(in: source)
        #expect(sites.count == 1)
        #expect(sites.first?.form == .constructedPerCall)
    }

    // The whole fix, so it must not read as the defect.
    @Test func doesNotFlagAStaticDeclaration() {
        let source = """
            enum Fold {
                private static let re = try! NSRegularExpression(pattern: "x+")
                static let wrapped = CompiledPattern("x+")
            }
            """
        #expect(PerCallPattern.sites(in: source).isEmpty)
    }

    // A comment ABOUT the rule is where the rule is most often written down, so a scanner that reads
    // comments is a scanner that fires on its own documentation (L103).
    @Test func doesNotFlagProseAboutThePattern() {
        let source = """
            enum Fold {
                // Never write options: .regularExpression here, and never call NSRegularExpression(
                // inside a function body: both compile on every call.
                static let wrapped = CompiledPattern("x+")
            }
            """
        #expect(PerCallPattern.sites(in: source).isEmpty)
    }

    @Test func reportsTheLineAndTheCode() {
        let source = """
            enum Fold {
                static func tidy(_ s: String) -> String {
                    s.replacingOccurrences(of: "x+", with: " ", options: .regularExpression)
                }
            }
            """
        let site = PerCallPattern.sites(in: source).first
        #expect(site?.line == 3)
        #expect(site?.code.contains("replacingOccurrences") == true)
    }

    // The scanner's first version skipped marked regions, because that is the default everything else
    // here uses, and it reported CompiledPattern.swift and GmailMessage.swift as holding no per-call
    // pattern when each holds one. A pattern inside a `#if DEBUG` block or a copy-inventory marked region
    // is still compiled on every call (L98).
    @Test func readsInsideAMarkedRegion() {
        let source = """
            enum Fold {
                // copy-inventory:ignore-start  outbound HTML, never a sentence Dan reads
                static func tidy(_ s: String) -> String {
                    s.replacingOccurrences(of: "x+", with: " ", options: .regularExpression)
                }
                // copy-inventory:ignore-end
            }
            """
        #expect(PerCallPattern.sites(in: source).count == 1)
    }

    @Test func readsInsideADebugBlock() {
        let source = """
            enum Fold {
                #if DEBUG
                static func tidy(_ s: String) -> String {
                    s.replacingOccurrences(of: "x+", with: " ", options: .regularExpression)
                }
                #endif
            }
            """
        #expect(PerCallPattern.sites(in: source).count == 1)
    }

    @Test func findsEverySiteRatherThanTheFirst() {
        let source = """
            enum Fold {
                static func tidy(_ s: String) -> String {
                    var out = s.replacingOccurrences(of: "x+", with: " ", options: .regularExpression)
                    out = out.replacingOccurrences(of: "y+", with: " ", options: .regularExpression)
                    return out
                }
            }
            """
        #expect(PerCallPattern.sites(in: source).count == 2)
    }
}
