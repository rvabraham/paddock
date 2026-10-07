import Foundation

actor RaceProvider {
    private let http: ProviderHTTP
    private var archives: ReplayArchiveStore
    private let legacyCache: DiskCache
    private var migratedLegacy = false
    private var requestEpochs: [Int: UUID] = [:]
    private var pending: [Int: ReplayManifest] = [:]

    init(replayDirectory: URL? = nil, http: ProviderHTTP = ProviderHTTP()) {
        self.http = http
        let directory = replayDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Paddock/Replays", isDirectory: true)
        archives = ReplayArchiveStore(directory: directory)
        let oldDirectory = replayDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Paddock/Replays", isDirectory: true)
        legacyCache = DiskCache(directory: oldDirectory, maximumBytes: 512 * 1024 * 1024, maximumEntries: 65, maximumEntryBytes: 64 * 1024 * 1024)
    }
    func sessions(year: Int, force: Bool = false) async throws -> [SessionSummary] {
        guard (2018...2100).contains(year) else { throw ProviderError.invalidData("Replay data starts with the 2018 season.") }
        if year < 2023 { return try await HistoricalReplayProvider.sessions(year: year, http: http, force: force) }
        let values = try await http.request(URL(string: "https://api.openf1.org/v1/sessions?year=\(year)")!, maxAge: force ? 0 : 3600) {
            try ProviderDecoders.sessions($0, year: year)
        }
        let meetings = try? await http.request(URL(string: "https://api.openf1.org/v1/meetings?year=\(year)")!, maxAge: force ? 0 : 21600)
        try Task.checkCancellation()
        let titles = Dictionary((meetings?.array ?? []).compactMap { row -> (Int, String)? in
            guard let key = row["meeting_key"].int, let name = row["meeting_name"].string else { return nil }; return (key, name)
        }, uniquingKeysWith: { first, _ in first })
        return values.map { value in
            var session = value.session
            if let key = value.meetingKey, let title = titles[key] { session.title = title }
            return session
        }.sorted { $0.startsAt > $1.startsAt }
    }
    func calendar(year: Int, force: Bool = false) async throws -> [RaceWeekend] {
        try await http.request(URL(string: "https://api.jolpi.ca/ergast/f1/\(year).json?limit=100")!, maxAge: force ? 0 : 21600) {
            try ProviderDecoders.calendar($0, year: year)
        }
    }
    func standings(year: Int, constructors: Bool, force: Bool = false) async throws -> (rows: [Standing], round: Int?) {
        let kind = constructors ? "constructorStandings" : "driverStandings"
        return try await http.request(URL(string: "https://api.jolpi.ca/ergast/f1/\(year)/\(kind).json?limit=100")!, maxAge: force ? 0 : 3600) {
            try ProviderDecoders.standings($0, constructors: constructors, year: year)
        }
    }
    func replay(_ session: SessionSummary, force: Bool = false, progress: @escaping @Sendable (ReplayDownloadProgress) -> Void = { _ in }) async throws -> ReplayDataset {
        try Task.checkCancellation()
        migrateLegacy()
        guard session.key > 0 else { throw ProviderError.invalidData("This session has no valid archive identifier.") }
        if !force, archives.manifest(session.key, pending: true) == nil,
           let manifest = archives.manifest(session.key), let dataset = try? ReplayArchivePersistence.load(manifest, store: archives) {
            progress(Self.progress(manifest, phase: .complete, detail: "Ready offline", resuming: false))
            return dataset
        }
        guard let end = session.endsAt, end.addingTimeInterval(1800) < Date() else {
            throw ProviderError.invalidData("This session is not in the free historical archive yet. Try again 30 minutes after it finishes.")
        }
        if pending[session.key] != nil { throw ProviderError.invalidData("This session is already downloading.") }
        let generation = UUID()
        requestEpochs[session.key] = generation
        defer {
            if requestEpochs[session.key] == generation { pending[session.key] = nil; requestEpochs[session.key] = nil }
        }
        if session.year < 2023 || session.isQualifying {
            return try await historicalReplay(session, force: force, generation: generation, progress: progress)
        }
        return try await openF1Replay(session, force: force, generation: generation, progress: progress)
    }
    func cachedArchives() -> [ReplayArchiveInfo] { migrateLegacy(); return archives.archives() }
    func cachedReplay(_ key: Int) -> ReplayDataset? {
        migrateLegacy()
        guard let manifest = archives.manifest(key) else { return nil }
        return try? ReplayArchivePersistence.load(manifest, store: archives)
    }
    func cachedKeys() -> Set<Int> { Set(cachedSessions().map(\.key)) }
    func cachedSessions() -> [SessionSummary] { cachedArchives().filter(\.canReplay).map(\.session) }
    func deleteReplay(_ key: Int) async throws {
        guard key > 0 else { throw ProviderError.invalidData("This session has no valid archive identifier.") }
        requestEpochs[key] = nil; pending[key] = nil
        try legacyCache.remove("\(key).json")
        try archives.delete(key)
        migratedLegacy = false
    }
    func clearCache() async throws {
        requestEpochs.removeAll(); pending.removeAll()
        try legacyCache.clear(); try archives.clear()
        await http.clear()
    }
    private func migrateLegacy() {
        guard !migratedLegacy, !Task.isCancelled,
              var slots = try? archives.remainingSessionSlots() else { return }
        defer { migratedLegacy = !Task.isCancelled }
        guard slots > 0 else { return }
        let entries = legacyCache.entries().filter {
            guard let key = Int($0.url.deletingPathExtension().lastPathComponent), key > 0 else { return false }
            return archives.manifest(key) == nil
        }.sorted { ($0.modified, $0.url.lastPathComponent) > ($1.modified, $1.url.lastPathComponent) }
        for entry in entries.prefix(legacyCache.maximumEntries) {
            guard !Task.isCancelled, slots > 0 else { return }
            guard let key = Int(entry.url.deletingPathExtension().lastPathComponent),
                  let data = legacyCache.read(entry.url.lastPathComponent),
                  let raw = try? JSONValue.decode(data).object, var dataset = try? ReplayDataset(raw: raw), dataset.session.key == key else { continue }
            if let summary = raw["summary"], let encoded = try? JSONEncoder().encode(summary), let saved = try? JSONDecoder().decode(SessionSummary.self, from: encoded), saved.key == key { dataset.session.title = saved.title }
            do {
                var manifest = try archives.begin(session: dataset.session, source: "legacy-openf1", chunks: [ReplayChunk(id: "archive", channel: "metadata")])
                manifest.unavailableChannels = ["full_location", "car_data"]
                try ReplayArchivePersistence.save(dataset.archive, manifest: &manifest, store: &archives)
                try archives.finish(manifest)
                slots -= 1
            } catch { continue }
        }
    }
    private func checkGeneration(_ generation: UUID, key: Int) throws {
        try Task.checkCancellation()
        guard generation == requestEpochs[key] else { throw CancellationError() }
    }
    private static func progress(_ manifest: ReplayManifest, phase: ReplayDownloadPhase, detail: String, resuming: Bool) -> ReplayDownloadProgress {
        ReplayDownloadProgress(phase: phase, completedChunks: manifest.completedChunks, totalChunks: manifest.chunks.count,
            downloadedBytes: manifest.bytes, detail: detail, isResuming: resuming)
    }
}

