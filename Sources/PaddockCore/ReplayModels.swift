import Foundation

public enum QualifyingPhase: String, CaseIterable, Codable, Sendable {
    case q1 = "Q1"
    case q2 = "Q2"
    case q3 = "Q3"
}

public enum DriverRaceStatus: String, Codable, Sendable {
    case racing, inPit, retired, finished, unknown
}

public enum DRSStatus: String, Codable, Sendable {
    case off, available, on, unknown
    public var label: String { rawValue.capitalized }
    static func recorded(_ value: Int?) -> Self? {
        guard let value else { return nil }
        switch value {
        case 0, 1: return .off
        case 8: return .available
        case 10, 12, 14: return .on
        default: return .unknown
        }
    }
}

public struct RecordedCarSample: Hashable, Codable, Sendable {
    public var date: Date
    public var driverNumber: Int
    public var x: Double
    public var y: Double
    public var z: Double?
    public init(date: Date, driverNumber: Int, x: Double, y: Double, z: Double? = nil) {
        self.date = date
        self.driverNumber = driverNumber
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct RecordedTelemetrySample: Hashable, Codable, Sendable {
    public var date: Date
    public var driverNumber: Int
    public var speed: Double?
    public var throttle: Double?
    public var brake: Bool?
    public var gear: Int?
    public var rpm: Int?
    public var drs: DRSStatus?
    public var distance: Double?
    public init(
        date: Date, driverNumber: Int, speed: Double? = nil, throttle: Double? = nil,
        brake: Bool? = nil, gear: Int? = nil, rpm: Int? = nil, drs: DRSStatus? = nil,
        distance: Double? = nil
    ) {
        self.date = date
        self.driverNumber = driverNumber
        self.speed = speed
        self.throttle = throttle
        self.brake = brake
        self.gear = gear
        self.rpm = rpm
        self.drs = drs
        self.distance = distance
    }
}

public struct ReplayTelemetry: Hashable, Sendable {
    public var speed: Double?
    public var throttle: Double?
    public var brake: Bool?
    public var gear: Int?
    public var rpm: Int?
    public var drs: DRSStatus?
    public var date: Date?
    public var isStale: Bool
    public init(
        speed: Double? = nil, throttle: Double? = nil, brake: Bool? = nil, gear: Int? = nil,
        rpm: Int? = nil, drs: DRSStatus? = nil, date: Date? = nil, isStale: Bool = true
    ) {
        self.speed = speed
        self.throttle = throttle
        self.brake = brake
        self.gear = gear
        self.rpm = rpm
        self.drs = drs
        self.date = date
        self.isStale = isStale
    }
}

public struct RecordedLap: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(driverNumber)-\(lap)" }
    public var driverNumber: Int
    public var lap: Int
    public var startedAt: Date
    public var completedAt: Date?
    public var duration: Double?
    public var sector1: Double?
    public var sector2: Double?
    public var sector3: Double?
    public var phase: QualifyingPhase?
    public var isPitOut: Bool
    public var isPitIn: Bool
    public var isValid: Bool?
    public var validityChanges: [LapValidityChange]?
    public init(
        driverNumber: Int, lap: Int, startedAt: Date, completedAt: Date? = nil,
        duration: Double? = nil, sector1: Double? = nil, sector2: Double? = nil,
        sector3: Double? = nil, phase: QualifyingPhase? = nil, isPitOut: Bool = false,
        isPitIn: Bool = false, isValid: Bool? = nil, validityChanges: [LapValidityChange]? = nil
    ) {
        self.driverNumber = driverNumber
        self.lap = lap
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
        self.sector1 = sector1
        self.sector2 = sector2
        self.sector3 = sector3
        self.phase = phase
        self.isPitOut = isPitOut
        self.isPitIn = isPitIn
        self.isValid = isValid
        self.validityChanges = validityChanges
    }
    public func validity(at date: Date) -> Bool? {
        guard let changes = validityChanges, !changes.isEmpty else { return isValid }
        return changes.last(where: { $0.date <= date })?.isValid
    }
}

public struct LapValidityChange: Hashable, Codable, Sendable {
    public var date: Date
    public var isValid: Bool
    public init(date: Date, isValid: Bool) {
        self.date = date
        self.isValid = isValid
    }
}

public struct RecordedBestLap: Hashable, Codable, Sendable {
    public var date: Date
    public var driverNumber: Int
    public var time: Double?
    public init(date: Date, driverNumber: Int, time: Double?) {
        self.date = date
        self.driverNumber = driverNumber
        self.time = time
    }
}

public struct RecordedPitInterval: Hashable, Codable, Sendable {
    public var driverNumber: Int
    public var enteredAt: Date
    public var exitedAt: Date?
    public var lap: Int?
    public init(driverNumber: Int, enteredAt: Date, exitedAt: Date? = nil, lap: Int? = nil) {
        self.driverNumber = driverNumber
        self.enteredAt = enteredAt
        self.exitedAt = exitedAt
        self.lap = lap
    }
}

public struct RecordedDriverStatus: Hashable, Codable, Sendable {
    public var date: Date
    public var driverNumber: Int
    public var status: DriverRaceStatus
    public init(date: Date, driverNumber: Int, status: DriverRaceStatus) {
        self.date = date
        self.driverNumber = driverNumber
        self.status = status
    }
}

public enum ReplayStatusKind: String, Codable, Sendable { case session, track }
public struct RecordedStatus: Hashable, Codable, Sendable {
    public var date: Date
    public var kind: ReplayStatusKind
    public var status: String
    public var phase: QualifyingPhase?
    public init(date: Date, kind: ReplayStatusKind, status: String, phase: QualifyingPhase? = nil) {
        self.date = date
        self.kind = kind
        self.status = status
        self.phase = phase
    }
}

public enum ReplayEventKind: String, CaseIterable, Codable, Sendable {
    case start, finish, pit, retirement, redFlag, safetyCar, flag, qualifying, raceControl
}
public struct ReplayEvent: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var date: Date
    public var kind: ReplayEventKind
    public var title: String
    public var driverNumber: Int?
    public var lap: Int?
    public init(
        id: String, date: Date, kind: ReplayEventKind, title: String, driverNumber: Int? = nil,
        lap: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.driverNumber = driverNumber
        self.lap = lap
    }
}

