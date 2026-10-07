import CoreFoundation
import Foundation

public enum CoverageMode: String, Codable, Sendable { case idle, replay }

public struct SessionSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { key }
    public var isQualifying: Bool {
        sessionName.localizedCaseInsensitiveContains("qualifying")
            || sessionName.localizedCaseInsensitiveContains("shootout")
    }
    public func matchesScheduledName(_ name: String) -> Bool {
        Self.scheduledName(sessionName) == Self.scheduledName(name)
    }
    private static func scheduledName(_ name: String) -> String {
        let normalized = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized == "sprint shootout" ? "sprint qualifying" : normalized
    }
    public var key: Int
    public var title: String
    public var sessionName: String
    public var country: String
    public var circuit: String
    public var startsAt: Date
    public var endsAt: Date?
    public var year: Int
    public init(
        key: Int, title: String, sessionName: String, country: String, circuit: String, startsAt: Date,
        endsAt: Date?, year: Int
    ) {
        self.key = key
        self.title = title
        self.sessionName = sessionName
        self.country = country
        self.circuit = circuit
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.year = year
    }
}

public struct Driver: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { number }
    public var number: Int
    public var name: String
    public var acronym: String
    public var team: String
    public var colorHex: String
    public init(number: Int, name: String, acronym: String, team: String, colorHex: String) {
        self.number = number
        self.name = name
        self.acronym = acronym
        self.team = team
        self.colorHex = colorHex
    }
}

public struct DriverState: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { driver.number }
    public var driver: Driver
    public var position: Int?
    public var lap: Int
    public var gap: String
    public var interval: String
    public var lastLap: Double?
    public var bestLap: Double?
    public var sector1: Double?
    public var sector2: Double?
    public var sector3: Double?
    public var compound: String
    public var tyreAge: Int?
    public var inPit: Bool
    public var status: DriverRaceStatus
    public init(
        driver: Driver, position: Int? = nil, lap: Int = 0, gap: String = "—", interval: String = "—",
        lastLap: Double? = nil, bestLap: Double? = nil, sector1: Double? = nil, sector2: Double? = nil,
        sector3: Double? = nil, compound: String = "UNKNOWN", tyreAge: Int? = nil, inPit: Bool = false,
        status: DriverRaceStatus = .unknown
    ) {
        self.driver = driver
        self.position = position
        self.lap = lap
        self.gap = gap
        self.interval = interval
        self.lastLap = lastLap
        self.bestLap = bestLap
        self.sector1 = sector1
        self.sector2 = sector2
        self.sector3 = sector3
        self.compound = compound
        self.tyreAge = tyreAge
        self.inPit = inPit
        self.status = status
    }
}

public struct LapSample: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(driverNumber)-\(lap)" }
    public var driverNumber: Int
    public var lap: Int
    public var time: Double?
    public var sector1: Double?
    public var sector2: Double?
    public var sector3: Double?
    /// The moment the completed lap became known, not the start of that lap.
    public var date: Date
    public init(
        driverNumber: Int, lap: Int, time: Double?, sector1: Double? = nil, sector2: Double? = nil,
        sector3: Double? = nil, date: Date
    ) {
        self.driverNumber = driverNumber
        self.lap = lap
        self.time = time
        self.sector1 = sector1
        self.sector2 = sector2
        self.sector3 = sector3
        self.date = date
    }
}

public struct StintSample: Hashable, Codable, Sendable {
    public var driverNumber: Int
    public var compound: String
    public var startLap: Int
    public var endLap: Int?
    public var tyreAgeAtStart: Int
    public init(driverNumber: Int, compound: String, startLap: Int, endLap: Int?, tyreAgeAtStart: Int) {
        self.driverNumber = driverNumber
        self.compound = compound
        self.startLap = startLap
        self.endLap = endLap
        self.tyreAgeAtStart = tyreAgeAtStart
    }
}

public struct ControlMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var date: Date
    public var text: String
    public var category: String
    public var flag: String?
    public init(id: String, date: Date, text: String, category: String, flag: String?) {
        self.id = id
        self.date = date
        self.text = text
        self.category = category
        self.flag = flag
    }
}

public struct WeatherInfo: Hashable, Codable, Sendable {
    public var air: Double?
    public var track: Double?
    public var humidity: Double?
    public var windSpeed: Double?
    public var rainfall: Bool?
    public init(air: Double?, track: Double?, humidity: Double?, windSpeed: Double?, rainfall: Bool?) {
        self.air = air
        self.track = track
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.rainfall = rainfall
    }
}

