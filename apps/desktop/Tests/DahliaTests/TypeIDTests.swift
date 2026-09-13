#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing

    struct TypeIDTests {
        @Test func sharedVectors() throws {
            struct Vector: Decodable { let uuid: UUID
                let suffix: String
            }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: root.appending(path: "test-fixtures/typeid.json")))
            for kind in TypeID.Kind.allCases {
                for vector in vectors {
                    let expected = kind.rawValue + "_" + vector.suffix
                    #expect(TypeID.encode(vector.uuid, as: kind) == expected)
                    #expect(try TypeID.decode(expected, as: kind) == vector.uuid)
                }
            }
        }

        @Test func invalidIDs() throws {
            for value in [
                "ws_" + String(repeating: "0", count: 25),
                "ws_8" + String(repeating: "0", count: 25),
                "mtg_" + String(repeating: "0", count: 26),
                "00000000-0000-0000-0000-000000000000",
            ] {
                #expect(throws: TypeID.Failure.self) { try TypeID.decode(value, as: .workspace) }
            }
        }

        @Test func jobErrorFieldDoesNotOverrideItsShape() throws {
            let uuid = UUID()
            for error: Any in [NSNull(), "provider_failed"] {
                let job: [String: Any] = [
                    "id": uuid.uuidString.lowercased(),
                    "error": error,
                    "input": ["recordings": [["micFileId": uuid.uuidString.lowercased()]]],
                    "transcriptResult": ["transcriptId": uuid.uuidString.lowercased()],
                ]
                let wire = try #require(PublicIDWire.transform(["job": job], shape: "summaryJobResponse", direction: .encode) as? [String: Any])
                let encoded = try #require(wire["job"] as? [String: Any])
                #expect(encoded["id"] as? String == TypeID.encode(uuid, as: .summaryJob))
                let decoded = try #require(PublicIDWire.transform(wire, shape: "summaryJobResponse", direction: .decode) as? [String: Any])
                #expect(NSDictionary(dictionary: decoded) == NSDictionary(dictionary: ["job": job]))
            }
        }

        @Test func responseStatusSelectsErrorEnvelope() throws {
            let uuid = UUID()
            let request = try URLRequest(url: #require(URL(string: "https://dahlia.example/api/v1/organizations")))
            let body = try JSONSerialization.data(withJSONObject: ["error": "conflict", "operationId": TypeID.encode(uuid, as: .operation)])
            let decoded = try JSONSerialization.jsonObject(with: PublicIDWire.response(body, request: request, status: 409)) as? [String: Any]
            #expect(decoded?["operationId"] as? String == uuid.uuidString.lowercased())
            var chunkRequest = try URLRequest(url: #require(URL(string:
                "https://dahlia.example/api/v1/meetings/\(TypeID.encode(uuid, as: .meeting))/transcript-uploads/\(TypeID.encode(uuid, as: .patch))/chunks/0"
            )))
            chunkRequest.httpMethod = "PUT"
            let chunkError = try JSONSerialization.jsonObject(with: PublicIDWire.response(body, request: chunkRequest, status: 409)) as? [String: Any]
            #expect(chunkError?["operationId"] as? String == uuid.uuidString.lowercased())
            let filter = "https://dahlia.example/api/auth/admin/list-users?filterField=id&filterValue=\(TypeID.encode(uuid, as: .user))"
            #expect(try PublicIDWire.url(filter, direction: .decode).contains(uuid.uuidString.lowercased()))
        }

        @Test func documentRoundTrip() throws {
            let uuid = "01990ab0-0000-7000-8000-000000000001"
            let source = "{ \"sections\": [{\"blocks\":[{\"screenshot_id\":\"\(uuid)\",\"content\":{\"text\":\"\(uuid)\"}}]}] }"
            let wire = try PublicIDWire.document(source, direction: .encode)
            #expect((wire as? String)?.contains("att_") == true)
            #expect(try PublicIDWire.document(wire, direction: .decode) as? String == source)
        }
    }
#endif
