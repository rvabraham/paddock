import Foundation
import Testing

@testable import PaddockCore

struct TimingTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func testSparsePatchesPreserveUntouchedSectorsAndFalseValues() throws {
        let original = try json(
            #"{"Lines":{"16":{"InPit":true,"Sectors":[{"Value":"28.100"},{"Value":"33.200"},{"Value":"19.300"}]}}}"#
        )
        let patch = try json(#"{"Lines":{"16":{"InPit":false,"Sectors":{"1":{"Value":"32.900"}}}}}"#)
        let result = original.merging(patch)
        #expect(result["Lines"]["16"]["InPit"].bool == false)
        #expect(result["Lines"]["16"]["Sectors"].array[0]["Value"].string == "28.100")
        #expect(result["Lines"]["16"]["Sectors"].array[1]["Value"].string == "32.900")
        #expect(result["Lines"]["16"]["Sectors"].array[2]["Value"].string == "19.300")
    }

    @Test func testReplayUsesLapCompletionAndWithholdsFutureStints() throws {
        let raw: [String: JSONValue] = [
            "session": try json(
                #"[{"session_key":7,"date_start":"2024-01-01T12:00:00Z","date_end":"2024-01-01T12:10:00Z","session_name":"Race","year":2024}]"#
            ),
            "drivers": try json(
                #"[{"driver_number":16,"full_name":"Charles Leclerc","name_acronym":"LEC","team_name":"Ferrari","team_colour":"E8002D"}]"#
            ),
            "laps": try json(
                #"[{"driver_number":16,"lap_number":1,"date_start":"2024-01-01T12:00:00Z","lap_duration":90,"duration_sector_1":30},{"driver_number":16,"lap_number":2,"date_start":"2024-01-01T12:01:30Z","lap_duration":80},{"driver_number":16,"lap_number":3,"date_start":"2024-01-01T12:02:50Z","lap_duration":85}]"#
            ),
            "stints": try json(
                #"[{"driver_number":16,"lap_start":1,"lap_end":2,"compound":"MEDIUM","tyre_age_at_start":0},{"driver_number":16,"lap_start":3,"lap_end":8,"compound":"HARD","tyre_age_at_start":0}]"#
            ),
            "position": try json(
                #"[{"driver_number":16,"date":"2024-01-01T12:00:01Z","position":2},{"driver_number":16,"date":"2024-01-01T12:02:00Z","position":1}]"#
            ),
        ]
        let replay = try ReplayDataset(raw: raw)
        let start = replay.session.startsAt
        let early = replay.snapshot(at: start.addingTimeInterval(45))[0]
        #expect(early.lastLap == nil)
        #expect(early.bestLap == nil)
        #expect(early.sector1 == nil)
        #expect(early.position == 2)
        #expect(early.compound == "MEDIUM")
        #expect(replay.visibleStints(for: 16, at: start.addingTimeInterval(45)).count == 1)
        #expect(replay.visibleStints(for: 16, at: start.addingTimeInterval(45))[0].endLap == 1)
        let later = replay.snapshot(at: start.addingTimeInterval(180))[0]
        #expect(later.position == 1)
        #expect(later.lastLap == 80)
        #expect(later.bestLap == 80)
        #expect(later.compound == "HARD")
        #expect(
            replay.snapshot(at: start.addingTimeInterval(45)) == [early],
            "Seeking backwards must reconstruct the earlier state, including the previous position and compound"
        )
    }

    @Test func testSessionTimezoneAndChronology() throws {
        #expect(
            abs(
                (RaceDate.parse("2024-05-26T13:04:03.123456+00:00")?.timeIntervalSince1970 ?? 0)
                    - 1716728643.123456) < 0.001)
        #expect(
            RaceDate.parse("2024-05-26T15:04:03.123456+02:00")
                == RaceDate.parse("2024-05-26T13:04:03.123456Z"))
    }

    @Test func testLapFormattingCarriesRoundingAcrossMinuteBoundary() {
        #expect(formatLapTime(59.9996) == "1:00.000")
        #expect(formatLapTime(nil) == "—")
        #expect(formatLapTime(-1) == "—")
    }

    @Test func scheduledSessionNamesMatchSprintQualifyingAliasesWithoutMergingSessionTypes() {
        var session = SessionSummary(
            key: 7, title: "Test", sessionName: "", country: "Test", circuit: "Test",
            startsAt: Date(timeIntervalSince1970: 0), endsAt: nil, year: 2024)
        let cases = [
            ("Sprint Shootout", "Sprint qualifying", true),
            ("Sprint Qualifying", "Sprint Shootout", true),
            ("  SPRINT\tQUALIFYING  ", "sprint shootout", true),
            ("Qualifying", "Sprint qualifying", false),
            ("Sprint", "Sprint qualifying", false),
            ("Race", "Sprint", false),
            ("Race", "race", true),
            ("Practice 2", "Practice 3", false),
        ]
        for (recorded, scheduled, expected) in cases {
            session.sessionName = recorded
            #expect(session.matchesScheduledName(scheduled) == expected)
        }
    }

    @Test func recordedNullGapRequiresKnownLeaderPositionAndKeepsMissingDataUnknown() throws {
        let raw: [String: JSONValue] = [
            "session": try json(#"[{"session_key":7,"date_start":"2024-01-01T12:00:00Z","session_name":"Race","year":2024}]"#),
            "drivers": try json(#"[{"driver_number":16,"full_name":"Driver"}]"#),
            "laps": try json(#"[{"driver_number":16,"lap_number":1,"date_start":"2024-01-01T12:00:00Z","lap_duration":90}]"#),
            "position": try json(#"[{"driver_number":16,"date":"2024-01-01T12:00:30Z","position":1},{"driver_number":16,"date":"2024-01-01T12:00:10Z","position":1},{"driver_number":16,"date":"2024-01-01T12:00:20Z","position":2}]"#),
            "intervals": try json(#"[{"driver_number":16,"date":"2024-01-01T12:00:05Z","gap_to_leader":null,"interval":null},{"driver_number":16,"date":"2024-01-01T12:00:10Z","gap_to_leader":null,"interval":null},{"driver_number":16,"date":"2024-01-01T12:00:20Z","gap_to_leader":1.234,"interval":1.234},{"driver_number":16,"date":"2024-01-01T12:00:25Z","gap_to_leader":null},{"driver_number":16,"date":"2024-01-01T12:00:30Z"}]"#),
        ]
        let replay = try ReplayDataset(raw: raw)
        let start = replay.session.startsAt
        #expect(replay.snapshot(at: start.addingTimeInterval(5))[0].gap == "—")
        #expect(replay.snapshot(at: start.addingTimeInterval(10))[0].gap == "LEADER")
        #expect(replay.snapshot(at: start.addingTimeInterval(20))[0].gap == "+1.234")
        #expect(replay.snapshot(at: start.addingTimeInterval(25))[0].gap == "—")
        #expect(replay.snapshot(at: start.addingTimeInterval(30))[0].gap == "—")
        #expect(replay.snapshot(at: start.addingTimeInterval(10))[0].gap == "LEADER")
    }

    @Test func nullGapsRemainUnknownForRecordedNonleadersAcrossPositionChanges() throws {
        var raw = ReplayTestFixtures.raw()
        let records = (raw["intervals"]?.array ?? []).filter { $0["gap_to_leader"].double != 0 }.map { record in
            var row = record.object ?? [:]
            row["gap_to_leader"] = .null
            return JSONValue.object(row)
        }
        raw["intervals"] = .array(records)
        let replay = try ReplayDataset(raw: raw)
        #expect(records.count == 21)
        for record in records {
            let date = try #require(RaceDate.parse(record["date"].string))
            let number = try #require(record["driver_number"].int)
            let row = try #require(replay.snapshot(at: date).first { $0.id == number })
            #expect(row.position != 1)
            #expect(row.gap == "—")
            #expect(row.interval == "+1.200")
        }
    }

    @Test func testDateOnlyCalendarDoesNotInventRaceStartTime() throws {
        let value = try json(
            #"{"MRData":{"RaceTable":{"season":"2026","Races":[{"season":"2026","round":"1","raceName":"Test Grand Prix","date":"2026-10-04","Circuit":{"circuitName":"Test","Location":{"country":"Test"}},"Qualifying":{"date":"2026-10-03","time":"14:00:00Z"}}]}}}"#
        )
        let calendar = try ProviderDecoders.calendar(value, year: 2026)
        let race = try #require(calendar.first)
        #expect(!race.hasKnownTime)
        #expect(Calendar.current.component(.day, from: race.date) == 4)
        #expect(Calendar.current.component(.hour, from: race.date) == 12)
        #expect(race.sessions.first(where: { $0.name == "Qualifying" })?.hasKnownTime == true)
        #expect(race.sessions.first(where: { $0.name == "Race" })?.hasKnownTime == false)
    }

    @Test func testOfflineLibraryReadsSavedSessionMetadataWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(
            #"{"session":[{"session_key":7,"date_start":"2024-01-01T12:00:00Z","date_end":"2024-01-01T12:10:00Z","session_name":"Race","meeting_name":"Saved Grand Prix","year":2024}],"drivers":[{"driver_number":16,"full_name":"Charles Leclerc"}],"laps":[{"driver_number":16,"lap_number":1,"date_start":"2024-01-01T12:00:00Z","lap_duration":90}]}"#
                .utf8)
        try data.write(to: directory.appendingPathComponent("7.json"))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("8.json"))
        let provider = RaceProvider(
            replayDirectory: directory,
            http: ProviderHTTP(directory: directory.appendingPathComponent("Responses")))
        let summaries = await provider.cachedSessions()
        #expect(summaries.count == 1)
        #expect(summaries.first?.key == 7)
        #expect(summaries.first?.title == "Saved Grand Prix")
    }

    @Test func testTrackGeometryRequiresCompleteLapCoverage() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lap = LapSample(driverNumber: 16, lap: 10, time: 90, date: start.addingTimeInterval(90))
        let complete = (0...90).map {
            TimedLocation(
                date: start.addingTimeInterval(Double($0)),
                position: CarPosition(driverNumber: 16, x: Double($0), y: Double($0)))
        }
        #expect(!ReplayDataset.outline(for: lap, locations: complete).isEmpty)
        #expect(ReplayDataset.outline(for: lap, locations: Array(complete.prefix(60))).isEmpty)
        #expect(
            ReplayDataset.outline(
                for: lap,
                locations: complete.filter {
                    $0.date.timeIntervalSince(start) < 20 || $0.date.timeIntervalSince(start) > 40
                }
            ).isEmpty)
    }

    @Test func providerShapedSyntheticReplayKeepsExtendedSessionAndRestartChronology() throws {
        let replay = try ReplayTestFixtures.replay()
        #expect(replay.session.key == 7007)
        #expect(replay.drivers.count == 8)
        #expect(replay.laps.count == 80)
        #expect(!replay.outline.isEmpty, "Test coordinates cover a complete lap")
        let mid = replay.session.startsAt.addingTimeInterval(500)
        let state = replay.snapshot(at: mid)
        #expect(
            RaceStore.replayTrackStatus(messages: replay.controlMessages(at: mid), finished: false)
                == "Track clear", "A session restart supersedes an earlier red flag")
        #expect(state.count == 8)
        #expect((state.first(where: { $0.id == 16 })?.lap ?? 0) < 10)
        let actualFinish = try #require(replay.laps.last?.date)
        let scheduledFinish = try #require(replay.session.endsAt)
        #expect(actualFinish > scheduledFinish)
        #expect(replay.session.startsAt.addingTimeInterval(replay.duration) >= actualFinish)
        let finished = replay.snapshot(at: replay.session.startsAt.addingTimeInterval(replay.duration))
        #expect(finished.first(where: { $0.id == 16 })?.lap == 10)
        #expect(!replay.messages.isEmpty)
    }
}
