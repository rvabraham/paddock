import Foundation

enum HistoricalReplayProvider {
    static let topics = ["ExtrapolatedClock", "DriverList", "SessionStatus", "TrackStatus", "TimingData",
                         "TimingAppData", "RaceControlMessages", "WeatherData", "Position.z", "CarData.z"]
    private static let base = URL(string: "https://livetiming.formula1.com/static/")!

    struct Entry: Sendable {
        var session: SessionSummary
        var path: String
    }

    static func sessions(year: Int, http: ProviderHTTP, force: Bool = false) async throws -> [SessionSummary] {
        try await entries(year: year, http: http, force: force).map(\.session).sorted { $0.startsAt > $1.startsAt }
    }

    static func replay(
        _ session: SessionSummary, http: ProviderHTTP,
        progress: @escaping @Sendable (ReplayDownloadProgress) async -> Void,
        loadCheckpoint: @escaping @Sendable (String) async throws -> Data? = { _ in nil },
        saveCheckpoint: @escaping @Sendable (String, Data) async throws -> Void = { _, _ in }
    ) async throws -> ReplayArchive {
        guard let end = session.endsAt, end < Date().addingTimeInterval(-1800) else {
            throw ProviderError.invalidData("This session is not yet a completed historical replay.")
        }
        let entry = try await resolveEntry(session, http: http)
        var decoder = HistoricalReplayDecoder(session: entry.session)
        var bytes: Int64 = 0
        for (index, topic) in topics.enumerated() {
            try Task.checkCancellation()
            let saved = try await loadCheckpoint(topic)
            await progress(ReplayDownloadProgress(phase: .downloading, completedChunks: index,
                totalChunks: topics.count, downloadedBytes: bytes,
                detail: Self.title(for: topic), isResuming: saved != nil))
            let data: Data
            if let saved {
                guard saved.count <= 64 * 1024 * 1024 else {
                    throw ProviderError.invalidData("A saved historical topic exceeds its size limit.")
                }
                data = saved
            } else {
                let url = base.appendingPathComponent(entry.path, isDirectory: true).appendingPathComponent(topic + ".jsonStream")
                data = try await http.bytes(url, maxAge: 31536000, maximumBytes: 64 * 1024 * 1024, cacheResponse: false)
                try Task.checkCancellation()
            }
            try decoder.consume(topic, data: data)
            if saved == nil { try await saveCheckpoint(topic, data) }
            bytes += Int64(data.count)
            await progress(ReplayDownloadProgress(phase: .downloading, completedChunks: index + 1,
                totalChunks: topics.count, downloadedBytes: bytes,
                detail: Self.title(for: topic), isResuming: saved != nil))
        }
        try Task.checkCancellation()
        await progress(ReplayDownloadProgress(phase: .verifying, completedChunks: topics.count,
            totalChunks: topics.count, downloadedBytes: bytes, detail: "Preparing replay", isResuming: false))
        return try decoder.finish()
    }

    static func decodeIndex(_ value: JSONValue, year: Int) -> [Entry] {
        guard value["Year"].int == year else { return [] }
        var known: Set<Int> = []
        return value["Meetings"].array.flatMap { meeting in
            meeting["Sessions"].array.compactMap { row -> Entry? in
                guard let key = row["Key"].int, key > 0,
                      let path = row["Path"].string, validPath(path, year: year),
                      let start = localDate(row["StartDate"].string, offset: row["GmtOffset"].string),
                      let end = localDate(row["EndDate"].string, offset: row["GmtOffset"].string), end > start,
                      let sourceName = row["Name"].string, known.insert(key).inserted else { return nil }
                let name = row["Type"].string == "Race" && sourceName == "Sprint Qualifying" ? "Sprint" : sourceName
                return Entry(session: SessionSummary(key: key, title: meeting["Name"].string ?? "Grand Prix",
                    sessionName: name, country: meeting["Country"]["Name"].string ?? "",
                    circuit: meeting["Circuit"]["ShortName"].string ?? meeting["Location"].string ?? "",
                    startsAt: start, endsAt: end, year: year), path: path)
            }
        }
    }

