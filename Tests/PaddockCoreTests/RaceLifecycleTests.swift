import Foundation
import Testing

@testable import PaddockCore

@Suite(.serialized) struct RaceLifecycleTests {
    @Test @MainActor func freshStartupRemainsEmptyAndIdle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(provider: RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        await store.bootstrap()
        await store.bootstrap()
        #expect(store.mode == .idle)
        #expect(store.session == nil)
        #expect(store.sessions.isEmpty && store.archives.isEmpty && store.cachedSessionKeys.isEmpty)
        #expect(store.calendar.isEmpty && store.driverStandings.isEmpty && store.constructorStandings.isEmpty)
        #expect(store.drivers.isEmpty && store.messages.isEmpty && store.trackOutline.isEmpty && store.replayEvents.isEmpty)
        #expect(store.weather == nil && store.standingsRound == nil)
        #expect(store.errorMessage == nil && store.sessionsError == nil && store.calendarError == nil && store.standingsError == nil)
        #expect(!store.isLoading && !store.isPlaying && !store.replayClock.isAdvancing)
        #expect(store.dataSourceLabel == "No replay loaded")
    }

    @Test @MainActor func startupRestoresOnlyASuccessfullyInstalledCompletedReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PaddockTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let earlier = try ReplayTestFixtures.saveRecording(7006, directory: directory)
        let provider = RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses")))
        let original = RaceStore(provider: provider, preferences: preferences)
        await original.bootstrap()
        #expect(original.session?.key == earlier.key)
        let saved = try ReplayTestFixtures.saveRecording(7007, directory: directory)
        await original.loadSession(saved)
        #expect(preferences.integer(forKey: "lastReplaySessionKey") == saved.key)
        _ = try ReplayTestFixtures.saveRecording(7008, directory: directory)
        let restarted = RaceStore(provider: provider, preferences: preferences)
        await restarted.bootstrap()
        #expect(restarted.session?.key == saved.key)
        #expect(restarted.dataSourceLabel == "Downloaded recorded session")
        #expect(restarted.calendar.isEmpty && restarted.driverStandings.isEmpty && restarted.constructorStandings.isEmpty)
        #expect(restarted.replayTime == 0)
        #expect(!restarted.isPlaying && !restarted.replayClock.isAdvancing)
    }

    @Test @MainActor func startupFallsBackToMostRecentReadableSavedReplay() async throws {
        for invalidRecording in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "PaddockTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            if invalidRecording { _ = try ReplayTestFixtures.saveRecording(7007, directory: directory, valid: false) }
            _ = try ReplayTestFixtures.saveRecording(7008, directory: directory, updatedAt: Date(timeIntervalSince1970: 100))
            _ = try ReplayTestFixtures.saveRecording(7009, directory: directory, updatedAt: Date(timeIntervalSince1970: 200))
            _ = try ReplayTestFixtures.saveRecording(7010, directory: directory, valid: false, updatedAt: Date(timeIntervalSince1970: 300))
            preferences.set(7007, forKey: "lastReplaySessionKey")
            let store = RaceStore(
                provider: RaceProvider(
                    replayDirectory: directory,
                    http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))),
                preferences: preferences)
            await store.bootstrap()
            #expect(store.session?.key == 7009)
            #expect(store.mode == .replay && !store.isPlaying)
            #expect(store.errorMessage == nil)
            #expect(preferences.integer(forKey: "lastReplaySessionKey") == 7009)
            if invalidRecording {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("7007/manifest.json").path))
            }
        }
    }

    @Test @MainActor func startupWithNoReadableSavedReplayRemainsIdle() async throws {
        for invalidRecording in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "PaddockTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            if invalidRecording { _ = try ReplayTestFixtures.saveRecording(7007, directory: directory, valid: false) }
            preferences.set(7007, forKey: "lastReplaySessionKey")
            let store = RaceStore(provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))), preferences: preferences)
            await store.bootstrap()
            #expect(store.session == nil && store.mode == .idle && store.drivers.isEmpty)
            #expect(store.errorMessage == nil && !store.isLoading)
            #expect(preferences.integer(forKey: "lastReplaySessionKey") == 0)
        }
    }

    @Test @MainActor func cancellingStartupPreventsLateSavedReplayInstallation() async throws {
        for cancelTask in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let saved = try ReplayTestFixtures.saveRecording(directory: directory)
            let suite = "PaddockTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            preferences.set(saved.key, forKey: "lastReplaySessionKey")
            let provider = RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses")))
            let gate = StartupGate()
            let holding = Task.detached { await provider.holdForStartupTest(gate) }
            defer { gate.release() }
            let deadline = Date().addingTimeInterval(5)
            while !gate.isWaiting && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(gate.isWaiting)
            let store = RaceStore(provider: provider, preferences: preferences)
            let opening = Task { await store.bootstrap() }
            while !store.isLoading && Date() < deadline { await Task.yield() }
            try #require(store.isLoading)
            if cancelTask { opening.cancel() } else { store.cancelLoading() }
            gate.release()
            await holding.value
            await opening.value
            #expect(store.session == nil && store.mode == .idle && store.drivers.isEmpty)
            #expect(!store.isLoading && store.errorMessage == nil)
            #expect(preferences.integer(forKey: "lastReplaySessionKey") == saved.key)
            await store.loadSession(saved)
            #expect(store.session?.key == saved.key && store.mode == .replay)
        }
    }

    @Test @MainActor func openingAnotherSavedSessionSupersedesStartupRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remembered = try ReplayTestFixtures.saveRecording(7007, directory: directory)
        let selected = try ReplayTestFixtures.saveRecording(7008, directory: directory)
        let suite = "PaddockTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(remembered.key, forKey: "lastReplaySessionKey")
        let provider = RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses")))
        let gate = StartupGate()
        let holding = Task.detached { await provider.holdForStartupTest(gate) }
        defer { gate.release() }
        let deadline = Date().addingTimeInterval(5)
        while !gate.isWaiting && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.isWaiting)
        let store = RaceStore(provider: provider, preferences: preferences)
        let opening = Task { await store.bootstrap() }
        while !store.isLoading && Date() < deadline { await Task.yield() }
        try #require(store.isLoading)
        let selecting = Task { await store.loadSession(selected) }
        while store.loadingLabel != "Opening \(selected.title) · \(selected.sessionName)" && Date() < deadline {
            await Task.yield()
        }
        try #require(store.loadingLabel == "Opening \(selected.title) · \(selected.sessionName)")
        gate.release()
        await holding.value
        await opening.value
        await selecting.value
        #expect(store.session?.key == selected.key)
        #expect(preferences.integer(forKey: "lastReplaySessionKey") == selected.key)
        #expect(!store.isLoading && store.errorMessage == nil)
    }

    @Test @MainActor func failedClearDownloadsReportsErrorAndReloadsRetainedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try ReplayTestFixtures.saveRecording(7007, directory: directory)
        let sessionDirectory = directory.appendingPathComponent("7007")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = RaceStore(provider: RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        await store.bootstrap()
        #expect(store.cachedSessionKeys.contains(session.key))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionDirectory.path)
        await store.clearCache()
        #expect(store.sessionsError != nil)
        #expect(store.cachedSessionKeys.contains(session.key))
        #expect(store.archives.contains { $0.id == session.key && $0.canReplay })
    }

    @Test @MainActor func replayPlaybackSuspendsWhenCoverageOrAppIsInactive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        store.setReplayTime(100)
        store.playbackRate = 1
        #expect(!store.isPlaying)
        let paused = store.replayTime
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.replayTime == paused)

        store.togglePlayback()
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.replayTime > paused)
        store.setCoverageVisible(false)
        let hidden = store.replayTime
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.replayTime == hidden)
        #expect(store.isPlaying)

        store.setAppActive(false)
        store.setCoverageVisible(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.replayTime == hidden)
        store.setAppActive(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.replayTime > hidden)
        store.setReplayTime(store.replayDuration)
        #expect(!store.isPlaying)
    }

    @Test @MainActor func cancelledSavedLoadCannotInstallAReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        let original = try #require(store.session)
        store.setReplayTime(200)
        let loading = Task {
            try? await Task.sleep(for: .milliseconds(100))
            await store.loadSession(original)
        }
        loading.cancel()
        await loading.value
        #expect(store.replayTime == 200)
        #expect(!store.isLoading)
    }

    @Test @MainActor func aReadyTickerCannotAdvanceAfterCoverageHides() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        store.setReplayTime(100)
        store.playbackRate = 1
        store.togglePlayback()
        for _ in 0..<5 { await Task.yield() }
        blockCurrentThread(for: 0.4)
        store.setCoverageVisible(false)
        let beforeHiding = store.replayTime
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.replayTime == beforeHiding)
    }
    private func blockCurrentThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test @MainActor func lapNavigationUsesTheAdvancingCursorBetweenTimingTicks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses")))
        let store = RaceStore(provider: provider)
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        let replay = try ReplayTestFixtures.replay()
        let starts = replay.recordedLaps(for: 16).map(\.startedAt)
        let pair = try #require(zip(starts, starts.dropFirst()).first {
            $1.timeIntervalSince($0) > 60 && $0 > replay.session.startsAt.addingTimeInterval(300)
        })
        store.selectedDriverNumber = 16
        store.setReplayTime(pair.0.timeIntervalSince(replay.session.startsAt) - 1)
        store.playbackRate = 256
        store.togglePlayback()
        blockCurrentThread(for: 0.1)
        #expect(store.replayClock.sessionDate(at: Date()) > pair.0)
        store.skipLap(1)
        #expect(store.replayDate == pair.1)
        store.pauseReplay()
    }

    @Test @MainActor func invalidPlaybackRatesAreClamped() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        store.playbackRate = .infinity
        #expect(store.playbackRate == 1)
        store.playbackRate = .nan
        #expect(store.playbackRate == 1)
        store.playbackRate = 1e30
        #expect(store.playbackRate == 256)
        store.playbackRate = -1e30
        #expect(store.playbackRate == 0.1)
        store.playbackRate = 0.25
        #expect(store.playbackRate == 0.25)
    }

    @Test @MainActor func replayControlsSeekAllChannelsAndClampNudges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        let session = try #require(store.session)
        let lap = try #require(store.recordedLaps(for: 16).first)
        store.seekLap(lap.lap, driver: 16)
        #expect(store.replayDate == max(session.startsAt, lap.startedAt))
        #expect(store.lapHistory(for: 16).allSatisfy { $0.date <= store.replayDate! })
        let event = try #require(store.replayEvents.last)
        store.seekEvent(event)
        #expect(store.replayDate == event.date)
        store.restartReplay()
        #expect(store.replayTime == 0)
        store.nudgeReplay(-100)
        #expect(store.replayTime == 0)
        store.nudgeReplay(1e20)
        #expect(store.replayTime == store.replayDuration)
        store.setReplayTime(.infinity)
        #expect(store.replayTime == store.replayDuration)
        store.comparisonDriverNumbers = Set(store.drivers.prefix(8).map(\.id) + [999])
        #expect(store.comparisonDriverNumbers.count == 6)
        #expect(!store.comparisonDriverNumbers.contains(999))
    }

    @Test @MainActor func renderClockStopsImmediatelyAndRateChangesStayContinuous() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RaceStore(
            provider: RaceProvider(
                replayDirectory: directory,
                http: ProviderHTTP(directory: directory.appendingPathComponent("Responses"))))
        try ReplayTestFixtures.saveRecording(directory: directory)
        await store.bootstrap()
        store.setReplayTime(100)
        store.playbackRate = 0.5
        store.togglePlayback()
        #expect(store.replayClock.isAdvancing)
        try await Task.sleep(for: .milliseconds(100))
        let beforeRate = store.replayClock.time(at: Date())
        store.playbackRate = 2
        let afterRate = store.replayClock.time(at: Date())
        #expect(abs(afterRate - beforeRate) < 0.01)
        store.setCoverageVisible(false)
        #expect(!store.replayClock.isAdvancing)
        let hidden = store.replayTime
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.replayClock.time(at: Date()) == hidden)
        store.setCoverageVisible(true)
        #expect(store.replayClock.isAdvancing)
        store.pauseReplay()
        #expect(!store.replayClock.isAdvancing)
        #expect(!store.isPlaying)
    }
}

private final class StartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var waiting = false
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func wait() {
        lock.lock(); waiting = true; lock.unlock()
        _ = signal.wait(timeout: .now() + 5)
    }
    func release() { signal.signal() }
}

private extension RaceProvider {
    func holdForStartupTest(_ gate: StartupGate) { gate.wait() }
}
