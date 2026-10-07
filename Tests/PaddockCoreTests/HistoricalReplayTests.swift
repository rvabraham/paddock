import Foundation
import Testing
@testable import PaddockCore

@Suite struct HistoricalReplayTests {
    private let positions = "NcmtDoAgFIbhe/kybOfgnPN0u8HgzwwGA0FwQmPcuzK1vG94EnofbLTeQZaEwR57iNtxQmCIW02V5magWpiEeIZC5+Jl9wBJYC4d8SApTBBTPkMoKxjz4Us/5LzmGw=="
    private let cars = "bYyxDoMwDET/5eYg2SaBxivqH7QLVQeEkKhUZaBsUf69JqzccCdb9y7jnvbts/ygr4znPkMhxLGhtuH+QUGZlHiEwzBt1spgPnxYp5SWb/0QrGVyEKgEyxbaOXhotCNAzb0FSylWkouBEz7RWFEmX9maB30rpnf5Aw=="

    @Test func streamAcceptsBOMAndCRLFAndKeepsFractionalTime() throws {
        let data = Data("\u{FEFF}00:00:01.125{\"value\":1}\r\n00:01:02.750{\"value\":2}".utf8)
        var timestamps: [Double] = []
        var values: [Int] = []
        try HistoricalStream.forEach(data) { time, row in
            timestamps.append(time)
            values.append(row["value"].int ?? -1)
        }
        #expect(timestamps == [1.125, 62.75])
        #expect(values == [1, 2])
    }

