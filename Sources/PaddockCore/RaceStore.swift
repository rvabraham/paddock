import Foundation
import Observation

@MainActor @Observable public final class RaceStore {
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var calendar: [RaceWeekend] = []
    public private(set) var driverStandings: [Standing] = []
    public private(set) var constructorStandings: [Standing] = []
    public private(set) var standingsYear = 2026
    public private(set) var standingsRound: Int?
    public private(set) var session: SessionSummary?
    public private(set) var drivers: [DriverState] = []
    public private(set) var messages: [ControlMessage] = []
    public private(set) var weather: WeatherInfo?
    public private(set) var trackStatus = "Recorded session"
    public private(set) var sessionStatus: String?
    public private(set) var qualifyingPhase: QualifyingPhase?
    public private(set) var replayTime: Double = 0
    public private(set) var replayDuration: Double = 1
    public private(set) var replayClock = ReplayClock(
        sessionStart: Date(timeIntervalSince1970: 0), duration: 1, anchorTime: 0, anchorDate: Date(), rate: 1,
        isAdvancing: false)
    public private(set) var isPlaying = false
    public var playbackRate: Double = 1 {
        didSet {
            let valid = playbackRate.isFinite ? min(256, max(0.1, playbackRate)) : 1
            if playbackRate != valid { playbackRate = valid }
            guard playbackRate != oldValue else { return }
            synchronizeTime(rate: oldValue.isFinite ? min(256, max(0.1, oldValue)) : 1)
            updateReplay()
            resetClock()
        }
    }
    public private(set) var mode: CoverageMode = .idle
    public private(set) var connectionState = "No replay loaded"
    public private(set) var isLoading = false
    public private(set) var isCalendarLoading = false
    public private(set) var isStandingsLoading = false
    public private(set) var isSessionsLoading = false
    public private(set) var loadingLabel = "Opening recorded session"
    public private(set) var downloadProgress: ReplayDownloadProgress?
    public private(set) var archives: [ReplayArchiveInfo] = []
    public var errorMessage: String?
    public private(set) var sessionsError: String?
    public private(set) var calendarError: String?
    public private(set) var standingsError: String?
    public var selectedDriverNumber: Int?
    public var comparisonDriverNumbers: Set<Int> = [] {
        didSet {
            let allowed = Set(drivers.map(\.id))
            let valid = Set(comparisonDriverNumbers.intersection(allowed).sorted().prefix(6))
            if valid != comparisonDriverNumbers { comparisonDriverNumbers = valid }
        }
    }
    public private(set) var trackOutline: [TrackPoint] = []
    public private(set) var replayEvents: [ReplayEvent] = []
    public private(set) var channelAvailability = ReplayChannelAvailability(
        coordinates: false, telemetry: false, pitIntervals: false, driverStatuses: false,
        qualifyingPhases: false)
    public private(set) var cachedSessionKeys: Set<Int> = []
    public private(set) var dataSourceLabel = "No replay loaded"
    public var replayDate: Date? { session?.startsAt.addingTimeInterval(replayTime) }
    public var currentLap: Int { drivers.reduce(0) { max($0, $1.lap) } }

    @ObservationIgnored private let provider: RaceProvider
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private var replay: ReplayDataset?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<ReplayDataset, Error>?
    @ObservationIgnored private var lastTick = ContinuousClock.now
    @ObservationIgnored private var isCoverageVisible = true
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var cacheGeneration = UUID()
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var sessionsRequestID = UUID()
    @ObservationIgnored private var calendarRequestID = UUID()
    @ObservationIgnored private var standingsRequestID = UUID()

    public convenience init() { self.init(provider: RaceProvider(), preferences: .standard) }
    init(provider: RaceProvider, preferences: UserDefaults? = nil) {
        self.provider = provider
        self.preferences = preferences
    }
    deinit {
        ticker?.cancel()
        loadTask?.cancel()
    }

