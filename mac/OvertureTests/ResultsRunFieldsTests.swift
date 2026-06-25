import Testing
import Foundation
@testable import Overture

@Suite("Results run fields")
struct ResultsRunFieldsTests {
    @Test func decodesRunRangeAndFlag() throws {
        let json = """
        {"version":2,"generatedAt":"2026-06-25T00:00:00Z","prospects":[
          {"groupName":"Mark Morris","discipline":"dance","venue":"The Joyce","performanceDate":"2026-07-14",
           "sourceListingUrl":"u1","websiteUrl":null,"priorRelationship":"none","production":"self","profile":"strong",
           "coverage":"likely_uncovered","fitScore":9,"tier":"high","fitReason":"r","matchedClientName":null,
           "possibleMatchSource":null,"possibleMatchName":null,
           "runEndDate":"2026-07-16","partOfRelatedRun":true,"runSourceUrls":["u1","u2","u3"]}
        ]}
        """
        let file = try JSONDecoder().decode(ResultsFile.self, from: Data(json.utf8))
        let p = file.prospects[0]
        #expect(p.runEndDate == "2026-07-16")
        #expect(p.partOfRelatedRun == true)
        #expect(p.runSourceUrls == ["u1", "u2", "u3"])
    }
}
