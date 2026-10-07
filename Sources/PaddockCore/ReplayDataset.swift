import Foundation

typealias TimedPosition = RecordedPosition
typealias TimedInterval = RecordedInterval
typealias TimedWeather = RecordedWeather
struct TimedLocation: Sendable {
    var date: Date
    var position: CarPosition
}
struct LapStart: Sendable {
    var date: Date
    var driver: Int
    var lap: Int
}

struct ReplayDataset: Sendable {
    static let maximumInterpolationGap: TimeInterval = 2
    private(set) var archive: ReplayArchive
    var session: SessionSummary {
        get { archive.session }
        set { archive.session = newValue }
    }
    var drivers: [Driver] { archive.drivers }
    var stints: [StintSample] { archive.stints }
    var messages: [ControlMessage] { archive.messages }
    var positions: [TimedPosition] { archive.positions }
    var intervals: [TimedInterval] { archive.intervals }
    var weather: [TimedWeather] { archive.weather }
    var locations: [TimedLocation] {
        get {
            archive.locations.map {
                TimedLocation(
                    date: $0.date, position: CarPosition(driverNumber: $0.driverNumber, x: $0.x, y: $0.y))
            }.sorted { $0.date < $1.date }
        }
        set {
            attachRecordedSamples(
                locations: newValue.map {
                    RecordedCarSample(
                        date: $0.date, driverNumber: $0.position.driverNumber, x: $0.position.x,
                        y: $0.position.y)
                }, telemetry: archive.telemetry)
        }
    }
    private(set) var laps: [LapSample] = []
    private(set) var lapStarts: [LapStart] = []
    private(set) var duration: Double = 1
    var outline: [TrackPoint] = []
    private(set) var events: [ReplayEvent] = []
    private var timelines: [DriverTimeline] = []
    private var timelineByDriver: [Int: Int] = [:]
    private var locationRanges: [Int: Range<Int>] = [:]
    private var telemetryRanges: [Int: Range<Int>] = [:]
    private var locationDrivers: [Int] = []
    private var recordedLapsByDriver: [Int: [RecordedLap]] = [:]
    private var lapBySelection: [LapSelection: RecordedLap] = [:]

    init(raw: [String: JSONValue], fallback: SessionSummary? = nil) throws {
        try Task.checkCancellation()
        try self.init(archive: Self.decodeArchive(raw, fallback: fallback))
    }

