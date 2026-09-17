#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    struct SyncRecoveryTests {
        @Test
        func queueFailureDispositionRetriesOnlyTransportErrors() {
            #expect(SyncWorker.localQueueFailureDisposition(CancellationError()) == .ignore)
            #expect(SyncWorker.localQueueFailureDisposition(URLError(.cancelled)) == .ignore)
            #expect(SyncWorker.localQueueFailureDisposition(URLError(.timedOut)) == .retry)
            #expect(SyncWorker.localQueueFailureDisposition(URLError(.dataLengthExceedsMaximum)) == .block("invalid_sync_response_size"))
            #expect(SyncWorker.localQueueFailureDisposition(ScreenshotContentError.unavailable) == .block("local_file_unavailable"))
            #expect(SyncWorker.localQueueFailureDisposition(ScreenshotContentError.integrityFailure) == .block("local_file_integrity_failure"))
            #expect(SyncWorker.localQueueFailureDisposition(SyncTransactionQueueError.invalidReceipt) == .block("invalid_sync_receipt"))
            #expect(SyncWorker.localQueueFailureDisposition(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))) ==
                .block("invalid_sync_payload"))
        }

        @Test
        func HTTPStatusClassificationSeparatesAuthenticationAuthorizationAndRetry() {
            let expected: [(Int, SyncBlockedReason?)] = [
                (401, .authorization), (403, .authorization), (409, .conflict), (422, .validation), (426, nil),
                (408, nil), (425, nil), (429, nil), (500, nil),
            ]
            for (status, reason) in expected {
                #expect(SyncHTTPError(status: status, body: Data()).blockedReason == reason)
            }
            #expect([408, 425, 429, 500, 599].allSatisfy { SyncHTTPError(status: $0, body: Data()).isRetryable })
            #expect([301, 400, 401, 403, 409, 422, 426, 600].allSatisfy {
                !SyncHTTPError(status: $0, body: Data()).isRetryable
            })
        }

        @Test
        func tokenProviderErrorsPreserveAuthenticationAndRetryStatus() async throws {
            let request = try URLRequest(url: #require(URL(string: "https://server.example.com/api/v1/workspaces")))
            let connectionId = UUID.v7()
            let failures: [(any Error, Int)] = [
                (DahliaCloudError.noCredential, 401),
                (DahliaCloudError.tokenRequestFailed(400), 401),
                (DahliaCloudError.tokenRequestFailed(403), 401),
                (DahliaCloudError.tokenRequestFailed(503), 503),
                (DahliaCloudError.invalidTokenResponse, 401),
                (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "stored credential")), 401),
            ]
            for (failure, expectedStatus) in failures {
                let client = SyncAPIClient(session: .shared, tokenProvider: { _, _ in throw failure })
                do {
                    _ = try await client.data(for: request, connectionId: connectionId)
                    Issue.record("Expected token failure")
                } catch let error as SyncHTTPError {
                    #expect(error.status == expectedStatus)
                    #expect(error.blockedReason == (expectedStatus == 503 ? nil : .authorization))
                    #expect(error.isRetryable == (expectedStatus == 503))
                }
            }
        }

        @Test
        func incidentsContainOnlyRecoveryMetadata() throws {
            let incident = SyncIncident(
                stage: .pull,
                error: SyncHTTPError(status: 403, body: Data(#"{"code":"forbidden"}"#.utf8)),
                occurredAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
            let json = try #require(incident.jsonString)
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["stage", "status", "code", "occurredAt"])
            #expect(object["status"] as? Int == 403)
            #expect(object["code"] as? String == "forbidden")
        }

        @Test
        func incidentsReuseDeterministicLocalFailureCodes() {
            let cases: [(any Error, String)] = [
                (URLError(.timedOut), "network"),
                (URLError(.cannotParseResponse), "invalid_sync_response"),
                (URLError(.dataLengthExceedsMaximum), "invalid_sync_response_size"),
                (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), "invalid_sync_payload"),
                (TypeID.Failure.invalidID, "invalid_sync_payload"),
                (TextContentError.integrityFailure, "local_text_integrityFailure"),
            ]
            for (error, code) in cases {
                #expect(SyncIncident(stage: .pull, error: error).code == code)
            }
        }

        @Test
        func serverLinksUseCanonicalTypeIDRoutes() {
            let origin = "https://server.example.com"
            let workspaceID = UUID.v7(), projectID = UUID.v7(), meetingID = UUID.v7(), fileID = UUID.v7()
            let cases: [(SyncRecordTarget, String, TypeID.Kind)] = [
                (.init(entity: .workspace, id: workspaceID), "workspaces", .workspace),
                (.init(entity: .project, id: projectID), "projects", .project),
                (.init(entity: .meeting, id: meetingID), "meetings", .meeting),
                (.init(entity: .file, id: fileID), "files", .file),
            ]
            for (target, route, kind) in cases {
                #expect(SyncServerLink.url(origin: origin, workspaceId: workspaceID, target: target)?.absoluteString ==
                    "\(origin)/\(route)/\(TypeID.encode(target.id, as: kind))")
            }
            #expect(SyncServerLink.url(
                origin: origin,
                workspaceId: workspaceID,
                target: .init(entity: .recording, id: UUID.v7())
            )?.absoluteString == "\(origin)/workspaces/\(TypeID.encode(workspaceID, as: .workspace))")
        }

        @Test
        func recordingArchiveRetryFollowsWorkspaceRecoveryStateAndPermission() {
            func progress(state: MeetingSyncState, allowsCanonicalEdits: Bool) -> WorkspaceSyncProgress {
                WorkspaceSyncProgress(
                    id: .v7(),
                    name: "Workspace",
                    state: state,
                    phase: .attention,
                    issues: [],
                    allowsCanonicalEdits: allowsCanonicalEdits,
                    retryAt: nil,
                    retryErrorCode: nil,
                    discardImpact: nil,
                    recordingArchiveFailures: [],
                    meetings: 0,
                    files: 0,
                    attachments: 0,
                    other: 0
                )
            }

            #expect(progress(state: .synced, allowsCanonicalEdits: true).allowsRecordingArchiveRetry)
            #expect(progress(state: .blocked(.validation), allowsCanonicalEdits: true).allowsRecordingArchiveRetry)
            #expect(!progress(state: .recovering, allowsCanonicalEdits: true).allowsRecordingArchiveRetry)
            #expect(!progress(state: .updateRequired, allowsCanonicalEdits: true).allowsRecordingArchiveRetry)
            #expect(!progress(state: .relocationPaused, allowsCanonicalEdits: true).allowsRecordingArchiveRetry)
            #expect(!progress(state: .synced, allowsCanonicalEdits: false).allowsRecordingArchiveRetry)
        }
    }
#endif
