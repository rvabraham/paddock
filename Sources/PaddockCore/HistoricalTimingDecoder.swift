import Foundation

struct HistoricalTimingDecoder {
    private struct CountUpdate { var lap: Int; var date: Date }
    private struct TimeUpdate { var duration: Double; var date: Date }
    private var lines: [Int: JSONValue] = [:]
    private var countUpdates: [Int: CountUpdate] = [:]
    private var timeUpdates: [Int: TimeUpdate] = [:]
    private var lapCountOffsets: [Int: Int] = [:]
    private var completed: [String: RecordedLap] = [:]
    private var pitEntries: [Int: (date: Date, lap: Int?)] = [:]
    private(set) var positions: [RecordedPosition] = []
    private(set) var intervals: [RecordedInterval] = []
    private(set) var pits: [RecordedPitInterval] = []
    private(set) var driverStatuses: [RecordedDriverStatus] = []
    private(set) var phases: [RecordedStatus] = []
    private(set) var sourceBestLaps: [RecordedBestLap] = []
    private var phase: QualifyingPhase?
    private let countsCompletedLaps: Bool
    private var raceStartedAt: Date?

    init(countsCompletedLaps: Bool = false) { self.countsCompletedLaps = countsCompletedLaps }

    mutating func recordRaceStart(at date: Date) {
        if countsCompletedLaps, raceStartedAt == nil { raceStartedAt = date }
    }