    init(archive: ReplayArchive) throws {
        try Task.checkCancellation()
        var archive = archive
        guard archive.session.startsAt.timeIntervalSince1970.isFinite else {
            throw ProviderError.invalidData("This archive has no valid session start time.")
        }
        archive.drivers = Dictionary(
            archive.drivers.filter { $0.number > 0 }.map { ($0.number, $0) },
            uniquingKeysWith: { _, last in last }
        ).values.sorted { $0.number < $1.number }
        let knownDrivers = Set(archive.drivers.map(\.number))
        archive.laps = Dictionary(
            archive.laps.compactMap { original -> (String, RecordedLap)? in
                guard knownDrivers.contains(original.driverNumber), (1...10000).contains(original.lap),
                    original.startedAt.timeIntervalSince1970.isFinite
                else { return nil }
                var lap = original
                if let completion = lap.completedAt,
                    !completion.timeIntervalSince1970.isFinite || completion < lap.startedAt
                {
                    lap.completedAt = nil
                    lap.duration = nil
                }
                lap.duration = lap.duration.flatMap { $0.isFinite && $0 > 0 && $0 <= 86400 ? $0 : nil }
                return (lap.id, lap)
            }, uniquingKeysWith: { _, last in last }
        ).values.sorted {
            ($0.startedAt, $0.driverNumber, $0.lap) < ($1.startedAt, $1.driverNumber, $1.lap)
        }
        archive.positions = archive.positions.filter {
            knownDrivers.contains($0.driver) && $0.position > 0 && $0.date.timeIntervalSince1970.isFinite
        }
            .sorted { $0.date < $1.date }
        archive.intervals = archive.intervals.filter {
            knownDrivers.contains($0.driver) && $0.date.timeIntervalSince1970.isFinite
        }.sorted { $0.date < $1.date }
        archive.weather = archive.weather.filter { $0.date.timeIntervalSince1970.isFinite }
            .sorted { $0.date < $1.date }
        archive.messages = archive.messages.filter { $0.date.timeIntervalSince1970.isFinite }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        LapValidity.attribute(archive.messages, to: &archive.laps)
        archive.statuses = archive.statuses.filter { $0.date.timeIntervalSince1970.isFinite }
            .sorted { $0.date < $1.date }
        archive.driverStatuses = archive.driverStatuses.filter {
            knownDrivers.contains($0.driverNumber) && $0.date.timeIntervalSince1970.isFinite
        }.sorted { $0.date < $1.date }
        archive.sourceBestLaps = archive.sourceBestLaps?.filter {
            guard knownDrivers.contains($0.driverNumber), $0.date.timeIntervalSince1970.isFinite else {
                return false
            }
            guard let time = $0.time else { return true }
            return time.isFinite && time > 0 && time <= 86400
        }.sorted { $0.date < $1.date }
        archive.pits = archive.pits.filter { pit in
            knownDrivers.contains(pit.driverNumber) && pit.enteredAt.timeIntervalSince1970.isFinite
                && (pit.exitedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= pit.enteredAt } ?? true)
        }.sorted { $0.enteredAt < $1.enteredAt }
        archive.stints = archive.stints.filter { (1...10000).contains($0.startLap) }.map {
            var stint = $0
            stint.tyreAgeAtStart = min(10000, max(0, stint.tyreAgeAtStart))
            return stint
        }.sorted { $0.startLap < $1.startLap }
        guard !archive.drivers.isEmpty, !archive.laps.isEmpty else {
            throw ProviderError.invalidData("This archive has no recorded drivers and laps to replay.")
        }
        try Task.checkCancellation()
        self.archive = archive
        recordedLapsByDriver = Dictionary(grouping: archive.laps, by: \.driverNumber)
        lapBySelection = Dictionary(
            uniqueKeysWithValues: archive.laps.map {
                (LapSelection(driverNumber: $0.driverNumber, lap: $0.lap), $0)
            })
        lapStarts = archive.laps.map { LapStart(date: $0.startedAt, driver: $0.driverNumber, lap: $0.lap) }
        laps = archive.laps.compactMap { lap in
            guard let duration = lap.duration, duration.isFinite, duration > 0, duration <= 86400,
                let completed = lap.completedAt, completed.timeIntervalSince1970.isFinite,
                completed >= lap.startedAt
            else { return nil }
            return LapSample(
                driverNumber: lap.driverNumber, lap: lap.lap, time: duration,
                sector1: lap.sector1, sector2: lap.sector2, sector3: lap.sector3, date: completed)
        }.sorted { ($0.date, $0.driverNumber, $0.lap) < ($1.date, $1.driverNumber, $1.lap) }
        let lapGroups = Dictionary(grouping: laps, by: \.driverNumber)
        let startGroups = Dictionary(grouping: lapStarts, by: \.driver)
        let positionGroups = Dictionary(grouping: archive.positions, by: \.driver)
        let intervalGroups = Dictionary(grouping: archive.intervals, by: \.driver)
        let stintGroups = Dictionary(grouping: archive.stints, by: \.driverNumber)
        let pitGroups = Dictionary(grouping: archive.pits, by: \.driverNumber)
        let statusGroups = Dictionary(grouping: archive.driverStatuses, by: \.driverNumber)
        let sourceBestGroups = Dictionary(grouping: archive.sourceBestLaps ?? [], by: \.driverNumber)
        timelines = archive.drivers.map { driver in
            DriverTimeline(
                driver: driver, laps: lapGroups[driver.number] ?? [],
                starts: startGroups[driver.number] ?? [],
                positions: positionGroups[driver.number] ?? [],
                intervals: intervalGroups[driver.number] ?? [],
                stints: stintGroups[driver.number] ?? [], pits: pitGroups[driver.number] ?? [],
                statuses: statusGroups[driver.number] ?? [],
                recordedLaps: recordedLapsByDriver[driver.number] ?? [],
                sourceBestLaps: sourceBestGroups[driver.number] ?? [])
        }
        timelineByDriver = Dictionary(
            uniqueKeysWithValues: timelines.enumerated().map { ($0.element.driver.number, $0.offset) })
        try Task.checkCancellation()
        attachRecordedSamples(locations: archive.locations, telemetry: archive.telemetry)
        try Task.checkCancellation()
        events = makeEvents()
    }

    mutating func attachRecordedSamples(locations: [RecordedCarSample], telemetry: [RecordedTelemetrySample])
    {
        let known = Set(drivers.map(\.number))
        archive.locations = locations.filter {
            known.contains($0.driverNumber) && $0.date.timeIntervalSince1970.isFinite
                && $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e9 && abs($0.y) <= 1e9
                && ($0.x != 0 || $0.y != 0)
        }.sorted { ($0.driverNumber, $0.date) < ($1.driverNumber, $1.date) }
        archive.telemetry = telemetry.filter {
            known.contains($0.driverNumber) && $0.date.timeIntervalSince1970.isFinite
        }.map(Self.validatedTelemetry).sorted { ($0.driverNumber, $0.date) < ($1.driverNumber, $1.date) }
        locationRanges = Self.ranges(archive.locations, driver: \.driverNumber)
        telemetryRanges = Self.ranges(archive.telemetry, driver: \.driverNumber)
        locationDrivers = locationRanges.keys.sorted()
        outline = makeOutline()
        let actualEnd =
            [
                session.endsAt, lapStarts.last?.date, messages.last?.date,
                archive.laps.compactMap(\.completedAt).filter { $0.timeIntervalSince1970.isFinite }.max(),
                archive.laps.compactMap { $0.validityChanges?.last?.date }.max(),
                archive.positions.last?.date, archive.intervals.last?.date, archive.weather.last?.date,
                archive.locations.max(by: { $0.date < $1.date })?.date,
                archive.telemetry.max(by: { $0.date < $1.date })?.date,
                archive.statuses.last?.date, archive.driverStatuses.last?.date,
                archive.sourceBestLaps?.last?.date, archive.pits.last?.enteredAt,
                archive.pits.compactMap(\.exitedAt).max(),
            ].compactMap { $0 }.filter { $0.timeIntervalSince1970.isFinite }.max() ?? session.startsAt
        duration = max(1, actualEnd.timeIntervalSince(session.startsAt))
    }

    var channelAvailability: ReplayChannelAvailability {
        ReplayChannelAvailability(
            coordinates: !archive.locations.isEmpty, telemetry: !archive.telemetry.isEmpty,
            pitIntervals: !archive.pits.isEmpty, driverStatuses: !archive.driverStatuses.isEmpty,
            qualifyingPhases: archive.laps.contains { $0.phase != nil })
    }
    func snapshot(at date: Date) -> [DriverState] {
        let currentPhase = session.isQualifying ? phase(at: date) : nil
        return timelines.map { $0.snapshot(at: date, qualifyingPhase: currentPhase) }.sorted {
            ($0.position ?? 999, $0.id) < ($1.position ?? 999, $1.id)
        }
    }
    func laps(for driver: Int, at date: Date) -> [LapSample] {
        guard let index = timelineByDriver[driver] else { return [] }
        let samples = timelines[index].laps
        return Array(samples.prefix(samples.upperBound(at: date, date: \.date)))
    }
    func recordedLaps(for driver: Int) -> [RecordedLap] { recordedLapsByDriver[driver] ?? [] }
    func lapBoundary(for driver: Int, at date: Date, direction: Int) -> Date? {
        guard let index = timelineByDriver[driver] else { return nil }
        let starts = timelines[index].starts
        if direction >= 0 {
            let next = starts.upperBound(at: date.addingTimeInterval(0.5), date: \.date)
            return next < starts.count ? starts[next].date : nil
        }
        let previous = starts.lowerBound(at: date.addingTimeInterval(-0.5), date: \.date) - 1
        return previous >= 0 ? starts[previous].date : nil
    }
    func lapStart(driver: Int, lap: Int) -> Date? {
        lapBySelection[LapSelection(driverNumber: driver, lap: lap)]?.startedAt
    }
    func visibleStints(for driver: Int, at date: Date) -> [StintSample] {
        guard let index = timelineByDriver[driver] else { return [] }
        let timeline = timelines[index]
        let lap = timeline.currentLap(at: date)
        return timeline.stints.prefix { $0.startLap <= lap }.map {
            var result = $0
            result.endLap = $0.endLap.map { min($0, lap) }
            return result
        }
    }
    func controlMessages(at date: Date) -> [ControlMessage] {
        Array(messages.prefix(messages.upperBound(at: date, date: \.date)).reversed())
    }
    func weather(at date: Date) -> WeatherInfo? {
        let index = weather.upperBound(at: date, date: \.date) - 1
        return index >= 0 ? weather[index].weather : nil
    }
    func status(at date: Date, kind: ReplayStatusKind) -> String? {
        let end = archive.statuses.upperBound(at: date, date: \.date)
        return archive.statuses[..<end].last { $0.kind == kind }?.status
    }
    func phase(at date: Date) -> QualifyingPhase? {
        let end = archive.statuses.upperBound(at: date, date: \.date)
        if let phase = archive.statuses[..<end].last(where: { $0.phase != nil })?.phase { return phase }
        return archive.laps.last { $0.startedAt <= date && $0.phase != nil }?.phase
    }
    func carPositions(at date: Date) -> [CarPosition] {
        locationDrivers.compactMap { driver in
            guard let range = locationRanges[driver] else { return nil }
            let index = Self.upperBound(archive.locations, in: range, at: date, date: \.date) - 1
            guard range.contains(index), date.timeIntervalSince(archive.locations[index].date) <= 3 else {
                return nil
            }
            let sample = archive.locations[index]
            return CarPosition(driverNumber: driver, x: sample.x, y: sample.y)
        }
    }
    func interpolatedPositions(at date: Date) -> [CarPosition] {
        locationDrivers.compactMap { driver in
            guard let range = locationRanges[driver],
                let pair = Self.bracket(archive.locations, in: range, at: date, date: \.date)
            else { return nil }
            let a = archive.locations[pair.lower]
            let b = archive.locations[pair.upper]
            return CarPosition(
                driverNumber: driver, x: Self.interpolate(a.x, b.x, pair.fraction),
                y: Self.interpolate(a.y, b.y, pair.fraction))
        }
    }
    func telemetry(for driver: Int, at date: Date) -> ReplayTelemetry {
        guard let range = telemetryRanges[driver] else { return ReplayTelemetry() }
        guard let pair = Self.bracket(archive.telemetry, in: range, at: date, date: \.date) else {
            let index = Self.upperBound(archive.telemetry, in: range, at: date, date: \.date) - 1
            return ReplayTelemetry(date: range.contains(index) ? archive.telemetry[index].date : nil)
        }
        let a = archive.telemetry[pair.lower]
        let b = archive.telemetry[pair.upper]
        let rpm = Self.interpolate(a.rpm.map(Double.init), b.rpm.map(Double.init), pair.fraction).map {
            Int($0.rounded())
        }
        return ReplayTelemetry(
            speed: Self.interpolate(a.speed, b.speed, pair.fraction),
            throttle: Self.interpolate(a.throttle, b.throttle, pair.fraction), brake: a.brake,
            gear: a.gear, rpm: rpm, drs: a.drs, date: a.date, isStale: false)
    }

    func lapTelemetry(for driver: Int, lap: Int) -> [LapTelemetryPoint] {
        guard let selected = lapBySelection[LapSelection(driverNumber: driver, lap: lap)],
            let end = selected.completedAt, end > selected.startedAt,
            let range = telemetryRanges[driver],
            let startSample = recordedTelemetry(for: driver, at: selected.startedAt),
            let endSample = recordedTelemetry(for: driver, at: end)
        else { return [] }
        let first = Self.upperBound(archive.telemetry, in: range, at: selected.startedAt, date: \.date)
        let last = Self.upperBound(
            archive.telemetry, in: range, at: end.addingTimeInterval(-0.000001), date: \.date)
        let samples = [startSample] + Array(archive.telemetry[first..<max(first, last)]) + [endSample]
        guard samples.count >= 2,
            !zip(samples, samples.dropFirst()).contains(where: {
                $1.date.timeIntervalSince($0.date) > Self.maximumInterpolationGap
            })
        else { return [] }
        var distance = 0.0
        var result: [LapTelemetryPoint] = []
        var previous: RecordedTelemetrySample?
        let distances = samples.compactMap(\.distance)
        let usesRecordedDistance =
            distances.count == samples.count && !zip(distances, distances.dropFirst()).contains { $1 < $0 }
        let sourceDistanceStart = usesRecordedDistance ? samples.first?.distance : nil
        for sample in samples {
            if let sourceDistanceStart, let recorded = sample.distance {
                distance = recorded - sourceDistanceStart
            } else if let previous, let a = previous.speed, let b = sample.speed {
                distance += (a + b) / 2 / 3.6 * sample.date.timeIntervalSince(previous.date)
            } else if previous != nil {
                return []
            }
            if let last = result.last, distance <= last.distance {
                previous = sample
                continue
            }
            result.append(
                LapTelemetryPoint(
                    distance: distance, elapsed: sample.date.timeIntervalSince(selected.startedAt),
                    speed: sample.speed, throttle: sample.throttle, brake: sample.brake,
                    gear: sample.gear, rpm: sample.rpm, drs: sample.drs))
            previous = sample
        }
        return result.count >= 2 ? result : []
    }
    private func recordedTelemetry(for driver: Int, at date: Date) -> RecordedTelemetrySample? {
        guard let range = telemetryRanges[driver],
            let pair = Self.bracket(archive.telemetry, in: range, at: date, date: \.date)
        else { return nil }
        let a = archive.telemetry[pair.lower]
        let b = archive.telemetry[pair.upper]
        let cursor = telemetry(for: driver, at: date)
        return RecordedTelemetrySample(
            date: date, driverNumber: driver, speed: cursor.speed, throttle: cursor.throttle,
            brake: cursor.brake, gear: cursor.gear, rpm: cursor.rpm, drs: cursor.drs,
            distance: Self.interpolate(a.distance, b.distance, pair.fraction))
    }
    func compareLaps(reference: LapSelection, comparison: LapSelection) -> LapComparison? {
        let a = lapTelemetry(for: reference.driverNumber, lap: reference.lap)
        let b = lapTelemetry(for: comparison.driverNumber, lap: comparison.lap)
        guard let aEnd = a.last?.distance, let bEnd = b.last?.distance, min(aEnd, bEnd) > 100 else {
            return nil
        }
        let end = min(aEnd, bEnd)
        var points: [LapComparisonPoint] = []
        var otherIndex = 0
        for sample in a where sample.distance <= end {
            while otherIndex + 1 < b.count, b[otherIndex + 1].distance < sample.distance { otherIndex += 1 }
            guard otherIndex + 1 < b.count, b[otherIndex].distance <= sample.distance else { continue }
            let lower = b[otherIndex]
            let upper = b[otherIndex + 1]
            let fraction = (sample.distance - lower.distance) / (upper.distance - lower.distance)
            points.append(
                LapComparisonPoint(
                    distance: sample.distance, referenceElapsed: sample.elapsed,
                    comparedElapsed: Self.interpolate(lower.elapsed, upper.elapsed, fraction)))
        }
        return points.count >= 2
            ? LapComparison(reference: reference, comparison: comparison, points: points) : nil
    }
    static func outline(for lap: LapSample, locations: [TimedLocation]) -> [TrackPoint] {
        guard let duration = lap.time, duration > 30 else { return [] }
        let start = lap.date.addingTimeInterval(-duration)
        let points = locations.filter {
            $0.position.driverNumber == lap.driverNumber && $0.date >= start && $0.date <= lap.date
        }.sorted { $0.date < $1.date }
        guard points.count >= 25, let first = points.first, let last = points.last,
            last.date.timeIntervalSince(first.date) >= duration * 0.95,
            first.date.timeIntervalSince(start) <= 3,
            lap.date.timeIntervalSince(last.date) <= 3,
            !zip(points, points.dropFirst()).contains(where: { $1.date.timeIntervalSince($0.date) > 5 })
        else { return [] }
        let step = max(1, points.count / 350)
        return points.enumerated().compactMap {
            $0.offset % step == 0 ? TrackPoint(x: $0.element.position.x, y: $0.element.position.y) : nil
        }
    }
    private func makeOutline() -> [TrackPoint] {
        for lap in laps.filter({ ($0.time ?? 0) > 30 }).sorted(by: {
            ($0.time ?? .infinity) < ($1.time ?? .infinity)
        }) {
            guard let range = locationRanges[lap.driverNumber], let duration = lap.time else { continue }
            let start = lap.date.addingTimeInterval(-duration)
            let lower = Self.upperBound(
                archive.locations, in: range, at: start.addingTimeInterval(-0.001), date: \.date)
            let upper = Self.upperBound(archive.locations, in: range, at: lap.date, date: \.date)
            let points = archive.locations[lower..<upper].map {
                TimedLocation(
                    date: $0.date, position: CarPosition(driverNumber: $0.driverNumber, x: $0.x, y: $0.y))
            }
            let outline = Self.outline(for: lap, locations: points)
            if !outline.isEmpty { return outline }
        }
        return []
    }
    private func makeEvents() -> [ReplayEvent] {
        var result = [ReplayEvent(id: "start", date: session.startsAt, kind: .start, title: "Session start")]
        for message in messages {
            let text = message.text.uppercased()
            let kind: ReplayEventKind
            if message.flag == "RED" {
                kind = .redFlag
            } else if text.contains("SAFETY CAR") {
                kind = .safetyCar
            } else if message.flag == "CHEQUERED" {
                kind = .finish
            } else if message.flag != nil {
                kind = .flag
            } else {
                kind = .raceControl
            }
            result.append(
                ReplayEvent(id: "control-\(message.id)", date: message.date, kind: kind, title: message.text))
        }
        for (index, pit) in archive.pits.enumerated() {
            result.append(
                ReplayEvent(
                    id: "pit-\(index)", date: pit.enteredAt, kind: .pit,
                    title: "Driver \(pit.driverNumber) entered pit lane", driverNumber: pit.driverNumber,
                    lap: pit.lap))
        }
        for (index, status) in archive.driverStatuses.enumerated() where status.status == .retired {
            result.append(
                ReplayEvent(
                    id: "retired-\(index)", date: status.date, kind: .retirement,
                    title: "Driver \(status.driverNumber) retired", driverNumber: status.driverNumber))
        }
        for (index, status) in archive.statuses.enumerated() {
            if let phase = status.phase {
                result.append(
                    ReplayEvent(
                        id: "phase-\(index)", date: status.date, kind: .qualifying,
                        title: "\(phase.rawValue) · \(status.status)"))
            } else if status.kind == .session {
                result.append(
                    ReplayEvent(
                        id: "session-\(index)", date: status.date, kind: .raceControl, title: status.status))
            }
        }
        return result.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }
    private static func ranges<T>(_ samples: [T], driver: KeyPath<T, Int>) -> [Int: Range<Int>] {
        var result: [Int: Range<Int>] = [:]
        var start = 0
        while start < samples.count {
            let number = samples[start][keyPath: driver]
            var end = start + 1
            while end < samples.count, samples[end][keyPath: driver] == number { end += 1 }
            result[number] = start..<end
            start = end
        }
        return result
    }
    private static func upperBound<T>(
        _ samples: [T], in range: Range<Int>, at date: Date, date key: KeyPath<T, Date>
    ) -> Int {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid][keyPath: key] <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }
    private static func bracket<T>(
        _ samples: [T], in range: Range<Int>, at date: Date, date key: KeyPath<T, Date>
    ) -> (lower: Int, upper: Int, fraction: Double)? {
        let lower = upperBound(samples, in: range, at: date, date: key) - 1
        guard range.contains(lower) else { return nil }
        let a = samples[lower][keyPath: key]
        if date == a { return (lower, lower, 0) }
        let upper = lower + 1
        guard range.contains(upper) else { return nil }
        let span = samples[upper][keyPath: key].timeIntervalSince(a)
        guard span > 0, span <= maximumInterpolationGap else { return nil }
        return (lower, upper, date.timeIntervalSince(a) / span)
    }
    private static func interpolate(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        a + (b - a) * fraction
    }
    private static func interpolate(_ a: Double?, _ b: Double?, _ fraction: Double) -> Double? {
        guard let a else { return nil }
        if fraction == 0 { return a }
        guard let b else { return nil }
        return interpolate(a, b, fraction)
    }
    private static func validatedTelemetry(_ sample: RecordedTelemetrySample) -> RecordedTelemetrySample {
        var result = sample
        result.speed = sample.speed.flatMap { $0.isFinite && (0...500).contains($0) ? $0 : nil }
        result.throttle = sample.throttle.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        result.gear = sample.gear.flatMap { (0...9).contains($0) ? $0 : nil }
        result.rpm = sample.rpm.flatMap { (0...25000).contains($0) ? $0 : nil }
        result.distance = sample.distance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return result
    }
    private static func decodeArchive(_ raw: [String: JSONValue], fallback: SessionSummary?) throws
        -> ReplayArchive
    {
        guard let session = (raw["session"]?.array ?? []).first.flatMap(ProviderDecoders.session) ?? fallback
        else {
            throw ProviderError.invalidData("The replay has no valid session metadata.")
        }
        let drivers = (raw["drivers"]?.array ?? []).compactMap(ProviderDecoders.driver)
        let laps: [RecordedLap] = (raw["laps"]?.array ?? []).compactMap { row in
            guard let driver = row["driver_number"].int, let lap = row["lap_number"].int,
                let start = RaceDate.parse(row["date_start"].string)
            else { return nil }
            let duration = row["lap_duration"].double.flatMap { $0 > 0 && $0 <= 86400 ? $0 : nil }
            return RecordedLap(
                driverNumber: driver, lap: lap, startedAt: start,
                completedAt: duration.map { start.addingTimeInterval($0) }, duration: duration,
                sector1: row["duration_sector_1"].double, sector2: row["duration_sector_2"].double,
                sector3: row["duration_sector_3"].double,
                phase: row["qualifying_phase"].string.flatMap(QualifyingPhase.init(rawValue:)),
                isPitOut: row["is_pit_out_lap"].bool ?? false, isPitIn: row["is_pit_in_lap"].bool ?? false,
                isValid: row["is_valid"].bool)
        }
        let stints: [StintSample] = (raw["stints"]?.array ?? []).compactMap { row in
            guard let driver = row["driver_number"].int, let start = row["lap_start"].int else { return nil }
            return StintSample(
                driverNumber: driver, compound: row["compound"].string ?? "UNKNOWN", startLap: start,
                endLap: row["lap_end"].int,
                tyreAgeAtStart: min(10000, max(0, row["tyre_age_at_start"].int ?? 0)))
        }
        let messages: [ControlMessage] = (raw["race_control"]?.array ?? []).enumerated().compactMap {
            index, row in
            guard let date = RaceDate.parse(row["date"].string), let text = row["message"].string else {
                return nil
            }
            return ControlMessage(
                id: "\(session.key)-\(index)", date: date, text: text,
                category: row["category"].string ?? "Race control", flag: row["flag"].string)
        }
        let positions: [RecordedPosition] = (raw["position"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int,
                let position = row["position"].int, position > 0
            else { return nil }
            return RecordedPosition(date: date, driver: driver, position: position)
        }
        let positionsByDriver = Dictionary(grouping: positions, by: \.driver).mapValues {
            $0.sorted { $0.date < $1.date }
        }
        let intervals: [RecordedInterval] = (raw["intervals"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int else {
                return nil
            }
            var gap = ProviderDecoders.gap(row["gap_to_leader"])
            if row.object?["gap_to_leader"] == .some(.null), let samples = positionsByDriver[driver] {
                let index = samples.upperBound(at: date, date: \.date) - 1
                if index >= 0, samples[index].position == 1 { gap = "LEADER" }
            }
            return RecordedInterval(
                date: date, driver: driver, gap: gap,
                interval: ProviderDecoders.gap(row["interval"]))
        }
        let weather: [RecordedWeather] = (raw["weather"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string) else { return nil }
            return RecordedWeather(
                date: date,
                weather: WeatherInfo(
                    air: row["air_temperature"].double, track: row["track_temperature"].double,
                    humidity: row["humidity"].double, windSpeed: row["wind_speed"].double,
                    rainfall: row["rainfall"].bool))
        }
        let locations: [RecordedCarSample] = (raw["location"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int,
                let x = row["x"].double, let y = row["y"].double
            else { return nil }
            return RecordedCarSample(date: date, driverNumber: driver, x: x, y: y, z: row["z"].double)
        }
        let telemetry: [RecordedTelemetrySample] = (raw["car_data"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int else {
                return nil
            }
            return RecordedTelemetrySample(
                date: date, driverNumber: driver, speed: row["speed"].double,
                throttle: row["throttle"].double,
                brake: row["brake"].bool, gear: row["n_gear"].int, rpm: row["rpm"].int,
                drs: DRSStatus.recorded(row["drs"].int), distance: row["distance"].double)
        }
        let pits: [RecordedPitInterval] = (raw["pit"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int else {
                return nil
            }
            let duration = row["lane_duration"].double ?? row["pit_duration"].double
            return RecordedPitInterval(
                driverNumber: driver, enteredAt: date,
                exitedAt: duration.flatMap { $0 > 0 && $0 < 600 ? date.addingTimeInterval($0) : nil },
                lap: row["lap_number"].int)
        }
        let driverStatuses: [RecordedDriverStatus] = (raw["driver_status"]?.array ?? []).compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), let driver = row["driver_number"].int,
                let status = row["status"].string.flatMap(DriverRaceStatus.init(rawValue:))
            else { return nil }
            return RecordedDriverStatus(date: date, driverNumber: driver, status: status)
        }
        var statuses: [RecordedStatus] = []
        for (key, kind) in [("session_status", ReplayStatusKind.session), ("track_status", .track)] {
            statuses += (raw[key]?.array ?? []).compactMap { row in
                guard let date = RaceDate.parse(row["date"].string), let status = row["status"].string else {
                    return nil
                }
                return RecordedStatus(
                    date: date, kind: kind, status: status,
                    phase: row["qualifying_phase"].string.flatMap(QualifyingPhase.init(rawValue:)))
            }
        }
        return ReplayArchive(
            session: session, drivers: drivers, laps: laps, stints: stints, messages: messages,
            positions: positions, intervals: intervals, weather: weather, locations: locations,
            telemetry: telemetry, pits: pits, driverStatuses: driverStatuses, statuses: statuses)
    }
}

private struct DriverTimeline: Sendable {
    private struct PhaseTimeline: Sendable {
        var startedAt: Date
        var bestLaps: [BestLapObservation]
    }
    let driver: Driver
    let laps: [LapSample]
    let starts: [LapStart]
    let positions: [TimedPosition]
    let intervals: [TimedInterval]
    let stints: [StintSample]
    let pits: [RecordedPitInterval]
    let statuses: [RecordedDriverStatus]
    private let bestLaps: [BestLapObservation]
    private let sourceBestLaps: [BestLapObservation]
    private let phaseTimelines: [QualifyingPhase: PhaseTimeline]
    private let lapNumbers: [Int]
    init(
        driver: Driver, laps: [LapSample], starts: [LapStart], positions: [TimedPosition],
        intervals: [TimedInterval],
        stints: [StintSample], pits: [RecordedPitInterval], statuses: [RecordedDriverStatus],
        recordedLaps: [RecordedLap], sourceBestLaps: [RecordedBestLap]
    ) {
        self.driver = driver
        self.laps = laps
        self.starts = starts
        self.positions = positions
        self.intervals = intervals
        self.stints = stints
        self.pits = pits
        self.statuses = statuses
        bestLaps = BestLapHistory.observations(for: recordedLaps)
        self.sourceBestLaps = sourceBestLaps.map { BestLapObservation(date: $0.date, time: $0.time) }
        let phaseLaps = Dictionary(grouping: recordedLaps, by: \.phase)
        phaseTimelines = Dictionary(
            uniqueKeysWithValues: QualifyingPhase.allCases.compactMap { phase -> (QualifyingPhase, PhaseTimeline)? in
                guard let samples = phaseLaps[phase], let first = samples.first else { return nil }
                return (phase, PhaseTimeline(
                    startedAt: first.startedAt, bestLaps: BestLapHistory.observations(for: samples)))
            })
        var lapNumber = 0
        lapNumbers = starts.map { start in
            lapNumber = max(lapNumber, start.lap)
            return lapNumber
        }
    }
    func currentLap(at date: Date) -> Int {
        let index = starts.upperBound(at: date, date: \.date) - 1
        return index >= 0 ? lapNumbers[index] : 0
    }
    func snapshot(at date: Date, qualifyingPhase: QualifyingPhase?) -> DriverState {
        var state = DriverState(driver: driver)
        let positionIndex = positions.upperBound(at: date, date: \.date) - 1
        if positionIndex >= 0 { state.position = positions[positionIndex].position }
        state.lap = currentLap(at: date)
        let intervalIndex = intervals.upperBound(at: date, date: \.date) - 1
        if intervalIndex >= 0 {
            state.gap = intervals[intervalIndex].gap
            state.interval = intervals[intervalIndex].interval
        }
        let lapIndex = laps.upperBound(at: date, date: \.date) - 1
        if lapIndex >= 0 {
            let lap = laps[lapIndex]
            state.lastLap = lap.time
            state.sector1 = lap.sector1
            state.sector2 = lap.sector2
            state.sector3 = lap.sector3
        }
        state.bestLap = bestLap(at: date, qualifyingPhase: qualifyingPhase)
        if let stint = stints.last(where: { $0.startLap <= state.lap }) {
            state.compound = stint.compound
            state.tyreAge = stint.tyreAgeAtStart + max(0, state.lap - stint.startLap)
        }
        let statusIndex = statuses.upperBound(at: date, date: \.date) - 1
        if statusIndex >= 0 { state.status = statuses[statusIndex].status }
        let pitIndex = pits.upperBound(at: date, date: \.enteredAt) - 1
        let pitIsActive = pitIndex >= 0 && (pits[pitIndex].exitedAt.map { date < $0 } ?? true)
        if pitIsActive {
            state.inPit = true
            if state.status != .retired && state.status != .finished { state.status = .inPit }
        } else if state.status == .inPit {
            state.inPit = true
        }
        return state
    }
    private func bestLap(at date: Date, qualifyingPhase: QualifyingPhase?) -> Double? {
        let history: [BestLapObservation]
        if !sourceBestLaps.isEmpty {
            history = sourceBestLaps
        } else if let qualifyingPhase,
            let phaseIndex = QualifyingPhase.allCases.firstIndex(of: qualifyingPhase)
        {
            let phases = QualifyingPhase.allCases[...phaseIndex].reversed()
            guard let phase = phases.first(where: { phaseTimelines[$0].map { $0.startedAt <= date } ?? false }),
                let timeline = phaseTimelines[phase]
            else { return nil }
            history = timeline.bestLaps
        } else {
            history = bestLaps
        }
        let index = history.upperBound(at: date, date: \.date) - 1
        return index >= 0 ? history[index].time : nil
    }
}

extension Array {
    func lowerBound(at target: Date, date: KeyPath<Element, Date>) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if self[middle][keyPath: date] < target { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func upperBound(at target: Date, date: KeyPath<Element, Date>) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if self[middle][keyPath: date] <= target { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