private extension RaceProvider {
    static let historicalTopics = ["ExtrapolatedClock", "DriverList", "SessionStatus", "TrackStatus", "TimingData", "TimingAppData", "RaceControlMessages", "WeatherData", "Position.z", "CarData.z"]
    static let openF1Metadata = ["session", "drivers", "laps", "position", "intervals", "stints", "race_control", "weather", "pit"]

    func historicalReplay(_ session: SessionSummary, force: Bool, generation: UUID, progress: @escaping @Sendable (ReplayDownloadProgress) -> Void) async throws -> ReplayDataset {
        let plans = Self.historicalTopics.map { ReplayChunk(id: $0, channel: $0) }
        let manifest = try archives.begin(session: session, source: "f1-static", chunks: plans, force: force)
        let resuming = manifest.completedChunks > 0
        pending[session.key] = manifest
        progress(Self.progress(manifest, phase: .metadata, detail: resuming ? "Resuming recorded session" : "Downloading recorded session", resuming: resuming))
        let archive = try await HistoricalReplayProvider.replay(session, http: http, progress: { progress($0) },
            loadCheckpoint: { [self] id in try await historicalCheckpoint(session.key, id: id, generation: generation) },
            saveCheckpoint: { [self] id, data in try await saveHistoricalCheckpoint(session.key, id: id, data: data, generation: generation) })
        try checkGeneration(generation, key: session.key)
        guard var completed = pending[session.key] else { throw CancellationError() }
        try ReplayArchivePersistence.save(archive, manifest: &completed, store: &archives)
        let typed = completed.chunks.filter { !Self.historicalTopics.contains($0.id) }
        completed.chunks = typed
        completed.complete = true
        progress(Self.progress(completed, phase: .verifying, detail: "Verifying offline archive", resuming: resuming))
        let dataset = try ReplayArchivePersistence.load(completed, store: archives)
        try checkGeneration(generation, key: session.key)
        try archives.finish(completed)
        progress(Self.progress(completed, phase: .complete, detail: "Ready offline", resuming: resuming))
        return dataset
    }
    func historicalCheckpoint(_ key: Int, id: String, generation: UUID) throws -> Data? {
        try checkGeneration(generation, key: key)
        guard Self.historicalTopics.contains(id) else { throw ProviderError.invalidData("Unsupported historical archive topic.") }
        return archives.checkpoint(key, id: id)
    }
    func saveHistoricalCheckpoint(_ key: Int, id: String, data: Data, generation: UUID) throws {
        try checkGeneration(generation, key: key)
        guard var manifest = pending[key], Self.historicalTopics.contains(id) else { throw CancellationError() }
        try archives.write(data, rows: 0, format: "historical-jsonstream", id: id, manifest: &manifest)
        pending[key] = manifest
    }