    public func bootstrap() async {
        guard !bootstrapped, !Task.isCancelled else { return }
        let initialRequest = requestID
        let initialSessionsRequest = sessionsRequestID
        let cacheID = cacheGeneration
        bootstrapped = true
        isLoading = true
        loadingLabel = "Opening saved replay"
        defer { if requestID == initialRequest { isLoading = false } }
        let savedArchives = await provider.cachedArchives()
        if cacheGeneration == cacheID {
            archives = savedArchives
            cachedSessionKeys = Set(
                savedArchives.filter(\.canReplay).map { $0.session.key })
            if sessionsRequestID == initialSessionsRequest {
                sessions = Self.mergedSessions(
                    preferred: sessions, saved: savedArchives.filter(\.canReplay).map(\.session))
            }
        }
        let remembered = preferences?.integer(forKey: "lastReplaySessionKey") ?? 0
        let candidates = savedArchives.filter(\.canReplay).sorted {
            if ($0.id == remembered) != ($1.id == remembered) { return $0.id == remembered }
            return ($0.updatedAt, $0.session.startsAt, $0.id) > ($1.updatedAt, $1.session.startsAt, $1.id)
        }
        for saved in candidates {
            guard !Task.isCancelled, requestID == initialRequest, cacheGeneration == cacheID,
                mode == .idle else { return }
            loadingLabel = "Opening \(saved.session.title) · \(saved.session.sessionName)"
            let dataset = await provider.cachedReplay(saved.id)
            guard !Task.isCancelled, requestID == initialRequest, cacheGeneration == cacheID,
                mode == .idle else { return }
            if let dataset {
                installReplay(dataset)
                selectedDriverNumber = drivers.first?.id
                return
            }
        }
        if !Task.isCancelled, requestID == initialRequest, cacheGeneration == cacheID,
            mode == .idle, remembered > 0 {
            preferences?.removeObject(forKey: "lastReplaySessionKey")
        }
    }

