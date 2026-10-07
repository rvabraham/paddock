import Foundation
import Testing
@testable import PaddockCore

private final class ReplayHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private var work: DispatchWorkItem?
    static func count(_ key: Int, channel: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts.filter { $0.key.hasPrefix("\(key):") && (channel == nil || $0.key.contains(":\(channel!):")) }.values.reduce(0, +)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = components.queryItems?.first(where: { $0.name == "session_key" })?.value.flatMap(Int.init) else { return }
        let channel = url.lastPathComponent
        let start = components.queryItems?.first(where: { $0.name == "date>=" })?.value.flatMap { RaceDate.parse($0) } ?? Date(timeIntervalSince1970: 1_704_110_400)
        let identity = "\(key):\(channel):\(start.timeIntervalSince1970)"
        Self.lock.lock(); Self.counts[identity, default: 0] += 1; Self.lock.unlock()
        let job = DispatchWorkItem { [self] in
            let rows = Self.rows(channel: channel, key: key, start: start)
            guard let data = try? JSONSerialization.data(withJSONObject: rows),
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        work = job; DispatchQueue.global().asyncAfter(deadline: .now() + 0.03, execute: job)
    }
    override func stopLoading() { work?.cancel() }
    private static func rows(channel: String, key: Int, start: Date) -> [[String: Any]] {
        let base = Date(timeIntervalSince1970: 1_704_110_400)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        switch channel {
        case "sessions": return [["session_key": key, "date_start": formatter.string(from: base), "date_end": formatter.string(from: base.addingTimeInterval(601)), "session_name": "Race", "year": 2024]]
        case "drivers": return [["session_key": key, "driver_number": 1, "full_name": "Test Driver"]]
        case "laps": return [["session_key": key, "driver_number": 1, "lap_number": 1, "date_start": formatter.string(from: base), "lap_duration": 600]]
        case "location": return [0.1, 0.37].map { ["session_key": key, "driver_number": 1, "date": formatter.string(from: start.addingTimeInterval($0)), "x": 12 + $0, "y": 30, "z": 4] }
        case "car_data": return [0.1, 0.37].map { ["session_key": key, "driver_number": 1, "date": formatter.string(from: start.addingTimeInterval($0)), "speed": 230, "throttle": 80, "brake": 0, "n_gear": 6, "rpm": 10000, "drs": 12] }
        default: return []
        }
    }
}