    @Test func malformedTimestampsAndCompressionAreRejected() {
        #expect(throws: (any Error).self) {
            try HistoricalStream.forEach(Data("00:99:00.000{}".utf8)) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            try HistoricalStream.forEach(Data("00:00:00.000\"bad-base64\"".utf8), compressed: true) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            _ = try HistoricalStream.inflate(Data([1, 2, 3]), maximumBytes: 1024)
        }
        #expect(throws: (any Error).self) {
            _ = try HistoricalStream.inflate(Data(base64Encoded: positions)!, maximumBytes: 16)
        }
    }

    @Test func historicalIndexPreservesSourceIDsAndConvertsLocalTimes() throws {
        let value = try json("""
        {"Year":2019,"Meetings":[{"Name":"Original Grand Prix","Country":{"Name":"Australia"},"Circuit":{"ShortName":"Original Circuit"},"Sessions":[
          {"Key":5394,"Name":"Race","StartDate":"2019-03-17T16:10:00","EndDate":"2019-03-17T18:10:00","GmtOffset":"11:00:00","Path":"2019/2019-03-17_Original_Grand_Prix/2019-03-17_Race/"},
          {"Key":5394,"Name":"Race","StartDate":"2019-03-17T16:10:00","EndDate":"2019-03-17T18:10:00","GmtOffset":"11:00:00","Path":"2019/2019-03-17_Original_Grand_Prix/2019-03-17_Race/"},
          {"Key":5395,"Name":"Race","StartDate":"2019-03-17T16:10:00","EndDate":"2019-03-17T18:10:00","GmtOffset":"11:00:00","Path":"2019/../signalrcore/"}
        ]}]}
        """)
        let entries = HistoricalReplayProvider.decodeIndex(value, year: 2019)
        #expect(entries.count == 1)
        #expect(entries.first?.session.key == 5394)
        #expect(entries.first?.session.startsAt == RaceDate.parse("2019-03-17T05:10:00Z"))
        #expect(HistoricalReplayProvider.decodeIndex(value, year: 2020).isEmpty)
        #expect(HistoricalReplayProvider.localDate("2019-03-17T08:00:00", offset: "-04:00:00") == RaceDate.parse("2019-03-17T12:00:00Z"))
    }

    @Test func archivePathsCannotEscapeStaticHistory() {
        for path in ["/2019/a/b/", "2019/a/../b/", "2019/a/b?x=1", "2019/a/%2e%2e/", "2019/a/b\\c/", "https://example.com/a/b/"] {
            #expect(!HistoricalReplayProvider.validPath(path, year: 2019))
        }
    }

    @Test func omittedModernArchiveUsesVerifiedEventAndLocalSessionDates() throws {
        let summary = SessionSummary(key: 77, title: "Original Grand Prix", sessionName: "Qualifying", country: "United States",
            circuit: "Original Circuit", startsAt: RaceDate.parse("2024-11-23T06:00:00Z")!,
            endsAt: RaceDate.parse("2024-11-23T07:00:00Z"), year: 2024)
        let row = try json("{\"session_key\":77,\"meeting_key\":44,\"year\":2024,\"session_name\":\"Qualifying\",\"country_name\":\"United States\",\"circuit_short_name\":\"Original Circuit\",\"date_start\":\"2024-11-23T06:00:00Z\",\"date_end\":\"2024-11-23T07:00:00Z\",\"gmt_offset\":\"-08:00:00\"}")
        let race = try json("{\"meeting_key\":44,\"year\":2024,\"date_start\":\"2024-11-24T06:00:00Z\"}")
        let meeting = try json("{\"meeting_key\":44,\"meeting_name\":\"Original Grand Prix\"}")
        let entry = try #require(HistoricalReplayProvider.archivedEntry(session: summary, row: row, race: race, meeting: meeting))
        #expect(entry.path == "2024/2024-11-24_Original_Grand_Prix/2024-11-22_Qualifying/")
        #expect(HistoricalReplayProvider.archivedEntry(session: summary, row: row, race: race,
            meeting: try json("{\"meeting_key\":45,\"meeting_name\":\"Original Grand Prix\"}")) == nil)
        #expect(HistoricalReplayProvider.archivedEntry(session: summary, row: row, race: race,
            meeting: try json("{\"meeting_key\":44,\"meeting_name\":\"../escape\"}")) == nil)
    }

    @Test func legacySprintQualifyingNameUsesRecordedRaceType() throws {
        let value = try json("{\"Year\":2021,\"Meetings\":[{\"Name\":\"Original Grand Prix\",\"Sessions\":[{\"Key\":6425,\"Type\":\"Race\",\"Name\":\"Sprint Qualifying\",\"StartDate\":\"2021-07-17T16:30:00\",\"EndDate\":\"2021-07-17T17:00:00\",\"GmtOffset\":\"01:00:00\",\"Path\":\"2021/2021-07-18_Original_Grand_Prix/2021-07-17_Sprint_Qualifying/\"}]}]}")
        let entry = try #require(HistoricalReplayProvider.decodeIndex(value, year: 2021).first)
        #expect(entry.session.sessionName == "Sprint")
        #expect(!entry.session.isQualifying)
        #expect(entry.path.hasSuffix("Sprint_Qualifying/"))
    }

    @Test func sparseLapUpdatesKeepPhasesPitIntervalsAndRetirements() throws {
        let start = try #require(RaceDate.parse("2019-03-17T05:10:00Z"))
        var decoder = HistoricalTimingDecoder()
        decoder.apply(try json("{\"SessionPart\":2,\"Lines\":{\"11\":{\"NumberOfLaps\":0,\"InPit\":true,\"Retired\":false}}}"), at: start)
        decoder.apply(try json("{\"Lines\":{\"11\":{\"InPit\":false,\"Sectors\":[{\"Value\":\"20.000\"},{\"Value\":\"20.500\"},{\"Value\":\"19.500\"}]}}}"), at: start.addingTimeInterval(5))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"LastLapTime\":{\"Value\":\"1:00.000\"}}}}"), at: start.addingTimeInterval(59.9))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"NumberOfLaps\":1,\"Position\":1,\"GapToLeader\":\"LAP 2\"}}}"), at: start.addingTimeInterval(60))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"Sectors\":{\"2\":{\"Value\":\"19.600\"}}}}}"), at: start.addingTimeInterval(60.2))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"Retired\":true}}}"), at: start.addingTimeInterval(65))
        let lap = try #require(decoder.laps.first)
        #expect(decoder.laps.count == 1)
        #expect(lap.duration == 60)
        #expect(lap.phase == .q2)
        #expect(lap.sector1 == 20)
        #expect(lap.sector3 == 19.6)
        #expect(lap.isPitOut)
        #expect(decoder.allPits.first?.exitedAt == start.addingTimeInterval(5))
        #expect(decoder.driverStatuses.last?.status == .retired)
        #expect(decoder.intervals.last?.gap == "LEADER")
    }

    @Test func emptyRaceGapsDoNotLabelEveryDriverAsLeader() throws {
        var decoder = HistoricalTimingDecoder(countsCompletedLaps: true)
        decoder.apply(try json("""
        {"Lines":{"11":{"Position":1,"GapToLeader":""},"22":{"Position":2,"GapToLeader":""},"33":{"Position":3,"GapToLeader":"+1 LAP"}}}
        """), at: session.startsAt)
        #expect(decoder.intervals.first { $0.driver == 11 }?.gap == "LEADER")
        #expect(decoder.intervals.first { $0.driver == 22 }?.gap == "—")
        #expect(decoder.intervals.first { $0.driver == 33 }?.gap == "+1 LAP")
    }

    @Test func nativeArchiveDecoderKeepsMeasuredFieldsAndMissingValues() throws {
        var decoder = HistoricalReplayDecoder(session: session)
        try decoder.consume("ExtrapolatedClock", data: Data("00:00:00.302{\"Utc\":\"2019-03-17T05:10:00.302Z\"}".utf8))
        try decoder.consume("DriverList", data: Data("00:00:00.000{\"11\":{\"RacingNumber\":\"11\",\"FirstName\":\"Ada\",\"LastName\":\"Driver\",\"Tla\":\"ADA\",\"TeamName\":\"Original Team\"},\"22\":{\"RacingNumber\":\"22\",\"FullName\":\"Grace Driver\"}}".utf8))
        try decoder.consume("TimingData", data: Data("00:01:00.000{\"SessionPart\":1,\"Lines\":{\"11\":{\"NumberOfLaps\":1,\"LastLapTime\":{\"Value\":\"1:00.000\"}}}}".utf8))
        try decoder.consume("WeatherData", data: Data("00:00:01.000{\"AirTemp\":\"31.5\",\"Rainfall\":\"1\"}".utf8))
        try decoder.consume("WeatherData", data: Data("00:00:02.000{\"Humidity\":\"75\"}".utf8))
        try decoder.consume("SessionStatus", data: Data("00:02:00.000{\"Status\":\"Finalised\"}".utf8))
        try decoder.consume("TrackStatus", data: Data("00:01:00.000{\"Status\":\"6\"}".utf8))
        try decoder.consume("TimingAppData", data: Data("00:00:05.000{\"Lines\":{\"11\":{\"Stints\":[{\"Compound\":\"SOFT\",\"StartLaps\":0,\"TotalLaps\":4,\"LapNumber\":3},{\"Compound\":\"MEDIUM\",\"StartLaps\":2,\"TotalLaps\":5,\"LapNumber\":6}]}}}".utf8))
        try decoder.consume("Position.z", data: Data("00:00:01.000\"\(positions)\"".utf8))
        try decoder.consume("CarData.z", data: Data("00:00:01.000\"\(cars)\"".utf8))
        let archive = try decoder.finish()
        #expect(archive.drivers.first?.name == "Ada Driver")
        #expect(archive.locations.count == 1)
        #expect(archive.telemetry.count == 2)
        #expect(archive.telemetry.first?.speed == 250)
        #expect(archive.telemetry.first?.drs == .on)
        #expect(archive.telemetry.last?.throttle == nil)
        #expect(archive.telemetry.last?.gear == nil)
        #expect(archive.telemetry.last?.brake == nil)
        #expect(archive.telemetry.last?.drs == .available)
        #expect(archive.weather.first?.weather.rainfall == true)
        #expect(archive.weather.last?.weather.air == 31.5)
        #expect(archive.weather.last?.weather.humidity == 75)
        #expect(archive.session.endsAt == session.startsAt.addingTimeInterval(120))
        #expect(archive.statuses.contains { $0.status == "Virtual safety car" })
        #expect(archive.stints.map(\.startLap) == [1, 5])
        #expect(archive.stints.map(\.tyreAgeAtStart) == [0, 2])
        #expect(archive.laps.first?.startedAt == session.startsAt)
    }

    @Test func incompleteArchiveIsNotPresentedAsPlayable() {
        var decoder = HistoricalReplayDecoder(session: session)
        #expect(throws: (any Error).self) { _ = try decoder.finish() }
    }

    @Test func pitExitCounterDoesNotAddAQualifyingLap() throws {
        let start = session.startsAt
        var decoder = HistoricalTimingDecoder()
        decoder.apply(try json("{\"Lines\":{\"11\":{\"InPit\":true}}}"), at: start)
        decoder.apply(try json("{\"SessionPart\":1,\"Lines\":{\"11\":{\"InPit\":false,\"PitOut\":true,\"NumberOfLaps\":1}}}"), at: start.addingTimeInterval(5))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"NumberOfLaps\":2,\"LastLapTime\":{\"Value\":\"1:00.000\"}}}}"), at: start.addingTimeInterval(65))
        #expect(decoder.laps.map(\.lap) == [1])
        #expect(decoder.laps.first?.isPitOut == true)
    }

    @Test func missingFirstRaceLapTimeUsesRecordedSectorSum() throws {
        var decoder = HistoricalTimingDecoder()
        decoder.apply(try json("{\"Lines\":{\"11\":{\"NumberOfLaps\":1,\"Sectors\":[{\"Value\":\"20.000\"},{\"Value\":\"20.500\"},{\"Value\":\"19.500\"}]}}}"), at: session.startsAt.addingTimeInterval(60))
        #expect(decoder.laps.first?.lap == 1)
        #expect(decoder.laps.first?.duration == 60)
    }

    @Test func completedSectorsSurviveSparseResets() throws {
        var decoder = HistoricalTimingDecoder()
        decoder.apply(try json("{\"Lines\":{\"11\":{\"NumberOfLaps\":1,\"LastLapTime\":{\"Value\":\"1:00.000\"},\"Sectors\":[{\"Value\":\"20.000\"},{\"Value\":\"21.000\"},{\"Value\":\"19.000\"}]}}}"), at: session.startsAt.addingTimeInterval(60))
        decoder.apply(try json("{\"Lines\":{\"11\":{\"Sectors\":{\"0\":{\"Value\":\"\"},\"1\":{\"Value\":\"\"},\"2\":{\"Value\":\"\"}}}}}"), at: session.startsAt.addingTimeInterval(60.5))
        #expect(decoder.laps.first?.sector1 == 20)
        #expect(decoder.laps.first?.sector2 == 21)
        #expect(decoder.laps.first?.sector3 == 19)
    }

    @Test func raceStartPreservesFirstLapWhenItsTimeIsMissing() throws {
        var decoder = HistoricalTimingDecoder(countsCompletedLaps: true)
        decoder.recordRaceStart(at: session.startsAt)
        decoder.apply(try json("{\"Lines\":{\"11\":{\"NumberOfLaps\":1,\"PitOut\":true}}}"), at: session.startsAt.addingTimeInterval(60))
        #expect(decoder.laps.first?.lap == 1)
        #expect(decoder.laps.first?.startedAt == session.startsAt)
        #expect(decoder.laps.first?.duration == nil)
    }

    @Test func qualifyingStatsAndBestTimeResetsFollowTheRecordedPhase() throws {
        var decoder = HistoricalTimingDecoder()
        let start = session.startsAt
        decoder.apply(try json("{\"SessionPart\":1,\"Lines\":{\"11\":{\"Position\":6,\"BestLapTime\":{\"Value\":\"1:12.839\"},\"Stats\":[{\"TimeDiffToFastest\":\"+0.423\",\"TimeDifftoPositionAhead\":\"+0.013\"}]}}}"), at: start)
        #expect(decoder.intervals.last?.gap == "+0.423")
        #expect(decoder.intervals.last?.interval == "+0.013")
        decoder.apply(try json("{\"SessionPart\":2,\"Lines\":{\"11\":{\"BestLapTime\":{\"Value\":\"\"}}}}"), at: start.addingTimeInterval(5))
        #expect(decoder.intervals.last?.gap == "—")
        #expect(decoder.sourceBestLaps.first?.time == 72.839)
        #expect(decoder.sourceBestLaps.last?.time == nil)
        decoder.apply(try json("{\"Lines\":{\"11\":{\"Stats\":{\"1\":{\"TimeDiffToFastest\":\"+0.500\",\"TimeDifftoPositionAhead\":\"+0.100\"}}}}}"), at: start.addingTimeInterval(6))
        #expect(decoder.intervals.last?.gap == "+0.500")
        #expect(decoder.intervals.last?.interval == "+0.100")
    }

    private var session: SessionSummary {
        SessionSummary(key: 5394, title: "Original Grand Prix", sessionName: "Race", country: "Australia",
            circuit: "Original Circuit", startsAt: RaceDate.parse("2019-03-17T05:10:00Z")!,
            endsAt: RaceDate.parse("2019-03-17T06:10:00Z"), year: 2019)
    }
    private func json(_ text: String) throws -> JSONValue { try JSONValue.decode(Data(text.utf8)) }
}
