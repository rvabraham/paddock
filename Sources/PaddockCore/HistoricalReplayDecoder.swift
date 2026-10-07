import Foundation

struct HistoricalReplayDecoder {
    private(set) var archive: ReplayArchive
    private var epoch: Date?
    private var timing: HistoricalTimingDecoder
    private var driverList: JSONValue = .null
    private var stintData: JSONValue = .null
    private var weatherData: JSONValue = .null
    private var seenMessages: Set<String> = []
    private var finalizedAt: Date?
    private let maximumSamples = 2_000_000

    init(session: SessionSummary) {
        archive = ReplayArchive(session: session, drivers: [], laps: [])
        timing = HistoricalTimingDecoder(countsCompletedLaps: ["race", "sprint"].contains(session.sessionName.lowercased()))
    }

    mutating func consume(_ name: String, data: Data) throws {
        switch name {
        case "ExtrapolatedClock":
            try HistoricalStream.forEach(data) { elapsed, value in
                if epoch == nil, let utc = RaceDate.parse(value["Utc"].string) {
                    epoch = utc.addingTimeInterval(-elapsed)
                }
            }
            guard epoch != nil else { throw ProviderError.invalidData("The historical archive has no usable replay clock.") }
        case "DriverList":
            try HistoricalStream.forEach(data) { _, patch in driverList = driverList.merging(patch) }
            archive.drivers = driverList.indexedValues.compactMap { key, row in
                guard let number = row["RacingNumber"].int ?? Int(key), (1...999).contains(number) else { return nil }
                let parts = [row["FirstName"].string, row["LastName"].string].compactMap { $0 }
                return Driver(number: number, name: parts.isEmpty ? row["FullName"].string ?? "Driver \(number)" : parts.joined(separator: " "),
                    acronym: row["Tla"].string ?? String(number), team: row["TeamName"].string ?? "",
                    colorHex: row["TeamColour"].string ?? "8E919A")
            }.sorted { $0.number < $1.number }
        case "TimingData":
            let base = try requireEpoch()
            try HistoricalStream.forEach(data) { elapsed, value in timing.apply(value, at: base.addingTimeInterval(elapsed)) }
        case "TimingAppData":
            try HistoricalStream.forEach(data) { _, patch in stintData = stintData.merging(patch) }
        case "SessionStatus", "TrackStatus":
            let base = try requireEpoch()
            try HistoricalStream.forEach(data) { elapsed, row in
                guard let value = row["Status"].string else { return }
                let date = base.addingTimeInterval(elapsed)
                archive.statuses.append(RecordedStatus(date: date,
                    kind: name == "TrackStatus" ? .track : .session,
                    status: name == "TrackStatus" ? Self.trackStatus(value) : value))
                if name == "SessionStatus", value.lowercased() == "started" { timing.recordRaceStart(at: date) }
                if name == "SessionStatus", ["finalised", "finalized", "ends"].contains(value.lowercased()) {
                    finalizedAt = max(finalizedAt ?? date, date)
                }
            }
        case "RaceControlMessages":
            try HistoricalStream.forEach(data) { _, patch in
                for (key, row) in patch["Messages"].indexedValues {
                    guard let date = RaceDate.parse(row["Utc"].string), let message = row["Message"].string else { continue }
                    let identity = "\(key)-\(date.timeIntervalSince1970)-\(message)"
                    guard seenMessages.insert(identity).inserted else { continue }
                    archive.messages.append(ControlMessage(id: "\(archive.session.key)-\(identity)", date: date,
                        text: message, category: row["Category"].string ?? "Race control", flag: row["Flag"].string))
                }
            }
        case "WeatherData":
            let base = try requireEpoch()
            try HistoricalStream.forEach(data) { elapsed, row in
                weatherData = weatherData.merging(row)
                archive.weather.append(RecordedWeather(date: base.addingTimeInterval(elapsed), weather: WeatherInfo(
                    air: Self.bounded(weatherData["AirTemp"].double, range: -60...70),
                    track: Self.bounded(weatherData["TrackTemp"].double, range: -60...100),
                    humidity: Self.bounded(weatherData["Humidity"].double, range: 0...100),
                    windSpeed: Self.bounded(weatherData["WindSpeed"].double, range: 0...100),
                    rainfall: weatherData["Rainfall"].bool)))
            }
        case "Position.z":
            try HistoricalStream.forEach(data, compressed: true) { _, value in
                for frame in value["Position"].array {
                    guard let date = RaceDate.parse(frame["Timestamp"].string) else { continue }
                    for (key, row) in frame["Entries"].indexedValues {
                        guard let driver = Int(key), let x = row["X"].double, let y = row["Y"].double,
                              x != 0 || y != 0, abs(x) <= 1e9, abs(y) <= 1e9 else { continue }
                        guard archive.locations.count < maximumSamples else { throw sampleLimit() }
                        try ReplayArchivePersistence.validateSampleBudget(locationCount: archive.locations.count + 1,
                            telemetryCount: archive.telemetry.count)
                        archive.locations.append(RecordedCarSample(date: date, driverNumber: driver, x: x, y: y, z: row["Z"].double))
                    }
                }
            }
        case "CarData.z":
            try HistoricalStream.forEach(data, compressed: true) { _, value in
                for frame in value["Entries"].array {
                    guard let date = RaceDate.parse(frame["Utc"].string) else { continue }
                    for (key, row) in frame["Cars"].indexedValues {
                        guard let driver = Int(key) else { continue }
                        guard archive.telemetry.count < maximumSamples else { throw sampleLimit() }
                        try ReplayArchivePersistence.validateSampleBudget(locationCount: archive.locations.count,
                            telemetryCount: archive.telemetry.count + 1)
                        let channels = row["Channels"]
                        let brake = channels["5"].double.flatMap { (0...100).contains($0) ? $0 > 0 : nil }
                        archive.telemetry.append(RecordedTelemetrySample(date: date, driverNumber: driver,
                            speed: Self.bounded(channels["2"].double, range: 0...500),
                            throttle: Self.bounded(channels["4"].double, range: 0...100), brake: brake,
                            gear: channels["3"].int.flatMap { (0...8).contains($0) ? $0 : nil },
                            rpm: channels["0"].int.flatMap { (0...25000).contains($0) ? $0 : nil },
                            drs: DRSStatus.recorded(channels["45"].int)))
                    }
                }
            }
        default: throw ProviderError.invalidData("The historical archive topic is unsupported.")
        }
    }