private final class DownloadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record(_ progress: ReplayDownloadProgress) {
        if progress.phase == .downloading { lock.lock(); value = true; lock.unlock() }
    }
    var hasChunk: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct ReplayAcquisitionTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("paddock-archive-" + UUID().uuidString) }
    private func session(_ key: Int) -> SessionSummary {
        let start = Date(timeIntervalSince1970: 1_704_110_400)
        return SessionSummary(key: key, title: "Recorded test", sessionName: "Race", country: "", circuit: "Test", startsAt: start, endsAt: start.addingTimeInterval(601), year: 2024)
    }
    private func http(_ directory: URL) -> ProviderHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayHTTPStub.self]
        return ProviderHTTP(configuration: configuration, directory: directory, rateLimits: [:])
    }

    @Test func cancelledDownloadResumesValidatedChunksAndRestartsOffline() async throws {
        let folder = directory(), responses = directory(), key = Int.random(in: 100_000...999_999)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: responses) }
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        let observation = DownloadObservation()
        let task = Task { try await provider.replay(session(key), progress: { observation.record($0) }) }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !observation.hasChunk && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(observation.hasChunk)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let partial = try #require(await provider.cachedArchives().first)
        #expect(partial.availability == .partial && partial.completedChunks > 0)
        let metadataRequests = ReplayHTTPStub.count(key, channel: "laps")
        let replay = try await provider.replay(session(key))
        #expect(ReplayHTTPStub.count(key, channel: "laps") == metadataRequests)
        #expect(replay.archive.locations.count == 6 && replay.archive.telemetry.count == 6)
        #expect(replay.archive.telemetry.allSatisfy { $0.brake == false && $0.gear == 6 && $0.drs == .on })
        let complete = try #require(await provider.cachedArchives().first)
        #expect(complete.availability == .complete && complete.completedChunks == complete.totalChunks)
        let requests = ReplayHTTPStub.count(key)
        let restarted = RaceProvider(replayDirectory: folder, http: http(responses))
        let offline = try await restarted.replay(session(key))
        #expect(offline.archive.locations == replay.archive.locations)
        #expect(offline.archive.telemetry == replay.archive.telemetry)
        #expect(ReplayHTTPStub.count(key) == requests)
        try await restarted.deleteReplay(key)
        #expect(await restarted.cachedArchives().isEmpty)
    }

    @Test func updatedSessionFinishExtendsRecordedSampleCoverage() async throws {
        let folder = directory(), responses = directory(), key = Int.random(in: 2_000_000...2_999_999)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: responses) }
        var summary = session(key)
        summary.endsAt = summary.startsAt.addingTimeInterval(301)
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        let replay = try await provider.replay(summary)
        #expect(replay.session.endsAt == summary.startsAt.addingTimeInterval(601))
        #expect(replay.archive.locations.count == 6 && replay.archive.telemetry.count == 6)
        #expect(replay.archive.telemetry.last!.date > summary.endsAt!)
        let manifest = try #require(ReplayArchiveStore(directory: folder).manifest(key))
        #expect(manifest.chunks.filter { $0.channel == "location" }.last?.end == summary.startsAt.addingTimeInterval(601.001))
        #expect(manifest.complete)
    }

    @Test func replanningRetainsOnlyExactRangesAndPreservesCommittedGeneration() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        var store = ReplayArchiveStore(directory: folder)
        var summary = session(7006)
        summary.endsAt = summary.startsAt.addingTimeInterval(301)
        let first = ReplayChunk(id: "first", channel: "location", start: summary.startsAt, end: summary.startsAt.addingTimeInterval(300))
        let tail = ReplayChunk(id: "tail", channel: "location", start: first.end, end: summary.endsAt)
        var original = try store.begin(session: summary, source: "test", chunks: [first, tail])
        try store.write(Data([1]), rows: 0, format: "json", id: "first", manifest: &original)
        try store.write(Data([2]), rows: 0, format: "json", id: "tail", manifest: &original)
        try store.finish(original)
        var resumed = try store.begin(session: summary, source: "test", chunks: [first, tail])
        summary.endsAt = summary.startsAt.addingTimeInterval(601)
        let extendedTail = ReplayChunk(id: "tail", channel: "location", start: first.end, end: summary.startsAt.addingTimeInterval(600))
        let final = ReplayChunk(id: "final", channel: "location", start: extendedTail.end, end: summary.endsAt)
        try store.replan([first, extendedTail, final], session: summary, manifest: &resumed)
        #expect(resumed.chunks[0] == original.chunks[0])
        #expect(resumed.chunks[1].file != original.chunks[1].file && resumed.chunks[1].checksum == nil)
        #expect(resumed.completedChunks == 1 && resumed.session.endsAt == summary.endsAt)
        #expect(store.read(original.chunks[1], key: 7006) == Data([2]))
        #expect(store.manifest(7006)?.session.endsAt == original.session.endsAt)
        #expect(store.archives().first?.hasCommittedArchive == true)
    }

    @MainActor @Test func cancelledRefreshKeepsPreviousRecordingUsableOffline() async throws {
        let folder = directory(), responses = directory(), key = Int.random(in: 1_000_000...1_999_999)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: responses) }
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        let recorded = try await provider.replay(session(key))
        let observation = DownloadObservation()
        let refresh = Task { try await provider.replay(session(key), force: true, progress: { observation.record($0) }) }
        defer { refresh.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !observation.hasChunk && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(observation.hasChunk)
        refresh.cancel()
        await #expect(throws: CancellationError.self) { try await refresh.value }
        let info = try #require(await provider.cachedArchives().first)
        #expect(info.availability == .partial && info.hasCommittedArchive && info.canReplay && info.resumable)
        let requests = ReplayHTTPStub.count(key)
        let restarted = RaceProvider(replayDirectory: folder, http: http(responses))
        let disk = try #require(await restarted.cachedReplay(key))
        #expect(disk.archive.locations == recorded.archive.locations && disk.archive.telemetry == recorded.archive.telemetry)
        let store = RaceStore(provider: restarted)
        await store.bootstrap()
        #expect(store.mode == .replay && store.session?.key == key)
        #expect(!store.isPlaying && store.replayTime == 0)
        #expect(store.archives.first?.availability == .partial)
        #expect(ReplayHTTPStub.count(key) == requests)
        let resumed = try await restarted.replay(session(key))
        #expect(resumed.archive.locations == recorded.archive.locations)
        #expect(await restarted.cachedArchives().first?.availability == .complete)
    }

    @Test func compactSamplesPreserveMissingValuesAndSubsecondDates() throws {
        let date = Date(timeIntervalSince1970: 123456.789123)
        let positions = [RecordedCarSample(date: date, driverNumber: 44, x: 12.23456789, y: -98.7654321, z: nil)]
        let telemetry = [RecordedTelemetrySample(date: date, driverNumber: 44, speed: nil, throttle: 0, brake: false, gear: 0, rpm: nil, drs: .unknown, distance: 12.345678)]
        #expect(try ReplaySampleCodec.locations(ReplayCompression.decode(ReplayCompression.encode(ReplaySampleCodec.encode(positions)))) == positions)
        #expect(try ReplaySampleCodec.telemetry(ReplayCompression.decode(ReplayCompression.encode(ReplaySampleCodec.encode(telemetry)))) == telemetry)
        #expect(throws: ProviderError.self) { try ReplaySampleCodec.telemetry(Data([255, 255, 255, 255])) }
        var bomb = Data([80, 68, 67, 72, 1, 1, 0, 0]); bomb.append(Data(repeating: 255, count: 8))
        #expect(throws: ProviderError.self) { try ReplayCompression.decode(bomb) }
        #expect(try ReplayCompression.decode(ReplayCompression.encode(Data())).isEmpty)
        #expect(throws: ProviderError.self) { try ReplayCompression.decode(Data([80, 68, 67, 72, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) }
    }

    @Test func integrityFailureIsRejectedBeforeOfflinePublication() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        var store = ReplayArchiveStore(directory: folder)
        var manifest = try store.begin(session: session(7001), source: "test", chunks: [ReplayChunk(id: "location", channel: "location")])
        let encoded = try ReplaySampleCodec.encode([RecordedCarSample(date: session(7001).startsAt, driverNumber: 1, x: 12, y: 13)])
        try store.write(encoded, rows: 1, format: "location-v1", id: "location", manifest: &manifest)
        let chunk = try #require(manifest.chunks.first)
        #expect(store.read(chunk, key: 7001) == encoded)
        let file = folder.appendingPathComponent("7001").appendingPathComponent(chunk.file)
        var corrupted = try Data(contentsOf: file); corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: file)
        #expect(store.read(chunk, key: 7001) == nil)
        #expect(throws: ProviderError.self) { try store.finish(manifest) }
        #expect(store.manifest(7001) == nil)
    }

    @Test func malformedManifestCannotOverflowStorageAccounting() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let sessionFolder = folder.appendingPathComponent("7007")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        var first = ReplayChunk(id: "first", channel: "location")
        var second = ReplayChunk(id: "second", channel: "car_data")
        first.encodedBytes = Int.max; second.encodedBytes = Int.max
        let malformed = ReplayManifest(source: "test", session: session(7007), complete: true, chunks: [first, second])
        try JSONEncoder().encode(malformed).write(to: sessionFolder.appendingPathComponent("manifest.json"))
        let store = ReplayArchiveStore(directory: folder)
        #expect(store.manifest(7007) == nil)
        #expect(store.archives().isEmpty)
        first.format = "location-v1"; second.format = "telemetry-v1"
        first.rowCount = Int.max; second.rowCount = Int.max
        let invalidCounts = ReplayManifest(source: "test", session: session(7007), complete: true, chunks: [first, second])
        #expect(throws: ProviderError.self) { try ReplayArchivePersistence.load(invalidCounts, store: store) }
    }

    @Test func cancelledVerificationCannotCommitAnArchive() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        var store = ReplayArchiveStore(directory: folder)
        var manifest = try store.begin(session: session(7008), source: "test", chunks: [ReplayChunk(id: "data", channel: "location")])
        try store.write(Data([1, 2, 3]), rows: 0, format: "json", id: "data", manifest: &manifest)
        let savedStore = store, savedManifest = manifest
        let verification = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var cancelledStore = savedStore
            try cancelledStore.finish(savedManifest)
        }
        await #expect(throws: CancellationError.self) { try await verification.value }
        #expect(store.manifest(7008) == nil)
        #expect(store.manifest(7008, pending: true)?.completedChunks == 1)
    }

    @Test func clearDownloadsReportsUnsafeDirectoryInsteadOfSuppressingFailure() async throws {
        let folder = directory(), outside = directory(), responses = directory()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside); try? FileManager.default.removeItem(at: responses) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let recording = outside.appendingPathComponent("retained.json")
        try Data([1, 2, 3]).write(to: recording)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        await #expect(throws: ProviderError.self) { try await provider.clearCache() }
        #expect(try Data(contentsOf: recording) == Data([1, 2, 3]))
    }

    @Test func legacyMigrationIsBoundedRecentAndRetryableAfterCancellation() async throws {
        let folder = directory(), responses = directory()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: responses) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<66 {
            let key = 20_000 + index
            let raw: [String: JSONValue] = [
                "session": .array([.object(["session_key": .number(Double(key)), "date_start": .string("2024-01-01T12:00:00Z"),
                    "date_end": .string("2024-01-01T12:10:01Z"), "session_name": .string("Race"), "year": .number(2024)])]),
                "drivers": .array([.object(["driver_number": .number(1), "full_name": .string("Legacy Driver")])]),
                "laps": .array([.object(["driver_number": .number(1), "lap_number": .number(1),
                    "date_start": .string("2024-01-01T12:00:00Z"), "lap_duration": .number(60)])])]
            let url = folder.appendingPathComponent("\(key).json")
            try JSONEncoder().encode(raw).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1000))], ofItemAtPath: url.path)
        }
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.cachedArchives()
        }
        #expect(await cancelled.value.isEmpty)
        let migrated = await provider.cachedArchives()
        #expect(migrated.count == 64)
        #expect(Set(migrated.map { $0.session.key }) == Set(20_002...20_065))
        #expect(migrated.allSatisfy { $0.canReplay && $0.unavailableChannels.contains("full_location") })
        #expect((0..<66).allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(20_000 + $0).json").path) })
    }

    @Test func failedLegacyDeletionPreservesTheCompletedRecording() async throws {
        let folder = directory(), outside = directory(), responses = directory(), key = 3_000_007
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside); try? FileManager.default.removeItem(at: responses) }
        let provider = RaceProvider(replayDirectory: folder, http: http(responses))
        _ = try await provider.replay(session(key))
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("\(key).json"), withDestinationURL: outside)
        await #expect(throws: ProviderError.self) { try await provider.deleteReplay(key) }
        #expect(await provider.cachedReplay(key) != nil)
        #expect(try Data(contentsOf: outside) == Data([1, 2, 3]))
    }

    @Test func replacementChargesPreviousGenerationAgainstSessionBudget() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        var store = ReplayArchiveStore(directory: folder)
        var committed = try store.begin(session: session(7004), source: "test", chunks: [ReplayChunk(id: "data", channel: "location")])
        let original = Data([1, 2, 3])
        try store.write(original, rows: 0, format: "json", id: "data", manifest: &committed)
        try store.finish(committed)
        var replacement = try store.begin(session: session(7004), source: "test", chunks: [ReplayChunk(id: "data", channel: "location")], force: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("7004"), includingPropertiesForKeys: [.fileSizeKey])
        let existingBytes = try files.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        store.maximumSessionBytes = existingBytes + 16
        #expect(throws: ProviderError.self) { try store.write(Data([4, 5, 6]), rows: 0, format: "json", id: "data", manifest: &replacement) }
        #expect(store.read(committed.chunks[0], key: 7004) == original)
        #expect(store.manifest(7004)?.complete == true)
        #expect(replacement.completedChunks == 0)
    }

    @Test func typedPayloadBudgetRejectsBeforeReadingOrAllocatingSamples() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = ReplayArchiveStore(directory: folder)
        var locations = ReplayChunk(id: "location", channel: "location")
        locations.rowCount = ReplayArchiveStore.maximumSamples; locations.format = "location-v1"
        var telemetry = ReplayChunk(id: "telemetry", channel: "car_data")
        telemetry.rowCount = ReplayArchiveStore.maximumSamples; telemetry.format = "telemetry-v1"
        let manifest = ReplayManifest(source: "test", session: session(7005), complete: true, chunks: [locations, telemetry])
        do {
            _ = try ReplayArchivePersistence.load(manifest, store: store)
            Issue.record("Accepted a recording exceeding the aggregate payload budget")
        } catch {
            #expect(error.localizedDescription.contains("memory budget"))
        }
        try ReplayArchivePersistence.validateSampleBudget(locationCount: 1, telemetryCount: 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func storageAndSymlinkBoundsProtectExistingArchives() throws {
        let folder = directory(), outside = directory()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        var store = ReplayArchiveStore(directory: folder)
        var manifest = try store.begin(session: session(7002), source: "test", chunks: [ReplayChunk(id: "data", channel: "location")])
        store.maximumSessionBytes = 1
        #expect(throws: ProviderError.self) { try store.write(Data([1, 2, 3]), rows: 0, format: "json", id: "data", manifest: &manifest) }
        #expect(manifest.completedChunks == 0)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("7003"), withDestinationURL: outside)
        #expect(throws: ProviderError.self) { try store.begin(session: session(7003), source: "test", chunks: [ReplayChunk(id: "data", channel: "location")]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