public struct LapSelection: Hashable, Codable, Sendable {
    public var driverNumber: Int
    public var lap: Int
    public init(driverNumber: Int, lap: Int) {
        self.driverNumber = driverNumber
        self.lap = lap
    }
}
public struct LapTelemetryPoint: Identifiable, Hashable, Sendable {
    public var id: Double { elapsed }
    public var distance: Double
    public var elapsed: Double
    public var speed: Double?
    public var throttle: Double?
    public var brake: Bool?
    public var gear: Int?
    public var rpm: Int?
    public var drs: DRSStatus?
}
public struct LapComparisonPoint: Identifiable, Hashable, Sendable {
    public var id: Double { distance }
    public var distance: Double
    public var referenceElapsed: Double
    public var comparedElapsed: Double
    public var delta: Double { comparedElapsed - referenceElapsed }
}
public struct LapComparison: Sendable {
    public var reference: LapSelection
    public var comparison: LapSelection
    public var points: [LapComparisonPoint]
}

public struct ReplayClock: Equatable, Sendable {
    public var sessionStart: Date
    public var duration: Double
    public var anchorTime: Double
    public var anchorDate: Date
    public var rate: Double
    public var isAdvancing: Bool
    public var isRunning: Bool { isAdvancing }
    public func time(at wallDate: Date) -> Double {
        let elapsed = isAdvancing ? max(0, wallDate.timeIntervalSince(anchorDate)) * rate : 0
        return min(duration, max(0, anchorTime + elapsed))
    }
    public func sessionDate(at wallDate: Date) -> Date { sessionStart.addingTimeInterval(time(at: wallDate)) }
    public func date(at wallDate: Date) -> Date { sessionDate(at: wallDate) }
}

public struct ReplayChannelAvailability: Equatable, Sendable {
    public var coordinates: Bool
    public var telemetry: Bool
    public var pitIntervals: Bool
    public var driverStatuses: Bool
    public var qualifyingPhases: Bool
}

public struct ReplayArchive: Codable, Sendable {
    public var session: SessionSummary
    public var drivers: [Driver]
    public var laps: [RecordedLap]
    public var stints: [StintSample]
    public var messages: [ControlMessage]
    public var positions: [RecordedPosition]
    public var intervals: [RecordedInterval]
    public var weather: [RecordedWeather]
    public var locations: [RecordedCarSample]
    public var telemetry: [RecordedTelemetrySample]
    public var pits: [RecordedPitInterval]
    public var driverStatuses: [RecordedDriverStatus]
    public var statuses: [RecordedStatus]
    public var sourceBestLaps: [RecordedBestLap]?
    public init(
        session: SessionSummary, drivers: [Driver], laps: [RecordedLap], stints: [StintSample] = [],
        messages: [ControlMessage] = [], positions: [RecordedPosition] = [],
        intervals: [RecordedInterval] = [],
        weather: [RecordedWeather] = [], locations: [RecordedCarSample] = [],
        telemetry: [RecordedTelemetrySample] = [],
        pits: [RecordedPitInterval] = [], driverStatuses: [RecordedDriverStatus] = [],
        statuses: [RecordedStatus] = [], sourceBestLaps: [RecordedBestLap]? = nil
    ) {
        self.session = session
        self.drivers = drivers
        self.laps = laps
        self.stints = stints
        self.messages = messages
        self.positions = positions
        self.intervals = intervals
        self.weather = weather
        self.locations = locations
        self.telemetry = telemetry
        self.pits = pits
        self.driverStatuses = driverStatuses
        self.statuses = statuses
        self.sourceBestLaps = sourceBestLaps
    }
}

public struct RecordedPosition: Codable, Sendable {
    public var date: Date
    public var driver: Int
    public var position: Int
}
public struct RecordedInterval: Codable, Sendable {
    public var date: Date
    public var driver: Int
    public var gap: String
    public var interval: String
}
public struct RecordedWeather: Codable, Sendable {
    public var date: Date
    public var weather: WeatherInfo
}
