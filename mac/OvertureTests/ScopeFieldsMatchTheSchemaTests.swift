import Testing
import Foundation
import SwiftData

// #4252: `ScopeMemo` serves an answer when every value of every row it was handed is what it was when the
// answer was built. That is only true of the values it COMPARES, so a stored property missing from a
// model's `scopeFields` is a property whose change is served as no change: a stale screen (L40).
//
// So the lists are held to `AppSchema.schema`, the same Schema the app opens its store with, in both
// directions: nothing the schema stores is missing, and nothing listed is something the schema does not
// store (a computed property listed by mistake would compare a derived value and miss the stored one).
// Derived from the schema rather than from a list kept beside it (L41), which is also how
// `StoredPropertyRatchetTests` enumerates the same properties.
@Suite("Every stored property is one a memo compares (#4252)")
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
    static func compared() -> (names: Set<String>, unreadable: [String], models: Int) {
        var names: Set<String> = []
        var unreadable: [String] = []
        var models = 0
        for model in AppSchema.models {
            guard let compared = model as? any ScopeCompared.Type else { continue }
            models += 1
            for path in compared.scopeKeyPaths {
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

    @Test func everyModelInTheSchemaIsCompared() {
        let notCompared = AppSchema.models.filter { !($0 is any ScopeCompared.Type) }.map { "\($0)" }
        #expect(notCompared.isEmpty, Comment(rawValue:
            "\(notCompared.joined(separator: ", ")) cannot be compared by value, so a memo handed one "
            + "would not compile, and one reached through a relationship would go uncompared"))
    }

    @Test func theListsNameExactlyWhatTheSchemaStores() {
        let schema = Self.stored()
        let (listed, unreadable, models) = Self.compared()
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
            "stored but never compared, so a change to any of them is served as no change: "
            + missing.joined(separator: ", ") + ". Add each to its model in ScopeFields.swift."))
        #expect(extra.isEmpty, Comment(rawValue:
            "compared but not stored: " + extra.joined(separator: ", ")))
    }
}
