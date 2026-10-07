import Foundation

enum ReplaySampleCodec {
    static func encode(_ samples: [RecordedCarSample]) throws -> Data {
        guard samples.count <= ReplayArchiveStore.maximumSamples else { throw invalid }
        var writer = Writer(count: samples.count, width: 36)
        for sample in samples {
            try writer.date(sample.date); try writer.driver(sample.driverNumber)
            try writer.number(sample.x); try writer.number(sample.y); try writer.optional(sample.z)
        }
        return writer.data
    }
    static func encode(_ samples: [RecordedTelemetrySample]) throws -> Data {
        guard samples.count <= ReplayArchiveStore.maximumSamples else { throw invalid }
        var writer = Writer(count: samples.count, width: 46)
        for sample in samples {
            try writer.date(sample.date); try writer.driver(sample.driverNumber)
            try writer.optional(sample.speed); try writer.optional(sample.throttle)
            writer.integer(UInt8(sample.brake.map { $0 ? 1 : 0 } ?? 2))
            try writer.optionalInteger(sample.gear); try writer.optionalInteger(sample.rpm)
            writer.integer(sample.drs.map { UInt8(DRSStatus.allRecordedCases.firstIndex(of: $0)!) } ?? 255)
            try writer.optional(sample.distance)
        }
        return writer.data
    }
    static func locations(_ data: Data) throws -> [RecordedCarSample] {
        var reader = try Reader(data, width: 36)
        var samples: [RecordedCarSample] = []; samples.reserveCapacity(reader.count)
        for _ in 0..<reader.count {
            samples.append(try RecordedCarSample(date: reader.date(), driverNumber: reader.driver(),
                x: reader.number(), y: reader.number(), z: reader.optional()))
        }
        return samples
    }
    static func telemetry(_ data: Data) throws -> [RecordedTelemetrySample] {
        var reader = try Reader(data, width: 46)
        var samples: [RecordedTelemetrySample] = []; samples.reserveCapacity(reader.count)
        for _ in 0..<reader.count {
            let date = try reader.date(), driver = try reader.driver()
            let speed = try reader.optional(), throttle = try reader.optional()
            let brake: UInt8 = reader.integer()
            let gear = reader.optionalInteger(), rpm = reader.optionalInteger()
            let drs: UInt8 = reader.integer()
            guard brake <= 2, drs == 255 || drs < DRSStatus.allRecordedCases.count else { throw invalid }
            samples.append(RecordedTelemetrySample(date: date, driverNumber: driver, speed: speed, throttle: throttle,
                brake: brake == 2 ? nil : brake == 1, gear: gear, rpm: rpm,
                drs: drs == 255 ? nil : DRSStatus.allRecordedCases[Int(drs)], distance: try reader.optional()))
        }
        return samples
    }
    static func locations(_ rows: [JSONValue], session: SessionSummary, start: Date, end: Date) throws -> [RecordedCarSample] {
        try validateRows(rows, session: session)
        return rows.compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), date >= start, date < end,
                  let driver = row["driver_number"].int, (1...999).contains(driver),
                  let x = row["x"].double, let y = row["y"].double, x.isFinite, y.isFinite else { return nil }
            return RecordedCarSample(date: date, driverNumber: driver, x: x, y: y, z: finite(row["z"].double))
        }
    }
    static func telemetry(_ rows: [JSONValue], session: SessionSummary, start: Date, end: Date) throws -> [RecordedTelemetrySample] {
        try validateRows(rows, session: session)
        return rows.compactMap { row in
            guard let date = RaceDate.parse(row["date"].string), date >= start, date < end,
                  let driver = row["driver_number"].int, (1...999).contains(driver) else { return nil }
            return RecordedTelemetrySample(date: date, driverNumber: driver, speed: finite(row["speed"].double),
                throttle: finite(row["throttle"].double), brake: row["brake"].int.map { $0 != 0 },
                gear: row["n_gear"].int, rpm: row["rpm"].int, drs: DRSStatus.recorded(row["drs"].int))
        }
    }
    private static func validateRows(_ rows: [JSONValue], session: SessionSummary) throws {
        guard rows.count <= 250_000, rows.allSatisfy({ $0["session_key"].int == session.key }) else { throw invalid }
    }
    private static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    private static var invalid: ProviderError { .invalidData("The replay samples are damaged or belong to another session.") }

    private struct Writer {
        var data = Data()
        init(count: Int, width: Int) { data.reserveCapacity(4 + count * width); integer(UInt32(count)) }
        mutating func integer<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        mutating func date(_ value: Date) throws { try number(value.timeIntervalSince1970) }
        mutating func driver(_ value: Int) throws {
            guard (1...999).contains(value) else { throw ReplaySampleCodec.invalid }; integer(Int32(value))
        }
        mutating func number(_ value: Double) throws {
            guard value.isFinite else { throw ReplaySampleCodec.invalid }; integer(value.bitPattern)
        }
        mutating func optional(_ value: Double?) throws {
            if let value { try number(value) } else { integer(Double.nan.bitPattern) }
        }
        mutating func optionalInteger(_ value: Int?) throws {
            guard value == nil || ((0...100_000).contains(value!)) else { throw ReplaySampleCodec.invalid }
            integer(value.map(Int32.init) ?? Int32.min)
        }
    }
    private struct Reader {
        let data: Data
        let count: Int
        var offset = 4
        init(_ data: Data, width: Int) throws {
            guard data.count >= 4 else { throw ReplaySampleCodec.invalid }
            let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard count <= ReplayArchiveStore.maximumSamples, data.count == 4 + count * width else { throw ReplaySampleCodec.invalid }
            self.data = data; self.count = count
        }
        mutating func integer<T: FixedWidthInteger>() -> T {
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        mutating func number() throws -> Double {
            let value = Double(bitPattern: integer())
            guard value.isFinite else { throw ReplaySampleCodec.invalid }; return value
        }
        mutating func date() throws -> Date { Date(timeIntervalSince1970: try number()) }
        mutating func driver() throws -> Int {
            let value: Int32 = integer()
            guard (1...999).contains(value) else { throw ReplaySampleCodec.invalid }; return Int(value)
        }
        mutating func optional() throws -> Double? {
            let value = Double(bitPattern: integer())
            if value.isNaN { return nil }
            guard value.isFinite else { throw ReplaySampleCodec.invalid }; return value
        }
        mutating func optionalInteger() -> Int? {
            let value: Int32 = integer(); return value == .min ? nil : Int(value)
        }
    }
}

private extension DRSStatus {
    static let allRecordedCases: [Self] = [.off, .available, .on, .unknown]
}
