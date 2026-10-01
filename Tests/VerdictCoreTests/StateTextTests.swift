import Foundation
import Testing
import VerdictCore

/// `state` as any JSON value (SPEC §3). Every expected string below is the output of
/// `json.dumps(json.loads(<state>), ensure_ascii=False, sort_keys=True)` on Python 3, compared byte for byte.
@Suite struct StateTextTests {
    static func body(state: String) -> Data {
        Data(#"{"state":\#(state),"questions":{"q":{"type":"noul","instructions":"i"}}}"#.utf8)
    }

    static func decodedState(_ state: String) throws -> String {
        try Wire.decodeRequest(body(state: state)).state
    }

    static func validationMessage(_ state: String) -> String? {
        do {
            _ = try Wire.decodeRequest(body(state: state))
            return nil
        } catch {
            return error.code == .validation ? error.message : "non-validation: \(error.code)"
        }
    }

    @Test func stringPassesThroughUnchanged() throws {
        #expect(Array(try Self.decodedState(#""Café says \"refund\"\n{not json}""#).utf8)
                == Array("Caf\u{e9} says \"refund\"\n{not json}".utf8))
    }

    @Test func objectRendersSortedWithPythonSeparators() throws {
        let state = try Self.decodedState(#"{"evidence": "The sky is blue.", "claim": "Sky color is blue"}"#)
        #expect(Array(state.utf8) == Array(#"{"claim": "Sky color is blue", "evidence": "The sky is blue."}"#.utf8))
    }

    @Test func nestedObjectEscapesLikeEnsureAsciiFalse() throws {
        let state = try Self.decodedState(
            #"{"z": {"y": [1, 2], "x": "Café \"q\" \\ / \n\t\u0001\u001f\u007f  😀"}, "a": null, "m": false}"#)
        let expected = #"{"a": null, "m": false, "z": {"x": "Caf\#u{e9} \"q\" \\ / \n\t\u0001\u001f\#u{7f}\#u{2028} \#u{1F600}", "y": [1, 2]}}"#
        #expect(Array(state.utf8) == Array(expected.utf8))
    }

    @Test func arrayKeepsIntFloatAndLiterals() throws {
        let state = try Self.decodedState(#"[1, 1.0, 1e2, -0, -0.0, true, null, "é", {"b": 2, "a": []}, {}]"#)
        #expect(Array(state.utf8) == Array(#"[1, 1.0, 100.0, 0, -0.0, true, null, "\#u{e9}", {"a": [], "b": 2}, {}]"#.utf8))
    }

    @Test func numbersMatchPythonRepr() throws {
        let state = try Self.decodedState(#"[9999000000000000.0, 1e16, 0.0001, 0.00001, 18446744073709551615, -9223372036854775808, 123456789.123456789, 5e-324, 1.7976931348623157e308, 0.1]"#)
        let expected = "[9999000000000000.0, 1e+16, 0.0001, 1e-05, 18446744073709551615, -9223372036854775808, 123456789.12345679, 5e-324, 1.7976931348623157e+308, 0.1]"
        #expect(state == expected)
    }

    @Test func keysSortByCodePointNotCanonicalForm() throws {
        // "é" and "é" are canonically equal in Swift; Python keeps both and orders by code point.
        let state = try Self.decodedState(#"{"b": 1, "a": 2, "é": 3, "Z": 4, "é": 5, "😀": 6, "Ａ": 7, "": 8}"#)
        let expected = #"{"": 8, "Z": 4, "a": 2, "b": 1, "e\#u{301}": 5, "\#u{e9}": 3, "\#u{ff21}": 7, "\#u{1F600}": 6}"#
        #expect(Array(state.utf8) == Array(expected.utf8))
    }

    @Test func scalarStateRendersAsJSONText() throws {
        #expect(try Self.decodedState("42") == "42")
        #expect(try Self.decodedState("true") == "true")
    }

    @Test func emptyStateIsValidation() throws {
        for state in ["{}", "[]", " { } "] {
            #expect(Self.validationMessage(state)?.contains("`state` is empty") == true, Comment(rawValue: state))
        }
        for state in [#""""#, #""  \n""#] {   // decodes; the engine rejects it
            let core = try Wire.decodeRequest(Self.body(state: state)).toCore()
            do {
                try Verdict.validate(core)
                Issue.record("accepted empty state \(state)")
            } catch {
                #expect(error.code == .validation)
                #expect(error.message.contains("`state` is empty"))
            }
        }
        #expect(Self.validationMessage("null")?.contains("state") == true)
        do {
            _ = try Wire.decodeRequest(Data(#"{"questions":{"q":{"type":"noul","instructions":"i"}}}"#.utf8))
            Issue.record("decoded a request without state")
        } catch {
            #expect(error.code == .validation)
            #expect(error.message.contains("missing key `state`"))
        }
    }

    @Test func integerBeyond64BitsIsValidation() {
        #expect(Self.validationMessage(#"{"n": 123456789012345678901234567890}"#)?.contains("64-bit") == true)
    }

    @Test func backendSeesTheClientSideDumpsText() async throws {
        let object = #"{"evidence": "Le ciel est bleu.", "claim": "Café"}"#
        let dumped = #""{\"claim\": \"Café\", \"evidence\": \"Le ciel est bleu.\"}""#   // json.dumps(..., sort_keys=True), as a JSON string
        var seen: [String] = []
        for state in [object, dumped] {
            let backend = FakeBackend([.success(.bool(true))])
            _ = try await Verdict(backend: backend).decide(Wire.decodeRequest(Self.body(state: state)).toCore())
            seen += backend.states.withLock { $0 }
        }
        #expect(seen.count == 2)
        #expect(Array(seen[0].utf8) == Array(seen[1].utf8))
    }

    @Test func objectStateRoundTripsAsItsText() throws {
        let w = try Wire.decodeRequest(Self.body(state: #"{"b": [1.0], "a": "x"}"#))
        let again = try Wire.decodeRequest(try Wire.encoder().encode(w))
        #expect(again == w)
        #expect(again.state == #"{"a": "x", "b": [1.0]}"#)
    }

    @Test func bareJSONDecoderAcceptsOnlyStringState() {
        // The raw body is needed to tell 1 from 1.0; only `Wire.decodeRequest` supplies it.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Wire.Request.self, from: Self.body(state: #"{"a": 1}"#))
        }
    }
}
