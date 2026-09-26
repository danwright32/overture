import Testing
import Foundation
import SwiftData

// #4252: `ScopeMemo` may serve SwiftData's refetch the answer it already has, and when it does it re-arms
// observation on every stored property of every row (`ScopeRows.armAll`), because the refetch spent the
// tracking the build armed. That is only every property if the model's list names every one: a stored
// property missing from `scopeFields` is one whose next edit reaches nobody after a served refetch, and
// the screen keeps the old answer (L40).
//
// So the lists are held to `AppSchema.schema`, the same Schema the app opens its store with, in both
// directions: nothing the schema stores is missing, and nothing listed is something the schema does not
// store. Derived from the schema rather than from a list kept beside it (L41), which is also how
// `StoredPropertyRatchetTests` enumerates the same properties.
@Suite("Every stored property is one a served memo re-arms (#4252)")
struct ScopeFieldsMatchTheSchemaTests {

    // "Entity.property" for every attribute and relationship the schema stores.
    static func stored() -> Set<String> {
        var out: Set<String> = []
        for entity in AppSchema.schema.entities {
            for a in entity.attributes { out.insert("\(entity.name).\(a.name)") }
            for r in entity.relationships { out.insert("\(entity.name).\(r.name)") }
        }
        return out
    }

    // "Entity.property" for every field a model hands the memo, named from its own key path. A key path
    // prints as `\Prospect.naturalKey`, which is the spelling the schema uses.
    static func armed() -> (names: Set<String>, unreadable: [String], models: Int) {
        var names: Set<String> = []
        var unreadable: [String] = []
        var models = 0
        for model in AppSchema.models {
            guard let observed = model as? any ScopeObserved.Type else { continue }
            models += 1
            for path in observed.scopeKeyPaths {
                let printed = String(describing: path)
                guard printed.hasPrefix("\\"), printed.contains(".") else {
                    unreadable.append(printed)
                    continue
                }
                names.insert(String(printed.dropFirst()))
            }
        }
        return (names, unreadable, models)
    }

    @Test func everyModelInTheSchemaIsArmed() {
        let notArmed = AppSchema.models.filter { !($0 is any ScopeObserved.Type) }.map { "\($0)" }
        #expect(notArmed.isEmpty, Comment(rawValue:
            "\(notArmed.joined(separator: ", ")) cannot be re-armed, so a memo handed one would not "
            + "compile, and one reached through a relationship would go unwatched after a served refetch"))
    }

    @Test func theListsNameExactlyWhatTheSchemaStores() {
        let schema = Self.stored()
        let (listed, unreadable, models) = Self.armed()
        // The positive control: a walk that found nothing would pass both comparisons below (L98).
        #expect(models == AppSchema.models.count && schema.count > 300, Comment(rawValue:
            "only \(models) models and \(schema.count) stored properties were enumerated, so this guard "
            + "measured part of the store"))
        #expect(unreadable.isEmpty, Comment(rawValue:
            "these key paths do not print their names, so the comparison below cannot see them: "
            + unreadable.joined(separator: ", ")))

        let missing = schema.subtracting(listed).sorted()
        let extra = listed.subtracting(schema).sorted()
        #expect(missing.isEmpty, Comment(rawValue:
            "stored but never re-armed, so after a served refetch an edit to any of them reaches nobody: "
            + missing.joined(separator: ", ") + ". Add each to its model in ScopeFields.swift."))
        #expect(extra.isEmpty, Comment(rawValue:
            "listed but not stored: " + extra.joined(separator: ", ")))
    }
}
