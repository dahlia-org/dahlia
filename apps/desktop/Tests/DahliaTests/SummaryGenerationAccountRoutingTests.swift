#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SummaryGenerationAccountRoutingTests {
        @Test(arguments: [false, true], [false, true])
        func manualRequestsLoadTheMeetingAccountBeforeLocalInference(bulk: Bool, unavailable: Bool) async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let connectionID = try attachServerAccount(to: fixture)
            var requestedAccounts: [UUID] = []
            var generatedSettings: [SummaryGenerationSettings] = []
            let viewModel = CaptionViewModel(summaryGenerationRunner: { input in
                generatedSettings.append(input.generationSettings)
                throw CancellationError()
            }, summaryAccountSettingsLoader: { id in
                requestedAccounts.append(id)
                if unavailable { throw URLError(.notConnectedToInternet) }
                return accountSettings()
            })
            await fixture.select(fixture.first, in: viewModel, note: "note")
            if bulk {
                viewModel.triggerManualSummaries(
                    meetingIds: [fixture.first.id, fixture.second.id], dbQueue: fixture.database.dbQueue, vaultURL: nil
                )
            } else {
                try #require(viewModel.triggerManualSummary())
            }
            let jobs = viewModel.summaryGenerationJobs
            #expect(jobs.count == (bulk ? 2 : 1))
            for job in jobs {
                await job.task?.value
            }
            #expect(requestedAccounts == Array(repeating: connectionID, count: jobs.count))
            #expect(generatedSettings.count == (unavailable ? 0 : jobs.count))
            for settings in generatedSettings {
                #expect(settings.sourceAccountConnectionID == connectionID)
                #expect(settings.languageDisplayName == SummaryLanguage.fr.displayName)
                #expect(settings.detailLevelInstruction == SummaryDetailLevel.concise.instruction)
            }
            if unavailable {
                let allFailed = jobs.allSatisfy(\.hasFailure)
                #expect(allFailed)
            }
        }

        @Test
        func recordedLocalProcessingDoesNotLoadCurrentAccountSettings() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let connectionID = try attachServerAccount(to: fixture)
            var generationCalls = 0
            let viewModel = CaptionViewModel(summaryGenerationRunner: { input in
                generationCalls += 1
                #expect(input.generationSettings.sourceAccountConnectionID == connectionID)
                throw CancellationError()
            }, summaryAccountSettingsLoader: { _ in
                Issue.record("Frozen recording processing must not load current account settings")
                throw URLError(.notConnectedToInternet)
            })
            await fixture.select(fixture.first, in: viewModel, note: "note")
            let sessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            var generationSettings = SummaryGenerationSettings.current()
            generationSettings.accountConnectionID = connectionID
            let processing = RecordingProcessing(
                id: .v7(), automatic: true, liveDraft: false, localeIdentifier: "en_US", method: .transcript,
                options: .manual, generationSettings: generationSettings, serverSettings: nil,
                summaryMode: .local, sessionIDs: [sessionID], stage: .transcribing
            )
            try await fixture.database.dbQueue.write { db in try processing.save(sessionID: sessionID, in: db) }
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID, meetingID: fixture.first.id, options: .manual,
                dbQueue: fixture.database.dbQueue, vaultURL: fixture.vaultURL,
                generationSettings: generationSettings, processing: processing
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(meetingId: fixture.first.id, state: .completed(sessionId: sessionID)))
            for job in viewModel.summaryGenerationJobs {
                await job.task?.value
            }
            #expect(generationCalls == 1)
        }

        @Test
        func cancellationDuringAccountLoadingNeverStartsInference() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            _ = try attachServerAccount(to: fixture)
            var continuation: CheckedContinuation<Void, Never>?
            var generationCalls = 0
            let viewModel = CaptionViewModel(summaryGenerationRunner: { _ in
                generationCalls += 1
                throw CancellationError()
            }, summaryAccountSettingsLoader: { _ in
                await withCheckedContinuation { continuation = $0 }
                return accountSettings()
            })
            await fixture.select(fixture.first, in: viewModel, note: "note")
            try #require(viewModel.triggerManualSummary())
            let job = try #require(viewModel.summaryGenerationJobs.first)
            let task = try #require(job.task)
            try #require(await pollUntil { continuation != nil })
            task.cancel()
            continuation?.resume()
            await task.value
            #expect(generationCalls == 0)
            #expect(job.isFinished)
            #expect(!viewModel.isSummaryGenerating(meetingId: fixture.first.id))
        }

        private func accountSettings() -> ServerAccountSettings {
            .init(
                processing: .init(location: .local),
                summary: .init(style: .concise),
                outputLanguage: .fr,
                analysisLanguages: .init(scope: .all, identifiers: [])
            )
        }

        private func attachServerAccount(to fixture: SummaryGenerationFixture) throws -> UUID {
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://summary-routing.invalid", clientID: "test", createdAt: .now
            )
            try fixture.database.dbQueue.write { db in
                try connection.insert(db)
                try VaultRecord.filter(key: fixture.vault.id).updateAll(db, Column("accountConnectionId").set(to: connection.id))
            }
            return connection.id
        }
    }
#endif
