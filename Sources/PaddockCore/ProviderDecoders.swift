import Foundation

enum ProviderDecoders {
    static func sessions(_ value: JSONValue, year: Int) throws -> [(session: SessionSummary, meetingKey: Int?)] {
        guard case .array(let rows) = value else { throw ProviderError.invalidData("The provider returned invalid session data.") }
        var known: Set<Int> = []
        return try rows.compactMap { row in
            guard let session = Self.session(row), session.key > 0, session.year == year else {
                throw ProviderError.invalidData("The provider returned invalid session data.")
            }
            guard known.insert(session.key).inserted else { return nil }
            return (session, row["meeting_key"].int)
        }
    }
    static func session(_ row: JSONValue) -> SessionSummary? {
        guard let key = row["session_key"].int, let date = RaceDate.parse(row["date_start"].string) else { return nil }
        if let year = row.object?["year"], year.int == nil { return nil }
        let location = row["location"].string ?? row["circuit_short_name"].string ?? "Grand Prix"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return SessionSummary(key: key, title: row["meeting_name"].string ?? location, sessionName: row["session_name"].string ?? "Session", country: row["country_name"].string ?? "", circuit: row["circuit_short_name"].string ?? location, startsAt: date, endsAt: RaceDate.parse(row["date_end"].string), year: row["year"].int ?? calendar.component(.year, from: date))
    }
    static func driver(_ row: JSONValue) -> Driver? {
        guard let number = row["driver_number"].int else { return nil }
        return Driver(number: number, name: row["full_name"].string ?? row["broadcast_name"].string ?? "Driver \(number)", acronym: row["name_acronym"].string ?? "\(number)", team: row["team_name"].string ?? "", colorHex: row["team_colour"].string ?? "8E919A")
    }
    static func gap(_ value: JSONValue) -> String {
        if let number = value.double { return number == 0 ? "LEADER" : String(format: "+%.3f", number) }
        return value.string ?? "—"
    }
    static func lapTime(_ value: JSONValue) -> Double? {
        guard let string = value.string, !string.isEmpty else { return nil }
        let pieces = string.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var result: Double = 0
        for (index, piece) in pieces.enumerated() {
            guard let number = Double(piece), number.isFinite, number >= 0,
                  index == 0 || number < 60, index == pieces.count - 1 || number.rounded() == number else { return nil }
            result = result * 60 + number
        }
        return result.isFinite && result > 0 && result <= 86400 ? result : nil
    }
    static func calendar(_ value: JSONValue, year: Int) throws -> [RaceWeekend] {
        let table = value["MRData"]["RaceTable"]
        guard table["season"].int == year, case .array(let rows) = table["Races"] else { throw invalidCalendar }
        var rounds: Set<Int> = []
        return try rows.map { row in
            guard row["season"].int == year, let round = row["round"].int, round > 0,
                  rounds.insert(round).inserted, let day = row["date"].string, day.hasPrefix("\(year)-"),
                  let date = combinedDate(row),
                  let name = row["raceName"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidCalendar
            }
            let names = [("FirstPractice", "Practice 1"), ("SecondPractice", "Practice 2"), ("ThirdPractice", "Practice 3"), ("SprintQualifying", "Sprint qualifying"), ("Sprint", "Sprint"), ("Qualifying", "Qualifying")]
            var sessions = names.compactMap { key, name in combinedDate(row[key]).map { WeekendSession(name: name, date: $0, hasKnownTime: row[key]["time"].string != nil) } }
            sessions.append(WeekendSession(name: "Race", date: date, hasKnownTime: row["time"].string != nil))
            return RaceWeekend(round: round, name: name, country: row["Circuit"]["Location"]["country"].string ?? "", circuit: row["Circuit"]["circuitName"].string ?? "", date: date, sessions: sessions.sorted { $0.date < $1.date }, hasKnownTime: row["time"].string != nil)
        }
    }
    static func combinedDate(_ value: JSONValue) -> Date? {
        guard let day = value["date"].string else { return nil }
        if let time = value["time"].string { return RaceDate.parse(day + "T" + time) }
        // Preserve the published calendar day locally without inventing a midnight start time.
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2 else { return nil }
        let parts = pieces.compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return date
    }
    static func standings(_ value: JSONValue, constructors: Bool, year: Int) throws -> (rows: [Standing], round: Int?) {
        let table = value["MRData"]["StandingsTable"]
        guard table["season"].int == year, case .array(let lists) = table["StandingsLists"] else { throw invalidStandings }
        guard !lists.isEmpty else { return ([], nil) }
        guard lists.count == 1, let list = lists.first, list["season"].int == year,
              let round = list["round"].int, round >= 0, table["round"].int == round,
              case .array(let rows) = list[constructors ? "ConstructorStandings" : "DriverStandings"] else { throw invalidStandings }
        var identities: Set<String> = []
        let standings = try rows.map { row in
            guard let position = row["position"].int, position > 0,
                  let points = row["points"].double, points.isFinite,
                  let wins = row["wins"].int, wins >= 0 else { throw invalidStandings }
            let driver = row["Driver"]
            let constructor = constructors ? row["Constructor"] : (row["Constructors"].array.first ?? .null)
            let team = constructor["name"].string ?? ""
            let name = constructors ? team : [driver["givenName"].string, driver["familyName"].string].compactMap { $0 }.joined(separator: " ")
            guard let id = constructors ? constructor["constructorId"].string : driver["driverId"].string,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identities.insert(id).inserted, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidStandings }
            return Standing(id: id, position: position, name: name, team: team, colorHex: teamColor(team, year: year), points: points, wins: wins)
        }
        return (standings, round)
    }
    private static var invalidCalendar: ProviderError { .invalidData("The provider returned invalid calendar data.") }
    private static var invalidStandings: ProviderError { .invalidData("The provider returned invalid championship standings.") }
    static func teamColor(_ name: String, year: Int = 2026) -> String {
        let name = name.lowercased()
        if year >= 2026 {
            for (key, color) in [("ferrari", "ED1131"), ("mclaren", "F47600"), ("mercedes", "00D7B6"), ("red bull", "4781D7"), ("aston", "229971"), ("alpine", "00A1E8"), ("williams", "1868DB"), ("haas", "9C9FA2"), ("audi", "F50537"), ("racing bulls", "6C98FF"), ("rb", "6C98FF"), ("cadillac", "909090")] where name.contains(key) { return color }
        }
        for (key, color) in [("ferrari", "E8002D"), ("mclaren", "FF8000"), ("mercedes", "27F4D2"), ("red bull", "3671C6"), ("aston", "229971"), ("alpine", "FF87BC"), ("williams", "64C4FF"), ("haas", "B6BABD"), ("sauber", "52E252"), ("audi", "E50028"), ("racing bulls", "6692FF"), ("rb", "6692FF"), ("cadillac", "B5AD9B")] where name.contains(key) { return color }
        return "8E919A"
    }
}