    private static func resolveEntry(_ session: SessionSummary, http: ProviderHTTP) async throws -> Entry {
        if let entry = try await entries(year: session.year, http: http).first(where: { $0.session.key == session.key }) {
            return entry
        }
        guard session.year >= 2023 else { throw unavailable }
        let rows = try await http.request(URL(string: "https://api.openf1.org/v1/sessions?session_key=\(session.key)")!, maxAge: 31536000)
        guard let row = rows.array.first(where: { $0["session_key"].int == session.key }),
              let meetingKey = row["meeting_key"].int, meetingKey > 0 else { throw unavailable }
        let races = try await http.request(URL(string: "https://api.openf1.org/v1/sessions?meeting_key=\(meetingKey)&session_name=Race")!, maxAge: 31536000)
        let meetings = try await http.request(URL(string: "https://api.openf1.org/v1/meetings?meeting_key=\(meetingKey)")!, maxAge: 31536000)
        guard let race = races.array.first(where: { $0["meeting_key"].int == meetingKey && $0["session_name"].string == "Race" }),
              let meeting = meetings.array.first(where: { $0["meeting_key"].int == meetingKey }),
              let entry = archivedEntry(session: session, row: row, race: race, meeting: meeting) else { throw unavailable }
        return entry
    }

    static func archivedEntry(session: SessionSummary, row: JSONValue, race: JSONValue, meeting: JSONValue) -> Entry? {
        guard row["session_key"].int == session.key, let meetingKey = row["meeting_key"].int,
              race["meeting_key"].int == meetingKey, meeting["meeting_key"].int == meetingKey,
              row["year"].int == session.year, race["year"].int == session.year,
              let raceDate = RaceDate.parse(race["date_start"].string),
              var recorded = ProviderDecoders.session(row), recorded.isQualifying,
              let offset = offsetSeconds(row["gmt_offset"].string),
              let name = meeting["meeting_name"].string, !name.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let eventDay = formatter.string(from: raceDate)
        let sessionDay = formatter.string(from: recorded.startsAt.addingTimeInterval(offset))
        let path = "\(session.year)/\(eventDay)_\(name.replacingOccurrences(of: " ", with: "_"))/\(sessionDay)_\(recorded.sessionName.replacingOccurrences(of: " ", with: "_"))/"
        guard validPath(path, year: session.year) else { return nil }
        recorded.title = name
        return Entry(session: recorded, path: path)
    }

    private static func entries(year: Int, http: ProviderHTTP, force: Bool = false) async throws -> [Entry] {
        guard (2018...2100).contains(year) else {
            throw ProviderError.invalidData("Historical replay data starts with the 2018 season.")
        }
        return try await http.request(base.appendingPathComponent("\(year)/Index.json"), maxAge: force ? 0 : 31536000) {
            let entries = decodeIndex($0, year: year)
            guard !entries.isEmpty else { throw ProviderError.invalidData("This season has no available historical sessions.") }
            return entries
        }
    }

    static func validPath(_ path: String, year: Int) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return path.utf8.count < 600 && parts.count == 3 && parts.first == Substring(String(year))
            && !path.hasPrefix("/") && !path.contains("..") && !path.contains("\\")
            && !path.contains("?") && !path.contains("#") && !path.contains("%") && !path.contains(":")
    }

    static func localDate(_ text: String?, offset: String?) -> Date? {
        guard let text, let date = RaceDate.parse(text), let seconds = offsetSeconds(offset) else { return nil }
        return date.addingTimeInterval(-seconds)
    }

    private static func offsetSeconds(_ offset: String?) -> Double? {
        guard let offset else { return nil }
        let negative = offset.hasPrefix("-")
        let digits = offset.hasPrefix("-") || offset.hasPrefix("+") ? String(offset.dropFirst()) : offset
        guard let seconds = HistoricalStream.duration(digits), seconds <= 24 * 3600 else { return nil }
        return negative ? -seconds : seconds
    }

    private static var unavailable: ProviderError { .invalidData("The session is unavailable in the historical archive.") }

    private static func title(for topic: String) -> String {
        switch topic {
        case "ExtrapolatedClock": "Session clock"
        case "DriverList": "Drivers"
        case "SessionStatus", "TrackStatus": "Session events"
        case "TimingData": "Lap timing"
        case "TimingAppData": "Tyre stints"
        case "RaceControlMessages": "Race control"
        case "WeatherData": "Weather"
        case "Position.z": "Car positions"
        case "CarData.z": "Car telemetry"
        default: "Replay data"
        }
    }
}
