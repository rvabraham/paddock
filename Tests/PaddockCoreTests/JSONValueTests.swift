import Foundation
import Testing

@testable import PaddockCore

struct JSONValueTests {
    @Test func foundationDecodeMatchesCodableTypesIncludingNumericBooleansAndNull() throws {
        let fixtures = [
            #"{"true":true,"false":false,"one":1,"zero":0,"fraction":1.5,"negative":-17,"null":null,"string":"1","array":[true,1,"1",null,{"n":1e30}]}"#,
            #"[[],{},"é / escaped \" value",-0.5,9223372036854775807,0.00001]"#,
            "null", "true", "1", #""value""#,
        ]
        for fixture in fixtures {
            let data = Data(fixture.utf8)
            #expect(try JSONValue.decode(data) == JSONDecoder().decode(JSONValue.self, from: data))
        }
        let value = try JSONValue.decode(Data(#"{"one":1,"true":true}"#.utf8))
        #expect(value["one"] == .number(1))
        #expect(value["true"] == .bool(true))
    }
    @Test func syntheticProviderResponsesDecodeEquallyWithFoundationAndCodable() throws {
        for (channel, response) in ReplayTestFixtures.raw() {
            let data = try JSONEncoder().encode(response)
            #expect(
                try JSONValue.decode(data) == JSONDecoder().decode(JSONValue.self, from: data),
                "Mismatched synthetic provider JSON: \(channel)")
        }
    }
    @Test func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) { try JSONValue.decode(Data("{ invalid".utf8)) }
    }

    @Test func fractionalNumbersAndStringsCannotBecomeIntegersOrBooleans() {
        let values: [JSONValue] = [
            .number(1.5), .number(-1.5), .number(0.5), .number(-0.5),
            .number(Double.leastNonzeroMagnitude), .number(-Double.leastNonzeroMagnitude),
            .string("1.5"), .string("-1.5"), .string("0.5"), .string("-0.5"),
            .string("2026.9"), .string("7.9"),
        ]
        for value in values {
            #expect(value.int == nil)
            #expect(value.bool == nil)
        }
    }

    @Test func wholeNumbersAndNativeBooleansPreserveTheirRecordedMeaning() {
        let values: [(JSONValue, Int)] = [
            (.number(0), 0), (.number(-0.0), 0), (.number(17), 17), (.number(-17), -17),
            (.string("0"), 0), (.string("17"), 17), (.string("-17"), -17),
            (.string("1.0"), 1), (.string("1e2"), 100), (.number(100), 100),
        ]
        for (value, expected) in values {
            #expect(value.int == expected)
            #expect(value.bool == (expected != 0))
        }
        #expect(JSONValue.bool(true).bool == true)
        #expect(JSONValue.bool(false).bool == false)
        #expect(JSONValue.bool(true).int == nil)
    }

    @Test func integerConversionPreservesRangeAndFiniteBoundaries() {
        #expect(JSONValue.number(Double(Int.min)).int == Int.min)
        #expect(JSONValue.string(String(Int.min)).int == Int.min)
        #expect(JSONValue.number(Double(Int.max).nextDown).int == Int(Double(Int.max).nextDown))
        let values: [JSONValue] = [
            .number(Double(Int.min).nextDown), .number(Double(Int.max)),
            .number(Double.greatestFiniteMagnitude), .number(.infinity), .number(-.infinity), .number(.nan),
            .string("1e400"), .string("-Infinity"), .string("nan"),
        ]
        for value in values {
            #expect(value.int == nil)
            #expect(value.bool == nil)
        }
    }
}
