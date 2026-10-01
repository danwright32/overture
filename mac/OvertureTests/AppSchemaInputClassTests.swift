import Foundation
import SwiftData
import Testing

// #4356 (plan v7 Phase 2, schema classification): `AppSchemaInputClass` names how every model reaches the
// queue, and is held to the code in both directions rather than trusted (L96).
//
//   * to `AppSchema.models`: every model classified exactly once, and nothing classified that is not one;
//   * to `QueueRenderPass.Inputs`: every field a class says it feeds is a real field of the pass's inputs;
//   * to `QueueView`: the models it actually holds (its `@Query`s and the array handed to it) are exactly
//     the ones classified as read directly, so a table the queue starts reading cannot stay classified as
//     one it ignores, and the reverse;
//   * and a table classified as not an input is not named anywhere in the pass's code.
@Suite("Every model's way into the queue is classified, and the classes are true (#4356)")
@MainActor
struct AppSchemaInputClassTests {

    static var modelNames: Set<String> { Set(AppSchema.models.map { String(describing: $0) }) }

    static func code(of fileName: String) throws -> [String] {
        let file = try #require(AppSourceWalk.appFiles().first { $0.name == fileName })
        return SwiftSource.scannableLines(in: file.text).map(\.code)
    }

    /// The models `QueueView` holds as arrays: its queries, and the corpus `RootView` hands it.
    static func modelsTheQueueViewHolds() throws -> Set<String> {
        var held: Set<String> = []
        for line in try code(of: "QueueView.swift") {
            // A member of the view itself, four spaces in, stored rather than computed.
            guard line.hasPrefix("    "), !line.hasPrefix("     "), !line.contains("{") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let open = trimmed.range(of: ": ["), trimmed.hasSuffix("]"),
                  trimmed.contains("var ") || trimmed.contains("let ") else { continue }
            let element = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            if modelNames.contains(element) { held.insert(element) }
        }
        return held
    }

