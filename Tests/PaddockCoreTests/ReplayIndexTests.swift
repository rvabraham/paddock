import Foundation
import Testing

@testable import PaddockCore

struct ReplayIndexTests {
    @Test func indexedSnapshotsMatchChronologicalScanAcrossForwardAndBackwardSeeks() throws {
        let replay = try ReplayTestFixtures.replay()
        let start = replay.session.startsAt
        var dates = [start.addingTimeInterval(-1), start, start.addingTimeInterval(replay.duration)]
        for index in 0..<80 {
            dates.append(start.addingTimeInterval(Double((index * 7919) % Int(replay.duration))))
        }
        for sample in replay.laps.prefix(6) {
            dates += [
                sample.date.addingTimeInterval(-0.001), sample.date, sample.date.addingTimeInterval(0.001),
            ]
        }
        for date in dates {
            #expect(replay.snapshot(at: date) == scannedSnapshot(replay, at: date))
            #expect(
                replay.controlMessages(at: date)
                    == Array(replay.messages.filter { $0.date <= date }.reversed()))
            #expect(replay.weather(at: date) == replay.weather.last(where: { $0.date <= date })?.weather)
            var cars: [Int: TimedLocation] = [:]
            for location in replay.locations where location.date <= date {
                cars[location.position.driverNumber] = location
            }
            let expectedCars = cars.values.filter { date.timeIntervalSince($0.date) <= 3 }.map(\.position)
                .sorted { $0.driverNumber < $1.driverNumber }
            #expect(replay.carPositions(at: date) == expectedCars)
            #expect(
                replay.laps(for: 16, at: date)
                    == replay.laps.filter { $0.driverNumber == 16 && $0.date <= date })
            let starts = replay.lapStarts.filter { $0.driver == 16 }
            #expect(
                replay.lapBoundary(for: 16, at: date, direction: 1)
                    == starts.first(where: { $0.date > date.addingTimeInterval(0.5) })?.date)
            #expect(
                replay.lapBoundary(for: 16, at: date, direction: -1)
                    == starts.last(where: { $0.date < date.addingTimeInterval(-0.5) })?.date)
        }
    }

    @Test func duplicateDriverRowsDoNotCrashOrProduceDuplicateIdentities() throws {
        let raw: [String: JSONValue] = [
            "session": try json(
                #"[{"session_key":7,"date_start":"2024-01-01T12:00:00Z","session_name":"Race","year":2024}]"#),
            "drivers": try json(
                #"[{"driver_number":16,"full_name":"Old name"},{"driver_number":16,"full_name":"Charles Leclerc"}]"#
            ),
            "laps": try json(
                #"[{"driver_number":16,"lap_number":1,"date_start":"2024-01-01T12:00:00Z","lap_duration":90}]"#
            ),
        ]
        let replay = try ReplayDataset(raw: raw)
        #expect(replay.drivers.count == 1)
        #expect(
            replay.snapshot(at: replay.session.startsAt.addingTimeInterval(90)).first?.driver.name
                == "Charles Leclerc")
    }

    @Test func simultaneousLapRecordsHaveDeterministicChronologyAfterReload() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionSummary(
            key: 7, title: "Test", sessionName: "Race", country: "Test", circuit: "Test",
            startsAt: start, endsAt: nil, year: 2024)
        let driver = Driver(number: 16, name: "Driver", acronym: "DRV", team: "Team", colorHex: "FFFFFF")
        let laps = (1...3).map { RecordedLap(
            driverNumber: 16, lap: $0, startedAt: start,
            completedAt: start.addingTimeInterval(90), duration: Double(100 - $0 * 10)) }
        for order in [laps, Array(laps.reversed()), [laps[1], laps[0], laps[2]]] {
            let replay = try ReplayDataset(archive: ReplayArchive(session: session, drivers: [driver], laps: order))
            let reloaded = try ReplayDataset(archive: replay.archive)
            for dataset in [replay, reloaded] {
                #expect(dataset.recordedLaps(for: 16).map(\.lap) == [1, 2, 3])
                #expect(dataset.laps.map(\.lap) == [1, 2, 3])
                #expect(dataset.snapshot(at: start.addingTimeInterval(90))[0].lastLap == 70)
            }
        }
    }

    @Test func changingCoordinateWindowRebuildsOnlyItsLookupAndKeepsTiming() throws {
        var replay = try ReplayTestFixtures.replay()
        let date = replay.session.startsAt.addingTimeInterval(3600)
        let timing = replay.snapshot(at: date)
        replay.locations = [
            TimedLocation(
                date: date.addingTimeInterval(-4), position: CarPosition(driverNumber: 16, x: 1, y: 2)),
            TimedLocation(
                date: date.addingTimeInterval(-2), position: CarPosition(driverNumber: 4, x: 3, y: 4)),
            TimedLocation(
                date: date.addingTimeInterval(1), position: CarPosition(driverNumber: 4, x: 5, y: 6)),
        ]
        #expect(replay.snapshot(at: date) == timing)
        #expect(replay.carPositions(at: date) == [CarPosition(driverNumber: 4, x: 3, y: 4)])
        #expect(replay.carPositions(at: date.addingTimeInterval(-5)).isEmpty)
        #expect(replay.carPositions(at: date.addingTimeInterval(5)).isEmpty)
        replay.locations = []
        #expect(replay.carPositions(at: date).isEmpty)
    }

    @Test func extremeNumericValuesDoNotTrapFormatting() {
        #expect(formatLapTime(Double.greatestFiniteMagnitude) == "—")
        #expect(formatRaceTime(Double.greatestFiniteMagnitude) == "0:00")
        #expect(formatRaceTime(-Double.greatestFiniteMagnitude) == "0:00")
        #expect(JSONValue.number(Double.greatestFiniteMagnitude).string != nil)
        #expect(JSONValue.number(Double(Int.min)).string == String(Int.min))
        #expect(JSONValue.number(Double(Int.min)).int == Int.min)
        #expect(JSONValue.number(Double(Int.max)).int == nil)
        #expect(JSONValue.string("1e400").double == nil)
        #expect(JSONValue.string("-Infinity").double == nil)
        #expect(JSONValue.number(.infinity).int == nil)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
    private func scannedSnapshot(_ replay: ReplayDataset, at date: Date) -> [DriverState] {
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
