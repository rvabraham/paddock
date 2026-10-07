import Foundation

@testable import PaddockCore

enum ReplayTestFixtures {
    static func raw(key: Int = 7007) -> [String: JSONValue] {
        let start = Date(timeIntervalSince1970: 1_704_110_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ offset: Double) -> JSONValue {
            .string(formatter.string(from: start.addingTimeInterval(offset)))
        }
        let numbers = [1, 2, 3, 4, 5, 6, 7, 16]
        var drivers: [JSONValue] = [], laps: [JSONValue] = [], stints: [JSONValue] = []
        var positions: [JSONValue] = [], intervals: [JSONValue] = [], locations: [JSONValue] = []
        for (index, number) in numbers.enumerated() {
            let driver = JSONValue.number(Double(number))
            drivers.append(.object([
                "driver_number": driver, "full_name": .string("Test Driver \(number)"),
                "name_acronym": .string("T\(number)"), "team_name": .string("Test Team"),
                "team_colour": .string("FFFFFF")]))
            for lap in 1...10 {
                let duration = Double(90 - lap % 3)
                laps.append(.object([
                    "driver_number": driver, "lap_number": .number(Double(lap)),
                    "date_start": date(Double((lap - 1) * 90 + index)),
                    "lap_duration": .number(duration),
                    "duration_sector_1": .number(duration / 3),
                    "duration_sector_2": .number(duration / 3),
                    "duration_sector_3": .number(duration / 3)]))
            }
            for (lap, compound) in [(1, "MEDIUM"), (5, "HARD")] {
                stints.append(.object([
                    "driver_number": driver, "lap_start": .number(Double(lap)),
                    "lap_end": .number(lap == 1 ? 4 : 10), "compound": .string(compound),
                    "tyre_age_at_start": .number(0)]))
            }
            for offset in [0.0, 210, 600] {
                let position = (index + (offset == 210 ? 1 : 0)) % numbers.count + 1
                positions.append(.object([
                    "driver_number": driver, "date": date(offset),
                    "position": .number(Double(position))]))
                intervals.append(.object([
                    "driver_number": driver, "date": date(offset + 1),
                    "gap_to_leader": .number(Double(position - 1) * 1.2),
                    "interval": position == 1 ? .null : .number(1.2)]))
            }
            for offset in stride(from: 0, through: 900, by: 2) {
                let angle = Double(offset % 90) / 90 * 2 * Double.pi
                locations.append(.object([
                    "driver_number": driver, "date": date(Double(offset)),
                    "x": .number(cos(angle) * 1000), "y": .number(sin(angle) * 600)]))
            }
        }
        return [
            "session": .array([.object([
                "session_key": .number(Double(key)), "date_start": date(0), "date_end": date(660),
                "session_name": .string("Race"), "meeting_name": .string("Synthetic test session"),
                "circuit_short_name": .string("Test circuit"), "country_name": .string("Test"),
                "year": .number(2024)])]),
            "drivers": .array(drivers), "laps": .array(Array(laps.reversed())), "stints": .array(stints),
            "position": .array(Array(positions.reversed())), "intervals": .array(Array(intervals.reversed())),
            "location": .array(locations),
            "race_control": .array([
                .object(["date": date(0), "message": .string("SESSION STARTED"), "category": .string("Session")]),
                .object(["date": date(120), "message": .string("SESSION ABORTED"), "flag": .string("RED")]),
                .object(["date": date(240), "message": .string("SESSION RESUMED"), "category": .string("Session")]),
                .object(["date": date(905), "message": .string("CHEQUERED FLAG"), "flag": .string("CHEQUERED")])]),
            "weather": .array([
                .object(["date": date(0), "air_temperature": .number(20), "track_temperature": .number(30),
                    "humidity": .number(60), "wind_speed": .number(2), "rainfall": .number(0)]),
                .object(["date": date(500), "air_temperature": .number(21), "track_temperature": .number(32),
                    "humidity": .null, "rainfall": .bool(false)])])]
    }

    static func replay(key: Int = 7007) throws -> ReplayDataset {
        try ReplayDataset(raw: raw(key: key))
    }

    @discardableResult
    static func saveRecording(
        _ key: Int = 7007, directory: URL, valid: Bool = true,
        updatedAt: Date? = nil
    ) throws -> SessionSummary {
        var archive = try replay(key: key).archive
        if !valid { archive.drivers = [] }
        var storage = ReplayArchiveStore(directory: directory)
        var manifest = try storage.begin(
            session: archive.session, source: "test", chunks: [ReplayChunk(id: "archive", channel: "metadata")])
        try ReplayArchivePersistence.save(archive, manifest: &manifest, store: &storage)
        try storage.finish(manifest)
        if let updatedAt, var saved = storage.manifest(key) {
            saved.updatedAt = updatedAt
            try JSONEncoder().encode(saved).write(
                to: directory.appendingPathComponent("\(key)/manifest.json"), options: .atomic)
        }
        return archive.session
    }
}