public struct TrackPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
public struct CarPosition: Hashable, Codable, Sendable {
    public var driverNumber: Int
    public var x: Double
    public var y: Double
    public init(driverNumber: Int, x: Double, y: Double) {
        self.driverNumber = driverNumber
        self.x = x
        self.y = y
    }
}
public struct WeekendSession: Hashable, Codable, Sendable {
    public var name: String
    public var date: Date
    public var hasKnownTime: Bool
    public init(name: String, date: Date, hasKnownTime: Bool = true) {
        self.name = name
        self.date = date
        self.hasKnownTime = hasKnownTime
    }
}
public struct RaceWeekend: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { round }
    public var round: Int
    public var name: String
    public var country: String
    public var circuit: String
    public var date: Date
    public var sessions: [WeekendSession]
    public var hasKnownTime: Bool
    public init(
        round: Int, name: String, country: String, circuit: String, date: Date, sessions: [WeekendSession],
        hasKnownTime: Bool = true
    ) {
        self.round = round
        self.name = name
        self.country = country
        self.circuit = circuit
        self.date = date
        self.sessions = sessions
        self.hasKnownTime = hasKnownTime
    }
}
public struct Standing: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var position: Int
    public var name: String
    public var team: String
    public var colorHex: String
    public var points: Double
    public var wins: Int
    public init(
        id: String, position: Int, name: String, team: String, colorHex: String, points: Double, wins: Int
    ) {
        self.id = id
        self.position = position
        self.name = name
        self.team = team
        self.colorHex = colorHex
        self.points = points
        self.wins = wins
    }
}

public func formatLapTime(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    let rounded = (seconds * 1000).rounded()
    guard rounded.isFinite, rounded < Double(Int.max) else { return "—" }
    let millis = Int(rounded)
    return String(format: "%d:%02d.%03d", millis / 60000, (millis / 1000) % 60, millis % 1000)
}
public func formatRaceTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(max(0, seconds))
    return value >= 3600
        ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    public static func decode(_ data: Data) throws -> JSONValue {
        try autoreleasepool {
            try JSONValue(
                foundationValue: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
    }
    private init(foundationValue: Any) throws {
        switch foundationValue {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [String: Any]:
            self = .object(try value.mapValues { try JSONValue(foundationValue: $0) })
        case let value as [Any]: self = .array(try value.map { try JSONValue(foundationValue: $0) })
        case is NSNull: self = .null
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported JSON value."))
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .array(try c.decode([JSONValue].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    public var array: [JSONValue] {
        if case .array(let v) = self { return v }
        return []
    }
    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.isFinite && n == floor(n) && n >= Double(Int.min) && n < Double(Int.max)
                ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    public var double: Double? {
        let value: Double?
        switch self {
        case .number(let number): value = number
        case .string(let string): value = Double(string)
        default: value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    public var int: Int? {
        double.flatMap {
            $0.rounded() == $0 && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil
        }
    }
    public var bool: Bool? {
        if case .bool(let v) = self { return v }
        if let n = int { return n != 0 }
        return nil
    }
    public var indexedValues: [(String, JSONValue)] {
        if let object { return object.sorted { (Int($0.key) ?? Int.max) < (Int($1.key) ?? Int.max) } }
        return array.enumerated().map { (String($0.offset), $0.element) }
    }
    public func merging(_ patch: JSONValue) -> JSONValue {
        if let base = object, let updates = patch.object {
            var result = base
            for (key, value) in updates { result[key] = (result[key] ?? .null).merging(value) }
            return .object(result)
        }
        // Recorded timing archives can encode sparse array updates by index.
        if case .array(let values) = self, let updates = patch.object {
            var result = values
            for (key, value) in updates {
                guard let i = Int(key), i >= 0, i < 10000 else { continue }
                while result.count <= i { result.append(.null) }
                result[i] = result[i].merging(value)
            }
            return .array(result)
        }
        return patch
    }
}

public enum RaceDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    public static func parse(_ value: String?) -> Date? {
        guard var value, !value.isEmpty else { return nil }
        // Upstream sometimes omits the timezone; F1 topic timestamps are UTC.
        let suffix = value.suffix(6)
        let hasOffset = (suffix.first == "+" || suffix.first == "-") && suffix.contains(":")
        if !value.hasSuffix("Z"), !hasOffset { value += "Z" }
        // Format styles are immutable and safe to share across concurrent archive loads.
        return (try? fractional.parse(value)) ?? (try? wholeSeconds.parse(value))
    }
}