    func openF1Replay(_ session: SessionSummary, force: Bool, generation: UUID, progress: @escaping @Sendable (ReplayDownloadProgress) -> Void) async throws -> ReplayDataset {
        let saved = force ? nil : archives.manifest(session.key, pending: true) ?? archives.manifest(session.key)
        let plannedSession = saved.flatMap { $0.source == "openf1" ? $0.session : nil } ?? session
        var plans = try Self.openF1Plans(plannedSession)
        var manifest = try archives.begin(session: plannedSession, source: "openf1", chunks: plans, force: force)
        let resuming = manifest.completedChunks > 0
        pending[session.key] = manifest
        progress(Self.progress(manifest, phase: .metadata, detail: resuming ? "Resuming saved chunks" : "Downloading session details", resuming: resuming))
        var raw: [String: JSONValue] = [:], metadataBytes = 0
        for channel in Self.openF1Metadata {
            try checkGeneration(generation, key: session.key)
            let id = "raw-" + channel
            let chunk = manifest.chunks.first { $0.id == id }!
            let saved = archives.read(chunk, key: session.key)
            let data: Data
            if let saved { data = saved }
            else { data = try await http.bytes(Self.openF1URL(channel: channel == "session" ? "sessions" : channel, session: session.key), maxAge: 0, cacheResponse: false) }
            try checkGeneration(generation, key: session.key)
            metadataBytes += data.count
            guard metadataBytes <= 32 * 1024 * 1024, case .array(let rows) = try JSONValue.decode(data),
                  rows.allSatisfy({ $0["session_key"].int == session.key }) else {
                throw ProviderError.invalidData("The provider returned invalid or oversized session details.")
            }
            raw[channel] = .array(rows)
            if saved == nil { try archives.write(data, rows: rows.count, format: "json", id: id, manifest: &manifest) }
            pending[session.key] = manifest
            progress(Self.progress(manifest, phase: .metadata, detail: "Session details: \(channel.replacingOccurrences(of: "_", with: " "))", resuming: resuming))
        }
        var metadata = try ReplayDataset(raw: raw, fallback: session).archive
        guard metadata.session.key == session.key else { throw ProviderError.invalidData("The provider returned another session.") }
        guard let end = metadata.session.endsAt, end.addingTimeInterval(1800) < Date() else {
            throw ProviderError.invalidData("The provider has updated this session's finish time. Its free historical data is not available yet.")
        }
        metadata.session.title = session.title
        metadata.locations = []; metadata.telemetry = []
        plans = try Self.openF1Plans(metadata.session)
        try archives.replan(plans, session: metadata.session, manifest: &manifest)
        ReplayArchivePersistence.noteUnavailableChannels(metadata, manifest: &manifest)
        raw.removeAll()
        try archives.write(JSONEncoder().encode(metadata), rows: metadata.laps.count, format: "archive-v1", id: "archive", manifest: &manifest)
        for plan in plans where plan.start != nil {
            try checkGeneration(generation, key: session.key)
            let chunk = manifest.chunks.first { $0.id == plan.id }!
            if archives.read(chunk, key: session.key) != nil { continue }
            let start = plan.start!, end = plan.end!
            let data = try await http.bytes(Self.openF1URL(channel: plan.channel, session: session.key, start: start, end: end), maxAge: 0, cacheResponse: false)
            try checkGeneration(generation, key: session.key)
            guard case .array(let rows) = try JSONValue.decode(data) else { throw ProviderError.invalidData("The provider returned invalid recorded samples.") }
            let encoded: Data, count: Int, format: String
            if plan.channel == "location" {
                let samples = try ReplaySampleCodec.locations(rows, session: session, start: start, end: end)
                encoded = try ReplaySampleCodec.encode(samples); count = samples.count; format = "location-v1"
            } else {
                let samples = try ReplaySampleCodec.telemetry(rows, session: session, start: start, end: end)
                encoded = try ReplaySampleCodec.encode(samples); count = samples.count; format = "telemetry-v1"
            }
            let locationCount = manifest.chunks.filter { $0.format == "location-v1" && $0.id != plan.id }.reduce(0) { $0 + $1.rowCount }
            let telemetryCount = manifest.chunks.filter { $0.format == "telemetry-v1" && $0.id != plan.id }.reduce(0) { $0 + $1.rowCount }
            try ReplayArchivePersistence.validateSampleBudget(locationCount: locationCount + (format == "location-v1" ? count : 0),
                telemetryCount: telemetryCount + (format == "telemetry-v1" ? count : 0))
            try archives.write(encoded, rows: count, format: format, id: plan.id, manifest: &manifest)
            pending[session.key] = manifest
            progress(Self.progress(manifest, phase: .downloading, detail: "Recorded \(plan.channel == "location" ? "coordinates" : "telemetry")", resuming: resuming))
        }
        for channel in ["location", "car_data"] where manifest.chunks.filter({ $0.channel == channel }).allSatisfy({ $0.rowCount == 0 }) {
            manifest.unavailableChannels.append(channel)
        }
        try checkGeneration(generation, key: session.key)
        manifest.complete = true
        progress(Self.progress(manifest, phase: .verifying, detail: "Verifying offline archive", resuming: resuming))
        let dataset = try ReplayArchivePersistence.load(manifest, store: archives)
        try checkGeneration(generation, key: session.key)
        try archives.finish(manifest)
        progress(Self.progress(manifest, phase: .complete, detail: "Ready offline", resuming: resuming))
        return dataset
    }
    static func openF1Plans(_ session: SessionSummary) throws -> [ReplayChunk] {
        guard let end = session.endsAt, end > session.startsAt, end.timeIntervalSince(session.startsAt) <= 8 * 3600 else {
            throw ProviderError.invalidData("This recorded session has an unsupported time range.")
        }
        let limit = end.addingTimeInterval(0.001)
        var plans = openF1Metadata.map { ReplayChunk(id: "raw-" + $0, channel: $0) }
        var start = session.startsAt, index = 0
        while start < limit {
            let finish = min(start.addingTimeInterval(300), limit)
            plans.append(ReplayChunk(id: "location-window-\(index)", channel: "location", start: start, end: finish))
            plans.append(ReplayChunk(id: "telemetry-window-\(index)", channel: "car_data", start: start, end: finish))
            start = finish; index += 1
        }
        plans.append(ReplayChunk(id: "archive", channel: "metadata"))
        return plans
    }
    static func openF1URL(channel: String, session: Int, start: Date? = nil, end: Date? = nil) -> URL {
        var components = URLComponents(string: "https://api.openf1.org/v1/\(channel)")!
        components.queryItems = [URLQueryItem(name: "session_key", value: String(session))]
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let start { components.queryItems?.append(URLQueryItem(name: "date>=", value: formatter.string(from: start))) }
        if let end { components.queryItems?.append(URLQueryItem(name: "date<", value: formatter.string(from: end))) }
        return components.url!
    }
}
