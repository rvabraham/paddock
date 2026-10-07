import Foundation

@main struct CoreBenchmark {
    private static func measure(_ name: String, _ action: () throws -> Int) rethrows {
        let start = ContinuousClock.now
        let checksum = try action()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        print("\(name): \(String(format: "%.6f", seconds)) seconds; checksum \(checksum)")
    }
    static func main() throws {
        let iterations = max(1, Int(CommandLine.arguments.dropFirst().first ?? "2000") ?? 2000)
        if CommandLine.arguments.contains("--recorded-only") {
            measureRecordedSamples()
            return
        }
        let archive = makeSyntheticArchive()
        let encoded = try JSONEncoder().encode(archive)
        try measure("Decode five synthetic archives with Codable reference") {
            var checksum = 0
            for _ in 0..<5 {
                checksum += try JSONDecoder().decode(JSONValue.self, from: encoded)["laps"].array.count
            }
            return checksum
        }
        try measure("Decode five synthetic archives with JSONValue") {
            var checksum = 0
            for _ in 0..<5 { checksum += try JSONValue.decode(encoded)["laps"].array.count }
            return checksum
        }
        let replay = try ReplayDataset(archive: archive)
        print(
            "Synthetic benchmark rows: \(replay.drivers.count) drivers, \(replay.laps.count) laps, \(replay.intervals.count) intervals, \(replay.locations.count) coordinates"
        )
        measure("\(iterations) scan reference random snapshots") {
            var checksum = 0
            for index in 0..<iterations {
                let date = replay.session.startsAt.addingTimeInterval(
                    Double((index * 7919) % Int(replay.duration)))
                checksum += scannedSnapshot(replay, at: date).first?.lap ?? 0
            }
            return checksum
        }
        measure("\(iterations) indexed random snapshots") {
            var checksum = 0
            for index in 0..<iterations {
                let date = replay.session.startsAt.addingTimeInterval(
                    Double((index * 7919) % Int(replay.duration)))
                checksum += replay.snapshot(at: date).first?.lap ?? 0
            }
            return checksum
        }
        measure("\(iterations) indexed full sequential state") {
            var checksum = 0
            for index in 0..<iterations {
                let date = replay.session.startsAt.addingTimeInterval(
                    Double(index) / Double(iterations) * replay.duration)
                checksum +=
                    (replay.snapshot(at: date).first?.lap ?? 0) + replay.controlMessages(at: date).count
                    + replay.carPositions(at: date).count + Int(replay.weather(at: date)?.air ?? 0)
            }
            return checksum
        }
        measure("\(iterations) indexed selected driver histories") {
            var checksum = 0
            for index in 0..<iterations {
                let date = replay.session.startsAt.addingTimeInterval(
                    Double(index) / Double(iterations) * replay.duration)
                checksum +=
                    replay.laps(for: 16, at: date).count + replay.visibleStints(for: 16, at: date).count
            }
            return checksum
        }
    }
    private static func makeSyntheticArchive() -> ReplayArchive {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionSummary(
            key: 7, title: "Synthetic benchmark", sessionName: "Race", country: "Test", circuit: "Test",
            startsAt: start, endsAt: start.addingTimeInterval(7200), year: 2023)
        let drivers = (1...20).map {
            Driver(number: $0, name: "Driver \($0)", acronym: "D\($0)", team: "Team", colorHex: "FFFFFF")
        }
        var laps: [RecordedLap] = []
        var positions: [RecordedPosition] = []
        var intervals: [RecordedInterval] = []
        var locations: [RecordedCarSample] = []
        for driver in drivers {
            for lap in 1...80 {
                laps.append(RecordedLap(
                    driverNumber: driver.number, lap: lap,
                    startedAt: start.addingTimeInterval(Double(lap - 1) * 90),
                    completedAt: start.addingTimeInterval(Double(lap) * 90), duration: 90))
            }
            for index in 0...720 {
                let seconds = Double(index) * 10
                let date = start.addingTimeInterval(seconds)
                let angle = seconds / 90 * 2 * Double.pi
                positions.append(RecordedPosition(date: date, driver: driver.number, position: driver.number))
                intervals.append(RecordedInterval(
                    date: date, driver: driver.number, gap: "+\(driver.number)", interval: "+1"))
                locations.append(RecordedCarSample(
                    date: date, driverNumber: driver.number, x: 1000 * cos(angle), y: 1000 * sin(angle)))
            }
        }
        return ReplayArchive(
            session: session, drivers: drivers, laps: laps, positions: positions,
            intervals: intervals, locations: locations)
    }
    private static func measureRecordedSamples() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionSummary(
            key: 7, title: "Benchmark", sessionName: "Race", country: "Test", circuit: "Test",
            startsAt: start, endsAt: start.addingTimeInterval(7200), year: 2023)
        let drivers = (1...20).map {
            Driver(number: $0, name: "Driver \($0)", acronym: "D\($0)", team: "Team", colorHex: "FFFFFF")
        }
        let laps = drivers.map {
            RecordedLap(
                driverNumber: $0.number, lap: 1, startedAt: start, completedAt: start.addingTimeInterval(90),
                duration: 90)
        }
        var locations: [RecordedCarSample] = []
        var telemetry: [RecordedTelemetrySample] = []
        locations.reserveCapacity(576020)
        telemetry.reserveCapacity(576020)
        for driver in drivers {
            for index in 0...28800 {
                let seconds = Double(index) / 4
                let angle = seconds / 90 * 2 * Double.pi
                let date = start.addingTimeInterval(seconds)
                locations.append(
                    RecordedCarSample(
                        date: date, driverNumber: driver.number, x: 1000 * cos(angle), y: 1000 * sin(angle)))
                telemetry.append(
                    RecordedTelemetrySample(
                        date: date, driverNumber: driver.number, speed: 200 + Double(index % 50),
                        throttle: 80, brake: false, gear: 7, rpm: 11000, drs: .off))
            }
        }
        var dataset: ReplayDataset?
        try! measure("Prepare two-hour synthetic source-rate dataset") {
            dataset = try ReplayDataset(
                archive: ReplayArchive(
                    session: session, drivers: drivers, laps: laps, locations: locations, telemetry: telemetry
                ))
            return dataset!.archive.locations.count + dataset!.archive.telemetry.count
        }
        let replay = dataset!
        print(
            "Synthetic benchmark rows: \(locations.count) coordinates, \(telemetry.count) telemetry; \(MemoryLayout<RecordedCarSample>.stride) and \(MemoryLayout<RecordedTelemetrySample>.stride) bytes per typed sample"
        )
        measure("10000 source-rate map and selected-driver cursors") {
            var checksum = 0
            for index in 0..<10000 {
                let seconds = Double((index * 7919) % 7200) + 0.123
                let date = start.addingTimeInterval(seconds)
                checksum += replay.interpolatedPositions(at: date).count
                checksum += Int(replay.telemetry(for: 16, at: date).speed ?? 0)
            }
            return checksum
        }
        measure("10000 full timing snapshots") {
            var checksum = 0
            for index in 0..<10000 {
                checksum += replay.snapshot(at: start.addingTimeInterval(Double((index * 7919) % 7200))).count
            }
            return checksum
        }
    }
    private static func scannedSnapshot(_ replay: ReplayDataset, at date: Date) -> [DriverState] {
        var state = Dictionary(
            uniqueKeysWithValues: replay.drivers.map { ($0.number, DriverState(driver: $0)) })
        for entry in replay.positions where entry.date <= date {
            state[entry.driver]?.position = entry.position
        }
        for entry in replay.lapStarts where entry.date <= date {
            let lap = max(state[entry.driver]?.lap ?? 0, entry.lap)
            state[entry.driver]?.lap = lap
        }
        for entry in replay.intervals where entry.date <= date {
            state[entry.driver]?.gap = entry.gap
            state[entry.driver]?.interval = entry.interval
        }
        for lap in replay.laps where lap.date <= date {
            state[lap.driverNumber]?.lastLap = lap.time
            let best = min(state[lap.driverNumber]?.bestLap ?? .infinity, lap.time ?? .infinity)
            state[lap.driverNumber]?.bestLap = best
            state[lap.driverNumber]?.sector1 = lap.sector1
            state[lap.driverNumber]?.sector2 = lap.sector2
            state[lap.driverNumber]?.sector3 = lap.sector3
        }
        for stint in replay.stints {
            guard let lap = state[stint.driverNumber]?.lap, lap >= stint.startLap else { continue }
            state[stint.driverNumber]?.compound = stint.compound
            state[stint.driverNumber]?.tyreAge = stint.tyreAgeAtStart + max(0, lap - stint.startLap)
        }
        return state.values.sorted { ($0.position ?? 999, $0.id) < ($1.position ?? 999, $1.id) }
    }
}