    mutating func finish() throws -> ReplayArchive {
        if let finalizedAt, finalizedAt > archive.session.startsAt {
            archive.session.endsAt = finalizedAt
        }
        if let end = archive.session.endsAt {
            let range = archive.session.startsAt.addingTimeInterval(-2)...end.addingTimeInterval(2)
            archive.locations.removeAll { !range.contains($0.date) }
            archive.telemetry.removeAll { !range.contains($0.date) }
        }
        archive.laps = timing.laps
        archive.positions = timing.positions
        archive.intervals = timing.intervals
        archive.pits = timing.allPits
        archive.driverStatuses = timing.driverStatuses
        archive.statuses.append(contentsOf: timing.phases)
        archive.sourceBestLaps = timing.sourceBestLaps
        archive.stints = stintData["Lines"].indexedValues.flatMap { key, line -> [StintSample] in
            guard let driver = Int(key) else { return [] }
            var nextLap = 1
            let rows = line["Stints"].indexedValues
            return rows.enumerated().compactMap { index, item in
                let row = item.1
                guard let compound = row["Compound"].string else { return nil }
                let age = max(0, min(10000, row["StartLaps"].int ?? 0))
                let total = max(0, min(10000, row["TotalLaps"].int ?? age))
                let completed = max(0, total - age)
                let start = nextLap
                let end = index == rows.count - 1 ? max(start, timing.completedLaps(for: driver)) : start + max(0, completed - 1)
                nextLap = end + 1
                return StintSample(driverNumber: driver, compound: compound, startLap: start, endLap: end, tyreAgeAtStart: age)
            }
        }
        archive.messages.sort { $0.date < $1.date }
        archive.statuses.sort { $0.date < $1.date }
        archive.locations.sort { ($0.date, $0.driverNumber) < ($1.date, $1.driverNumber) }
        archive.telemetry.sort { ($0.date, $0.driverNumber) < ($1.date, $1.driverNumber) }
        guard !archive.drivers.isEmpty, !archive.laps.isEmpty,
              !archive.locations.isEmpty, !archive.telemetry.isEmpty else {
            throw ProviderError.invalidData("This historical session is missing the timing, coordinates, or telemetry needed for a complete replay.")
        }
        return archive
    }

    private func requireEpoch() throws -> Date {
        guard let epoch else { throw ProviderError.invalidData("Load the historical replay clock before timing data.") }
        return epoch
    }
    private func sampleLimit() -> ProviderError { .invalidData("This historical session exceeds the supported telemetry size.") }
    private static func bounded(_ value: Double?, range: ClosedRange<Double>) -> Double? {
        value.flatMap { range.contains($0) ? $0 : nil }
    }
    private static func trackStatus(_ value: String) -> String {
        switch value {
        case "1": "Track clear"
        case "2": "Yellow flag"
        case "4": "Safety car"
        case "5": "Red flag"
        case "6": "Virtual safety car"
        case "7": "Virtual safety car ending"
        default: "Track status \(value)"
        }
    }
}