    static func inputs() -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus([]), inquiries: [], orgAnswers: [],
                               context: StageContext.at("2026-10-01", now: Date(timeIntervalSince1970: 0)))
    }

    /// Whether `path` (`field` or `field.subfield`) names a stored property reachable from `root`.
    static func resolves(_ path: String, from root: Any) -> Bool {
        var current: Any = root
        for part in path.split(separator: ".") {
            guard let child = Mirror(reflecting: current).children.first(where: { $0.label == String(part) })
            else { return false }
            current = child.value
        }
        return true
    }

    @Test func everyModelIsClassifiedExactlyOnce() {
        let classified = Set(AppSchemaInputClass.byModel.keys)
        #expect(Self.modelNames.count > 10, "the schema walk found too few models to have checked anything")
        let missing = Self.modelNames.subtracting(classified).sorted()
        let extra = classified.subtracting(Self.modelNames).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "these models are in AppSchema and unclassified, so the "
            + "engine would take their changes in as nothing: " + missing.joined(separator: ", ")))
        #expect(extra.isEmpty, Comment(rawValue: "classified but not in AppSchema: " + extra.joined(separator: ", ")))
    }

    @Test func everyFieldAClassFeedsIsARealInput() {
        let inputs = Self.inputs()
        var paths: [String] = []
        for (_, inputClass) in AppSchemaInputClass.byModel {
            switch inputClass {
            case .perRowFact(_, let feeds): paths += feeds.map { [$0] } ?? []
            case .smallTableInput(let feeds): paths += feeds
            case .notAQueueInput: break
            }
        }
        #expect(paths.count > 8, "too few feeds were read for this to have checked anything")
        let unreal = paths.filter { !Self.resolves($0, from: inputs) }.sorted()
        #expect(unreal.isEmpty, Comment(rawValue: "these feeds name no field of QueueRenderPass.Inputs: "
            + unreal.joined(separator: ", ")))
    }

    @Test func theModelsTheQueueHoldsAreExactlyTheOnesClassifiedAsReadDirectly() throws {
        let held = try Self.modelsTheQueueViewHolds()
        var direct: Set<String> = []
        for (model, inputClass) in AppSchemaInputClass.byModel {
            switch inputClass {
            case .perRowFact(.none, _), .smallTableInput: direct.insert(model)
            default: break
            }
        }
        // The positive control: the scan must at least find the corpus and the ledger it is known to hold.
        #expect(held.isSuperset(of: ["Prospect", "OrgReachabilityAnswer"]),
                "the scan of QueueView found too little to have read its stored properties")
        let readButNotClassified = held.subtracting(direct).sorted()
        let classifiedButNotRead = direct.subtracting(held).sorted()
        #expect(readButNotClassified.isEmpty, Comment(rawValue: "QueueView holds these, and they are not "
            + "classified as read by the queue: " + readButNotClassified.joined(separator: ", ")))
        #expect(classifiedButNotRead.isEmpty, Comment(rawValue: "classified as read by the queue, and "
            + "QueueView holds none of them: " + classifiedButNotRead.joined(separator: ", ")))
    }

    @Test func aTableClassifiedAsNotAnInputIsNamedNowhereInThePass() throws {
        let passCode = try Self.code(of: "QueueRenderPass.swift") + Self.code(of: "QueueView.swift")
        let words = Set(passCode.flatMap { $0.split { !$0.isLetter && !$0.isNumber && $0 != "_" } }.map(String.init))
        #expect(words.contains("OrgReachabilityAnswer"), "the scan of the pass found no model name at all")
        var named: [String] = []
        var reasonless: [String] = []
        for (model, inputClass) in AppSchemaInputClass.byModel {
            guard case .notAQueueInput(let reason) = inputClass else { continue }
            if words.contains(model) { named.append(model) }
            if reason.first?.isLetter != true { reasonless.append(model) }
        }
        #expect(named.isEmpty, Comment(rawValue: "classified as not a queue input, and named in the pass's "
            + "code: " + named.sorted().joined(separator: ", ")))
        #expect(reasonless.isEmpty, Comment(rawValue: "classified as not a queue input with no written "
            + "reason: " + reasonless.sorted().joined(separator: ", ")))
    }

    @Test func aParentLinkIsARelationshipOnThatModel() {
        for (model, inputClass) in AppSchemaInputClass.byModel {
            guard case .perRowFact(let parent?, _) = inputClass else { continue }
            let entity = AppSchema.schema.entities.first { $0.name == model }
            #expect(entity?.relationships.contains { $0.name == parent } == true,
                    Comment(rawValue: "\(model) names `\(parent)` as its parent link, and the schema "
                        + "stores no such relationship on it"))
        }
    }

    // THE RELATIONSHIP TEST (plan v5 D2, carried into v7 Phase 2). Every relationship the schema stores
    // must have a declared way in: carried as values inside the owner's facts, or the parent link a
    // `.perRowFact(parent:)` class rides on. A relationship added later with neither is one whose changes
    // the engine would take in as nothing (L30). Today there is exactly one, in both directions:
    // `Prospect.recipients` and `Recipient.prospect`.
    @Test func everySchemaRelationshipHasADeclaredWayIn() {
        var relationships: [String] = []
        var unhandled: [String] = []
        let carried = Set(RowFactsSchemaCoverageTests.structural.values.compactMap { $0 }
            .map { "Prospect.\($0)" })
        for entity in AppSchema.schema.entities {
            for relationship in entity.relationships {
                let name = "\(entity.name).\(relationship.name)"
                relationships.append(name)
                let isParentLink: Bool
                if case .perRowFact(let parent, _) = AppSchemaInputClass.byModel[entity.name] {
                    isParentLink = parent == relationship.name
                } else {
                    isParentLink = false
                }
                if !carried.contains(name) && !isParentLink { unhandled.append(name) }
            }
        }
        #expect(!relationships.isEmpty, "the schema walk found no relationship at all, so it checked nothing")
        #expect(unhandled.isEmpty, Comment(rawValue: "these relationships have no way into a row's facts: "
            + unhandled.sorted().joined(separator: ", ")
            + ". Carry them in the owner's RowFacts, or classify the related model as `.perRowFact(parent:)`."))
    }
}