    public func loadSession(_ summary: SessionSummary) async {
        await openSession(summary, forceDownload: false, refresh: false)
    }
    public func downloadSession(_ summary: SessionSummary, force: Bool = false) async {
        await openSession(summary, forceDownload: true, refresh: force)
    }
    private func openSession(_ summary: SessionSummary, forceDownload: Bool, refresh: Bool) async {
        guard !Task.isCancelled else { return }
        loadTask?.cancel()
        let id = UUID()
        requestID = id
        pauseReplay()
        isLoading = true
        errorMessage = nil
        downloadProgress = nil
        loadingLabel = "Opening \(summary.title) · \(summary.sessionName)"
        do {
            let forceUpgrade =
                forceDownload
                && archives.first(where: { $0.id == summary.key })?
                    .unavailableChannels.contains("full_location") == true
            let updateProgress: @Sendable (ReplayDownloadProgress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == id, self.isLoading else { return }
                    self.downloadProgress = progress
                    self.loadingLabel = progress.detail
                }
            }
            let task = Task { [provider] in
                if !forceDownload {
                    let committed = await provider.cachedReplay(summary.key)
                    try Task.checkCancellation()
                    if let committed { return committed }
                }
                let dataset = try await provider.replay(
                    summary, force: refresh || forceUpgrade, progress: updateProgress)
                return dataset
            }
            loadTask = task
            let result = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard requestID == id else { return }
            installReplay(result)
            selectedDriverNumber = drivers.first?.id
            await refreshArchives(request: id)
        } catch is CancellationError {
            if requestID == id {
                isLoading = false
                loadTask = nil
                downloadProgress = nil
                await refreshArchives(request: id)
            }
            return
        } catch {
            guard requestID == id else { return }
            errorMessage = error.localizedDescription
            await refreshArchives(request: id)
        }
        if requestID == id {
            isLoading = false
            loadTask = nil
        }
    }
    private func refreshArchives(request: UUID? = nil) async {
        let generation = cacheGeneration
        let values = await provider.cachedArchives()
        guard cacheGeneration == generation, request == nil || requestID == request else { return }
        archives = values
        cachedSessionKeys = Set(values.filter(\.canReplay).map { $0.session.key })
    }
    private func installReplay(_ dataset: ReplayDataset) {
        replay = dataset
        preferences?.set(dataset.session.key, forKey: "lastReplaySessionKey")
        session = dataset.session
        mode = .replay
        replayDuration = dataset.duration
        replayTime = 0
        isPlaying = false
        let savedRate = preferences?.double(forKey: "defaultPlaybackRate") ?? 1
        playbackRate = savedRate > 0 && savedRate.isFinite ? min(256, max(0.1, savedRate)) : 1
        connectionState = "Recorded session"
        dataSourceLabel = "Downloaded recorded session"
        trackOutline = dataset.outline
        channelAvailability = dataset.channelAvailability
        replayEvents = dataset.events
        comparisonDriverNumbers = []
        updateReplay()
        resetClock()
        updateTicker()
    }
    public func setReplayTime(_ time: Double) {
        guard mode == .replay, time.isFinite else { return }
        replayTime = min(replayDuration, max(0, time))
        if replayTime >= replayDuration { isPlaying = false }
        updateReplay()
        resetClock()
        updateTicker()
    }
    public func seekLap(_ lap: Int, driver: Int? = nil) {
        guard let replay, let driver = driver ?? selectedDriverNumber ?? drivers.first?.id,
            let start = replay.lapStart(driver: driver, lap: lap)
        else { return }
        setReplayTime(start.timeIntervalSince(replay.session.startsAt))
    }
    public func seekEvent(_ event: ReplayEvent) {
        guard let session else { return }
        setReplayTime(event.date.timeIntervalSince(session.startsAt))
    }
    public func skipEvent(_ direction: Int) {
        synchronizeTime()
        guard let date = replayDate else { return }
        let event =
            direction >= 0
            ? replayEvents.first { $0.date > date.addingTimeInterval(0.5) }
            : replayEvents.last { $0.date < date.addingTimeInterval(-0.5) }
        if let event { seekEvent(event) }
    }
    public func nudgeReplay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        synchronizeTime()
        setReplayTime(replayTime + seconds)
    }
    public func restartReplay() { setReplayTime(0) }
    public func skipLap(_ direction: Int) {
        synchronizeTime()
        guard let replay, let date = replayDate, let number = selectedDriverNumber ?? drivers.first?.id else {
            return
        }
        if let next = replay.lapBoundary(for: number, at: date, direction: direction) {
            setReplayTime(next.timeIntervalSince(replay.session.startsAt))
        } else {
            setReplayTime(direction >= 0 ? replayDuration : 0)
        }
    }
    public func togglePlayback() {
        guard mode == .replay, !isLoading else { return }
        synchronizeTime()
        if replayTime >= replayDuration { setReplayTime(0) }
        isPlaying.toggle()
        updateReplay()
        updateTicker()
        resetClock()
    }
    public func pauseReplay() {
        synchronizeTime()
        isPlaying = false
        updateReplay()
        updateTicker()
        resetClock()
    }
    public func toggleComparisonDriver(_ number: Int) {
        if comparisonDriverNumbers.contains(number) {
            comparisonDriverNumbers.remove(number)
        } else if comparisonDriverNumbers.count < 6 {
            comparisonDriverNumbers.insert(number)
        }
    }
    public func lapHistory(for number: Int) -> [LapSample] {
        guard let replay, let date = replayDate else { return [] }
        return replay.laps(for: number, at: date)
    }
    public func stintHistory(for number: Int) -> [StintSample] {
        guard let replay, let date = replayDate else { return [] }
        return replay.visibleStints(for: number, at: date)
    }
    public func recordedLaps(for number: Int) -> [RecordedLap] { replay?.recordedLaps(for: number) ?? [] }
    public func lapTelemetry(for number: Int, lap: Int) -> [LapTelemetryPoint] {
        replay?.lapTelemetry(for: number, lap: lap) ?? []
    }
    public func compareLaps(reference: LapSelection, comparison: LapSelection) -> LapComparison? {
        replay?.compareLaps(reference: reference, comparison: comparison)
    }
    public func renderedPositions(at sessionDate: Date) -> [CarPosition] {
        replay?.interpolatedPositions(at: sessionDate) ?? []
    }
    public func telemetry(for number: Int, at sessionDate: Date) -> ReplayTelemetry {
        replay?.telemetry(for: number, at: sessionDate) ?? ReplayTelemetry()
    }
    private func updateReplay() {
        guard let replay, let date = replayDate else { return }
        let state = replay.snapshot(at: date)
        if drivers != state { drivers = state }
        let control = replay.controlMessages(at: date)
        if messages != control { messages = control }
        weather = replay.weather(at: date)
        trackStatus =
            replay.status(at: date, kind: .track)
            ?? Self.replayTrackStatus(messages: messages, finished: replayTime >= replayDuration)
        sessionStatus = replay.status(at: date, kind: .session)
        qualifyingPhase = replay.phase(at: date)
    }
    nonisolated static func replayTrackStatus(messages: [ControlMessage], finished: Bool) -> String {
        if finished { return "Replay complete" }
        for message in messages {
            let text = message.text.uppercased()
            if text == "SESSION STARTED" || text == "SESSION RESUMED" { return "Track clear" }
            if text == "SESSION ABORTED" { return "Session suspended" }
            if message.category.lowercased() == "safetycar" {
                if text.contains("DEPLOYED") {
                    return text.contains("VIRTUAL") ? "Virtual safety car" : "Safety car"
                }
                if text.contains("IN THIS LAP") { return "Safety car ending" }
                if text.contains("ENDING") { return "Virtual safety car ending" }
            }
            if message.flag == "RED" { return "Red flag" }
            if message.flag == "GREEN", !text.contains("SECTOR") { return "Track clear" }
            if message.flag == "CHEQUERED" { return "Chequered flag" }
        }
        return "Recorded session"
    }

    public func fetchSessions(year: Int, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        sessionsRequestID = id
        sessionsError = nil
        isSessionsLoading = true
        defer { if sessionsRequestID == id { isSessionsLoading = false } }
        let savedSessions = await provider.cachedSessions().filter { $0.year == year }
        guard !Task.isCancelled, sessionsRequestID == id else { return }
        sessions = Self.mergedSessions(preferred: sessions.filter { $0.year == year }, saved: savedSessions)
        do {
            let values = try await provider.sessions(year: year, force: force)
            try Task.checkCancellation()
            guard sessionsRequestID == id else { return }
            sessions = Self.mergedSessions(preferred: values, saved: savedSessions)
        } catch is CancellationError {} catch {
            if sessionsRequestID == id {
                sessionsError = "Could not refresh sessions: \(error.localizedDescription)"
            }
        }
    }
    private static func mergedSessions(preferred: [SessionSummary], saved: [SessionSummary])
        -> [SessionSummary]
    {
        var byKey = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for summary in preferred { byKey[summary.key] = summary }
        return byKey.values.sorted { $0.startsAt > $1.startsAt }
    }
    public func refreshCalendar(year: Int, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        calendarRequestID = id
        calendarError = nil
        isCalendarLoading = true
        defer { if calendarRequestID == id { isCalendarLoading = false } }
        do {
            let values = try await provider.calendar(year: year, force: force)
            try Task.checkCancellation()
            guard calendarRequestID == id else { return }
            guard !values.isEmpty else {
                throw ProviderError.invalidData("No calendar has been published for \(year).")
            }
            calendar = values
        } catch is CancellationError {} catch {
            if calendarRequestID == id {
                calendarError = "Could not refresh the calendar: \(error.localizedDescription)"
            }
        }
    }
    public func refreshStandings(year: Int, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        standingsRequestID = id
        standingsError = nil
        isStandingsLoading = true
        defer { if standingsRequestID == id { isStandingsLoading = false } }
        do {
            async let drivers = provider.standings(year: year, constructors: false, force: force)
            async let constructors = provider.standings(year: year, constructors: true, force: force)
            let values = try await (drivers, constructors)
            try Task.checkCancellation()
            guard standingsRequestID == id else { return }
            driverStandings = values.0.rows
            constructorStandings = values.1.rows
            standingsYear = year
            standingsRound = values.0.round == values.1.round ? values.0.round : nil
            if values.0.rows.isEmpty && values.1.rows.isEmpty {
                standingsError = "Standings have not been published for \(year)."
            }
        } catch is CancellationError {} catch {
            if standingsRequestID == id {
                standingsError = "Could not refresh standings: \(error.localizedDescription)"
            }
        }
    }
    public func clearCache() async {
        sessionsError = nil
        cancelLoading()
        sessionsRequestID = UUID()
        isSessionsLoading = false
        let generation = UUID()
        cacheGeneration = generation
        do {
            try await provider.clearCache()
        } catch {
            if cacheGeneration == generation { sessionsError = error.localizedDescription }
        }
        guard cacheGeneration == generation else { return }
        await refreshArchives()
    }
    public func deleteDownloadedSession(_ key: Int) async {
        sessionsError = nil
        cancelLoading()
        cacheGeneration = UUID()
        do {
            try await provider.deleteReplay(key)
            await refreshArchives()
        } catch { sessionsError = error.localizedDescription }
    }
    public func cancelLoading() {
        let id = UUID()
        requestID = id
        let cancelled = loadTask
        cancelled?.cancel()
        loadTask = nil
        isLoading = false
        downloadProgress = nil
        if let cancelled {
            Task { [weak self] in
                _ = try? await cancelled.value
                await self?.refreshArchives(request: id)
            }
        }
    }
    public func setCoverageVisible(_ visible: Bool) {
        guard isCoverageVisible != visible else { return }
        if !visible {
            synchronizeTime()
            updateReplay()
        }
        isCoverageVisible = visible
        updateTicker()
        resetClock()
    }
    public func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        if !active {
            synchronizeTime()
            updateReplay()
        }
        isAppActive = active
        updateTicker()
        resetClock()
    }
    private func synchronizeTime(rate: Double? = nil) {
        guard ticker != nil, isPlaying, mode == .replay else { return }
        let now = ContinuousClock.now
        let interval = lastTick.duration(to: now)
        let seconds = max(
            0, Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18)
        replayTime = min(replayDuration, replayTime + seconds * (rate ?? playbackRate))
        lastTick = now
        if replayTime >= replayDuration { isPlaying = false }
    }
    private func resetClock() {
        lastTick = ContinuousClock.now
        replayClock = ReplayClock(
            sessionStart: session?.startsAt ?? Date(timeIntervalSince1970: 0), duration: replayDuration,
            anchorTime: replayTime, anchorDate: Date(), rate: playbackRate,
            isAdvancing: isPlaying && isCoverageVisible && isAppActive && !isLoading)
    }
    private func updateTicker() {
        let shouldTick = mode == .replay && isPlaying && isCoverageVisible && isAppActive && !isLoading
        guard shouldTick else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        lastTick = ContinuousClock.now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, let self, self.isCoverageVisible, self.isAppActive, self.isPlaying
                else { return }
                self.synchronizeTime()
                self.updateReplay()
                self.resetClock()
                if !self.isPlaying { self.updateTicker() }
            }
        }
    }
}