    mutating func apply(_ patch: JSONValue, at date: Date) {
        if let part = patch["SessionPart"].int, let next = Self.phase(part), next != phase {
            phase = next
            phases.append(RecordedStatus(date: date, kind: .session, status: next.rawValue, phase: next))
            for driver in lines.keys {
                intervals.append(RecordedInterval(date: date, driver: driver, gap: "—", interval: "—"))
            }
        }
        for (key, update) in patch["Lines"].indexedValues {
            guard let driver = Int(key), (1...999).contains(driver) else { continue }
            let previous = lines[driver] ?? .null
            let line = previous.merging(update)
            lines[driver] = line
            if update["BestLapTime"].object?["Value"] != nil {
                let time = ProviderDecoders.lapTime(update["BestLapTime"]["Value"])
                    .flatMap { $0 > 0 && $0 <= 86400 ? $0 : nil }
                sourceBestLaps.append(RecordedBestLap(date: date, driverNumber: driver, time: time))
            }
            if let position = update["Position"].int, (1...100).contains(position) {
                positions.append(RecordedPosition(date: date, driver: driver, position: position))
            }
            if update["GapToLeader"] != .null || update["IntervalToPositionAhead"] != .null {
                let gap = line["GapToLeader"].string ?? "—"
                intervals.append(RecordedInterval(date: date, driver: driver,
                    gap: line["Position"].int == 1 ? "LEADER" : gap.isEmpty ? "—" : gap,
                    interval: line["IntervalToPositionAhead"]["Value"].string ?? "—"))
            } else if let phase, update["Stats"] != .null {
                let key = phase == .q1 ? "0" : phase == .q2 ? "1" : "2"
                let stats = line["Stats"].indexedValues.first { $0.0 == key }?.1 ?? .null
                let gap = stats["TimeDiffToFastest"].string ?? "—"
                intervals.append(RecordedInterval(date: date, driver: driver,
                    gap: line["Position"].int == 1 ? "LEADER" : gap.isEmpty ? "—" : gap,
                    interval: stats["TimeDifftoPositionAhead"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "—"))
            }
            if let retired = update["Retired"].bool, retired != previous["Retired"].bool {
                driverStatuses.append(RecordedDriverStatus(date: date, driverNumber: driver,
                    status: retired ? .retired : .racing))
            }
            if let first = Self.lapCount(update["NumberOfLaps"]), first > 0,
               lapCountOffsets[driver] == nil {
                lapCountOffsets[driver] = !countsCompletedLaps && first == 1 && update["PitOut"].bool == true ? 1 : 0
            }
            let offset = lapCountOffsets[driver] ?? 0
            let count = Self.lapCount(line["NumberOfLaps"]).map { max(0, $0 - offset) }
            if let inPit = update["InPit"].bool, inPit != previous["InPit"].bool {
                if inPit {
                    pitEntries[driver] = (date, count.map { $0 + 1 })
                } else if let entry = pitEntries.removeValue(forKey: driver) {
                    pits.append(RecordedPitInterval(driverNumber: driver, enteredAt: entry.date,
                        exitedAt: date, lap: entry.lap))
                }
            }
            if let newCount = Self.lapCount(update["NumberOfLaps"]),
               newCount > (Self.lapCount(previous["NumberOfLaps"]) ?? 0) {
                if newCount > offset {
                    countUpdates[driver] = CountUpdate(lap: newCount - offset, date: date)
                }
                if countsCompletedLaps, newCount == 1, let start = raceStartedAt, date > start {
                    completed["\(driver)-1"] = RecordedLap(driverNumber: driver, lap: 1,
                        startedAt: start, completedAt: date,
                        sector1: Self.sector(line, index: 0), sector2: Self.sector(line, index: 1),
                        sector3: Self.sector(line, index: 2))
                }
            }
            if update["LastLapTime"] != .null,
               let duration = ProviderDecoders.lapTime(update["LastLapTime"]["Value"]),
               duration > 0, duration <= 86400 {
                timeUpdates[driver] = TimeUpdate(duration: duration, date: date)
            } else if update["LastLapTime"].object?["Value"] != nil {
                timeUpdates[driver] = nil
            }
            if timeUpdates[driver] == nil, let count = countUpdates[driver],
               abs(count.date.timeIntervalSince(date)) <= 5,
               let first = Self.sector(line, index: 0), let second = Self.sector(line, index: 1),
               let third = Self.sector(line, index: 2), first > 0, second > 0, third > 0 {
                timeUpdates[driver] = TimeUpdate(duration: first + second + third, date: date)
            }
            if let count = countUpdates[driver], let time = timeUpdates[driver],
               abs(count.date.timeIntervalSince(time.date)) <= 10 {
                let identity = "\(driver)-\(count.lap)"
                var lap = completed[identity] ?? RecordedLap(driverNumber: driver, lap: count.lap,
                    startedAt: count.date.addingTimeInterval(-time.duration), completedAt: count.date,
                    duration: time.duration, phase: phase)
                if date.timeIntervalSince(count.date) <= 10 {
                    lap.sector1 = Self.sector(line, index: 0) ?? lap.sector1
                    lap.sector2 = Self.sector(line, index: 1) ?? lap.sector2
                    lap.sector3 = Self.sector(line, index: 2) ?? lap.sector3
                    lap.duration = time.duration
                    lap.startedAt = count.date.addingTimeInterval(-time.duration)
                    completed[identity] = lap
                }
            }
        }
    }

    var laps: [RecordedLap] {
        completed.values.map { original in
            var lap = original
            lap.isPitIn = pits.contains { $0.driverNumber == lap.driverNumber && $0.lap == lap.lap }
            lap.isPitOut = pits.contains {
                guard $0.driverNumber == lap.driverNumber, let exit = $0.exitedAt, let end = lap.completedAt else { return false }
                return exit >= lap.startedAt && exit <= end
            }
            return lap
        }.sorted { ($0.startedAt, $0.driverNumber, $0.lap) < ($1.startedAt, $1.driverNumber, $1.lap) }
    }

    var allPits: [RecordedPitInterval] {
        pits + pitEntries.map { RecordedPitInterval(driverNumber: $0.key, enteredAt: $0.value.date, lap: $0.value.lap) }
    }

    func completedLaps(for driver: Int) -> Int {
        completed.values.filter { $0.driverNumber == driver }.map(\.lap).max() ?? 0
    }

    private static func lapCount(_ value: JSONValue) -> Int? {
        value.int.flatMap { (0...10000).contains($0) ? $0 : nil }
    }
    private static func phase(_ part: Int) -> QualifyingPhase? {
        switch part { case 1: .q1; case 2: .q2; case 3: .q3; default: nil }
    }
    private static func sector(_ line: JSONValue, index: Int) -> Double? {
        let values = line["Sectors"]
        let row = values.object?[String(index)] ?? (values.array.indices.contains(index) ? values.array[index] : .null)
        return ProviderDecoders.lapTime(row["Value"]).flatMap { $0 > 0 ? $0 : nil }
    }
}
