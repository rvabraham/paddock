import Foundation
import Testing

@testable import PaddockCore

struct ReplayEngineTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func archive(laps: [RecordedLap]? = nil) -> ReplayArchive {
        ReplayArchive(
            session: SessionSummary(
                key: 7, title: "Test Grand Prix", sessionName: "Qualifying", country: "Test", circuit: "Test",
                startsAt: start, endsAt: date(100), year: 2023),
            drivers: [Driver(number: 16, name: "Driver", acronym: "DRV", team: "Team", colorHex: "FFFFFF")],
            laps: laps ?? [
                RecordedLap(
                    driverNumber: 16, lap: 1, startedAt: start, completedAt: date(90), duration: 90,
                    phase: .q1)
            ])
    }
    @Test func sourceRateCoordinatesInterpolateOnlyWithinRecordedBrackets() throws {
        var recorded = archive()
        recorded.locations = [
            RecordedCarSample(date: date(5), driverNumber: 16, x: 60, y: 70),
            RecordedCarSample(date: date(0), driverNumber: 16, x: 10, y: 20),
            RecordedCarSample(date: date(1), driverNumber: 16, x: 20, y: 40),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.interpolatedPositions(at: date(0.5)) == [CarPosition(driverNumber: 16, x: 15, y: 30)])
        #expect(replay.interpolatedPositions(at: date(2)).isEmpty)
        #expect(replay.interpolatedPositions(at: date(-0.1)).isEmpty)
        #expect(replay.interpolatedPositions(at: date(5.1)).isEmpty)
        #expect(replay.interpolatedPositions(at: date(5)) == [CarPosition(driverNumber: 16, x: 60, y: 70)])
        #expect(replay.interpolatedPositions(at: date(0.5)) == [CarPosition(driverNumber: 16, x: 15, y: 30)])
        #expect(replay.archive.locations.count == 3)
    }
    @Test func malformedCoordinateOutliersCannotOverflowInterpolationOrTrackBounds() throws {
        var recorded = archive()
        recorded.locations = [
            RecordedCarSample(date: start, driverNumber: 16, x: 10, y: 20),
            RecordedCarSample(date: date(0.25), driverNumber: 16, x: -1e308, y: -1e308),
            RecordedCarSample(date: date(0.5), driverNumber: 16, x: 1e308, y: 1e308),
            RecordedCarSample(date: date(1), driverNumber: 16, x: 20, y: 40),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.archive.locations.count == 2)
        #expect(replay.interpolatedPositions(at: date(0.5)) == [CarPosition(driverNumber: 16, x: 15, y: 30)])
    }
    @Test func continuousTelemetryInterpolatesAndDiscreteFieldsRemainFromPast() throws {
        var recorded = archive()
        recorded.telemetry = [
            RecordedTelemetrySample(
                date: date(0), driverNumber: 16, speed: 100, throttle: 0, brake: false, gear: 3, rpm: 10000,
                drs: .off),
            RecordedTelemetrySample(
                date: date(1), driverNumber: 16, speed: 200, throttle: 100, brake: true, gear: 4, rpm: 12000,
                drs: .on),
            RecordedTelemetrySample(
                date: date(5), driverNumber: 16, speed: 250, throttle: 100, brake: false, gear: 6, rpm: 13000,
                drs: .off),
        ]
        let replay = try ReplayDataset(archive: recorded)
        let middle = replay.telemetry(for: 16, at: date(0.5))
        #expect(middle.speed == 150)
        #expect(middle.throttle == 50)
        #expect(middle.rpm == 11000)
        #expect(middle.gear == 3)
        #expect(middle.brake == false)
        #expect(middle.drs == .off)
        #expect(!middle.isStale)
        #expect(replay.telemetry(for: 16, at: date(1)).gear == 4)
        let gap = replay.telemetry(for: 16, at: date(2))
        #expect(gap.isStale)
        #expect(gap.speed == nil && gap.gear == nil && gap.brake == nil)
        #expect(gap.date == date(1))
        #expect(replay.telemetry(for: 44, at: date(0.5)).isStale)
        #expect(replay.telemetry(for: 16, at: date(0.5)) == middle)
    }
    @Test func missingAndMalformedTelemetryFieldsRemainUnknown() throws {
        var recorded = archive()
        recorded.telemetry = [
            RecordedTelemetrySample(
                date: start, driverNumber: 16, speed: .infinity, throttle: -1, gear: 200, rpm: Int.max)
        ]
        let replay = try ReplayDataset(archive: recorded)
        let cursor = replay.telemetry(for: 16, at: start)
        #expect(cursor.speed == nil && cursor.throttle == nil && cursor.gear == nil && cursor.rpm == nil)
        #expect(cursor.brake == nil && cursor.drs == nil)
    }
    @Test func explicitPitAndRetirementStatesReconstructAfterBackwardSeeking() throws {
        var recorded = archive()
        recorded.pits = [RecordedPitInterval(driverNumber: 16, enteredAt: date(4), exitedAt: date(6), lap: 1)]
        recorded.driverStatuses = [
            RecordedDriverStatus(date: date(2), driverNumber: 16, status: .racing),
            RecordedDriverStatus(date: date(8), driverNumber: 16, status: .retired),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.snapshot(at: date(1))[0].status == .unknown)
        #expect(replay.snapshot(at: date(5))[0].inPit)
        #expect(replay.snapshot(at: date(5))[0].status == .inPit)
        #expect(replay.snapshot(at: date(6))[0].status == .racing)
        #expect(replay.snapshot(at: date(8))[0].status == .retired)
        #expect(replay.snapshot(at: date(3))[0].status == .racing)
        #expect(replay.snapshot(at: date(3))[0].inPit == false)
        #expect(replay.events.contains { $0.kind == .pit && $0.date == date(4) })
        #expect(replay.events.contains { $0.kind == .retirement && $0.date == date(8) })
    }
    @Test func openPitEntryRemainsActiveUntilRecordingEndAcrossRepeatedSeeks() throws {
        var recorded = archive()
        recorded.pits = [
            RecordedPitInterval(driverNumber: 16, enteredAt: date(4), exitedAt: date(6), lap: 1),
            RecordedPitInterval(driverNumber: 16, enteredAt: date(8), lap: 1),
        ]
        recorded.driverStatuses = [
            RecordedDriverStatus(date: date(2), driverNumber: 16, status: .racing)
        ]
        let replay = try ReplayDataset(archive: recorded)
        for seconds in [100.0, 8, 5, 6, 3, 7, 8, 100] {
            let state = replay.snapshot(at: date(seconds))[0]
            let expectedPit = seconds >= 8 || (seconds >= 4 && seconds < 6)
            #expect(state.inPit == expectedPit)
            #expect(state.status == (expectedPit ? .inPit : .racing))
        }
        #expect(replay.archive.pits.last?.exitedAt == nil)
    }
    @Test func explicitTerminalStatusSurvivesAnOpenPitIntervalAndBackwardSeeking() throws {
        for terminal in [DriverRaceStatus.retired, .finished] {
            var recorded = archive()
            recorded.pits = [RecordedPitInterval(driverNumber: 16, enteredAt: date(4), lap: 1)]
            recorded.driverStatuses = [
                RecordedDriverStatus(date: date(2), driverNumber: 16, status: .racing),
                RecordedDriverStatus(date: date(8), driverNumber: 16, status: terminal),
            ]
            let replay = try ReplayDataset(archive: recorded)
            for seconds in [100.0, 5, 8, 3, 100] {
                let state = replay.snapshot(at: date(seconds))[0]
                #expect(state.inPit == (seconds >= 4))
                let expectedStatus: DriverRaceStatus = seconds >= 8 ? terminal : (seconds >= 4 ? .inPit : .racing)
                #expect(state.status == expectedStatus)
            }
        }
    }
    @Test func statusesAndQualifyingPhasesDoNotLeakAcrossCursor() throws {
        var recorded = archive()
        recorded.laps.append(
            RecordedLap(
                driverNumber: 16, lap: 2, startedAt: date(90), completedAt: date(130), duration: 40,
                phase: .q2, isValid: false))
        recorded.statuses = [
            RecordedStatus(date: date(0), kind: .session, status: "Started", phase: .q1),
            RecordedStatus(date: date(4), kind: .track, status: "Red flag"),
            RecordedStatus(date: date(5), kind: .session, status: "Suspended"),
            RecordedStatus(date: date(10), kind: .session, status: "Started", phase: .q2),
            RecordedStatus(date: date(11), kind: .track, status: "Track clear"),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.phase(at: date(3)) == .q1)
        #expect(replay.snapshot(at: date(130))[0].bestLap == nil)
        #expect(replay.phase(at: date(11)) == .q2)
        #expect(replay.phase(at: date(-1)) == nil)
        #expect(replay.status(at: date(6), kind: .session) == "Suspended")
        #expect(replay.status(at: date(6), kind: .track) == "Red flag")
        #expect(replay.status(at: date(3), kind: .track) == nil)
        #expect(replay.phase(at: date(3)) == .q1)
    }
    @Test func sourceBestLapResetsAtPhaseStartAndPreservesEliminatedDrivers() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: date(0), completedAt: date(60), duration: 60, phase: .q1),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(100), completedAt: date(170.896), duration: 70.896, phase: .q2),
            RecordedLap(driverNumber: 16, lap: 3, startedAt: date(200), completedAt: date(271.311), duration: 71.311, phase: .q3),
            RecordedLap(driverNumber: 20, lap: 1, startedAt: date(0), completedAt: date(65), duration: 65, phase: .q1),
        ])
        recorded.drivers.append(Driver(number: 20, name: "Eliminated", acronym: "OUT", team: "Team", colorHex: "FFFFFF"))
        recorded.statuses = [
            RecordedStatus(date: date(0), kind: .session, status: "Started", phase: .q1),
            RecordedStatus(date: date(80), kind: .session, status: "Started", phase: .q2),
            RecordedStatus(date: date(180), kind: .session, status: "Started", phase: .q3),
        ]
        recorded.sourceBestLaps = [
            RecordedBestLap(date: date(0), driverNumber: 16, time: nil),
            RecordedBestLap(date: date(60), driverNumber: 16, time: 60),
            RecordedBestLap(date: date(80), driverNumber: 16, time: nil),
            RecordedBestLap(date: date(170.896), driverNumber: 16, time: 70.896),
            RecordedBestLap(date: date(180), driverNumber: 16, time: nil),
            RecordedBestLap(date: date(271.311), driverNumber: 16, time: 71.311),
            RecordedBestLap(date: date(0), driverNumber: 20, time: nil),
            RecordedBestLap(date: date(65), driverNumber: 20, time: 65),
        ]
        let reloaded = try JSONDecoder().decode(ReplayArchive.self, from: JSONEncoder().encode(recorded))
        #expect(reloaded.sourceBestLaps == recorded.sourceBestLaps)
        let legacy = try JSONDecoder().decode(ReplayArchive.self, from: JSONEncoder().encode(archive()))
        #expect(legacy.sourceBestLaps == nil)
        let replay = try ReplayDataset(archive: reloaded)
        for (seconds, expected) in [(79.0, Double?(60)), (80, nil), (170.896, 70.896), (180, nil), (199, nil), (271.311, 71.311), (170.896, 70.896)] {
            let state = try #require(replay.snapshot(at: date(seconds)).first { $0.id == 16 })
            #expect(state.bestLap == expected)
            #expect(replay.snapshot(at: date(seconds)).first { $0.id == 20 }?.bestLap == 65)
        }
    }
    @Test func derivedQualifyingBestUsesTheDriversRecordedPhaseAndRetainsEliminatedDrivers() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: date(0), completedAt: date(60), duration: 60, phase: .q1),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(100), completedAt: date(170.896), duration: 70.896, phase: .q2),
            RecordedLap(driverNumber: 16, lap: 3, startedAt: date(200), completedAt: date(271.311), duration: 71.311, phase: .q3),
            RecordedLap(driverNumber: 20, lap: 1, startedAt: date(0), completedAt: date(65), duration: 65, phase: .q1),
        ])
        recorded.drivers.append(Driver(number: 20, name: "Eliminated", acronym: "OUT", team: "Team", colorHex: "FFFFFF"))
        recorded.statuses = [
            RecordedStatus(date: date(0), kind: .session, status: "Started", phase: .q1),
            RecordedStatus(date: date(80), kind: .session, status: "Started", phase: .q2),
            RecordedStatus(date: date(180), kind: .session, status: "Started", phase: .q3),
        ]
        let replay = try ReplayDataset(archive: recorded)
        for (seconds, expected) in [(99.0, Double?(60)), (100, nil), (170.896, 70.896), (200, nil), (271.311, 71.311), (170.896, 70.896)] {
            #expect(replay.snapshot(at: date(seconds)).first { $0.id == 16 }?.bestLap == expected)
            #expect(replay.snapshot(at: date(seconds)).first { $0.id == 20 }?.bestLap == 65)
        }
        recorded.session.sessionName = "Race"
        let race = try ReplayDataset(archive: recorded)
        #expect(race.snapshot(at: date(271.311)).first { $0.id == 16 }?.bestLap == 60)
    }
    @Test func lapDistanceComparisonUsesLapStartAndRejectsDataGaps() throws {
        let laps = [
            RecordedLap(
                driverNumber: 16, lap: 1, startedAt: date(0.5), completedAt: date(10.5), duration: 10),
            RecordedLap(
                driverNumber: 16, lap: 2, startedAt: date(20.5), completedAt: date(32.5), duration: 12),
        ]
        var recorded = archive(laps: laps)
        recorded.telemetry =
            (0...11).map { RecordedTelemetrySample(date: date(Double($0)), driverNumber: 16, speed: 180) }
            + (20...33).map { RecordedTelemetrySample(date: date(Double($0)), driverNumber: 16, speed: 150) }
        let replay = try ReplayDataset(archive: recorded)
        let series = replay.lapTelemetry(for: 16, lap: 1)
        #expect(series.first?.elapsed == 0)
        #expect(series.first?.distance == 0)
        #expect(series.last?.elapsed == 10)
        #expect(abs((series.last?.distance ?? 0) - 500) < 0.0001)
        let comparison = try #require(
            replay.compareLaps(
                reference: LapSelection(driverNumber: 16, lap: 1),
                comparison: LapSelection(driverNumber: 16, lap: 2)))
        #expect(abs((comparison.points.last?.delta ?? 0) - 2) < 0.0001)
        recorded.telemetry.removeAll { $0.date > date(4) && $0.date < date(8) }
        let missing = try ReplayDataset(archive: recorded)
        #expect(missing.lapTelemetry(for: 16, lap: 1).isEmpty)
        #expect(
            missing.compareLaps(
                reference: LapSelection(driverNumber: 16, lap: 1),
                comparison: LapSelection(driverNumber: 16, lap: 2)) == nil)
    }
    @Test func renderClockClampsAndFreezesWithoutUpdatingTimingRows() {
        let advancing = ReplayClock(
            sessionStart: start, duration: 100, anchorTime: 10, anchorDate: date(20), rate: 0.5,
            isAdvancing: true)
        #expect(advancing.time(at: date(22)) == 11)
        #expect(advancing.sessionDate(at: date(22)) == date(11))
        #expect(advancing.time(at: date(500)) == 100)
        #expect(advancing.time(at: date(19)) == 10)
        let paused = ReplayClock(
            sessionStart: start, duration: 100, anchorTime: 11, anchorDate: date(22), rate: 1,
            isAdvancing: false)
        #expect(paused.time(at: date(500)) == 11)
    }

    @Test func lapDeletionAndReinstatementPreserveBestTimeChronologyAndClosestPastIdentity() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: date(0), completedAt: date(60), duration: 60),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(60), completedAt: date(125), duration: 65),
            RecordedLap(driverNumber: 16, lap: 3, startedAt: date(125), completedAt: date(185), duration: 60),
        ])
        recorded.messages = [
            ControlMessage(
                id: "delete-first", date: date(150), text: "CAR 16 (DRV) - LAP TIME 1:00.000 DELETED",
                category: "Other", flag: nil),
            ControlMessage(
                id: "delete-later", date: date(200), text: "CAR 16 (DRV) - LAPTIME 1:00.000 DELETED",
                category: "Other", flag: nil),
            ControlMessage(
                id: "restore", date: date(230), text: "CAR 16 (DRV) - LAP TIME 1:00.000 REINSTATED",
                category: "Other", flag: nil),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.snapshot(at: date(149))[0].bestLap == 60)
        #expect(replay.snapshot(at: date(150))[0].bestLap == 65)
        #expect(replay.snapshot(at: date(185))[0].bestLap == 60)
        #expect(replay.snapshot(at: date(200))[0].bestLap == 65)
        #expect(replay.snapshot(at: date(230))[0].bestLap == 60)
        #expect(replay.snapshot(at: date(149))[0].bestLap == 60)
        let laps = replay.recordedLaps(for: 16)
        #expect(laps[0].isValid == false)
        #expect(laps[0].validity(at: date(149)) == nil)
        #expect(laps[2].isValid == true)
        #expect(laps[2].validityChanges?.count == 2)
        let reloaded = try ReplayDataset(archive: replay.archive)
        #expect(reloaded.recordedLaps(for: 16) == laps)
    }

    @Test func ambiguousOrUnmatchedDeletionMessagesDoNotInventLapValidity() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: date(0), completedAt: date(60), duration: 60),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(0), completedAt: date(60), duration: 60),
        ])
        recorded.messages = [
            ControlMessage(
                id: "too-early", date: date(20), text: "CAR 16 - LAP TIME 1:00.000 DELETED",
                category: "Other", flag: nil),
            ControlMessage(
                id: "tie", date: date(70), text: "CAR 16 - LAP TIME 1:00.000 DELETED", category: "Other",
                flag: nil),
            ControlMessage(
                id: "multiple", date: date(80), text: "CAR 16 AND CAR 44 - LAP TIME 1:00.000 DELETED",
                category: "Other", flag: nil),
            ControlMessage(
                id: "missing-time", date: date(90), text: "CAR 16 - LAP TIME DELETED", category: "Other",
                flag: nil),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.recordedLaps(for: 16).allSatisfy { $0.isValid == nil && $0.validityChanges == nil })
        #expect(replay.snapshot(at: date(90))[0].bestLap == 60)
    }

    @Test func explicitLapValiditySurvivesLaterReinstatementAndReload() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: start, completedAt: date(60), duration: 60, isValid: false),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(60), completedAt: date(125), duration: 65),
        ])
        recorded.messages = [ControlMessage(
            id: "restore", date: date(140), text: "CAR 16 - LAP TIME 1:00.000 REINSTATED",
            category: "Other", flag: nil)]
        let replay = try ReplayDataset(archive: recorded)
        let reloaded = try ReplayDataset(archive: replay.archive)
        for dataset in [replay, reloaded] {
            #expect(dataset.snapshot(at: date(60))[0].bestLap == nil)
            #expect(dataset.snapshot(at: date(139))[0].bestLap == 65)
            #expect(dataset.snapshot(at: date(140))[0].bestLap == 60)
            #expect(dataset.recordedLaps(for: 16)[0].validity(at: date(139)) == false)
            #expect(dataset.recordedLaps(for: 16)[0].isValid == true)
        }
    }

    @Test func replayDurationReachesEveryRetainedTimedChannel() throws {
        let updates: [(inout ReplayArchive) -> Void] = [
            { $0.positions = [RecordedPosition(date: date(150), driver: 16, position: 1)] },
            { $0.intervals = [RecordedInterval(date: date(150), driver: 16, gap: "LEADER", interval: "—")] },
            { $0.weather = [RecordedWeather(date: date(150), weather: WeatherInfo(air: 20, track: nil, humidity: nil, windSpeed: nil, rainfall: nil))] },
            { $0.driverStatuses = [RecordedDriverStatus(date: date(150), driverNumber: 16, status: .retired)] },
            { $0.pits = [RecordedPitInterval(driverNumber: 16, enteredAt: date(150))] },
            { $0.pits = [RecordedPitInterval(driverNumber: 16, enteredAt: date(95), exitedAt: date(150))] },
            { $0.sourceBestLaps = [RecordedBestLap(date: date(150), driverNumber: 16, time: 90)] },
            { $0.laps.append(RecordedLap(driverNumber: 16, lap: 2, startedAt: date(150))) },
            { $0.laps.append(RecordedLap(driverNumber: 16, lap: 2, startedAt: date(95), completedAt: date(150))) },
            { $0.laps[0].validityChanges = [LapValidityChange(date: date(150), isValid: false)] },
        ]
        for update in updates {
            var recorded = archive()
            update(&recorded)
            let replay = try ReplayDataset(archive: recorded)
            #expect(replay.duration == 150)
            #expect(replay.events.allSatisfy { $0.date <= start.addingTimeInterval(replay.duration) })
        }
    }

    @Test func malformedLapCompletionCannotPublishABestBeforeItsStart() throws {
        let replay = try ReplayDataset(archive: archive(laps: [RecordedLap(
            driverNumber: 16, lap: 1, startedAt: date(20), completedAt: date(10), duration: 60)]))
        #expect(replay.snapshot(at: date(10))[0].bestLap == nil)
        #expect(replay.laps(for: 16, at: date(100)).isEmpty)
        #expect(replay.recordedLaps(for: 16)[0].completedAt == nil)
        #expect(replay.recordedLaps(for: 16)[0].duration == nil)
        #expect(replay.lapStart(driver: 16, lap: 1) == date(20))
    }

    @Test(arguments: [-1.0, 0, Double.infinity, Double.nan, 86400.001, Double.greatestFiniteMagnitude])
    func invalidRecordedLapDurationsRemainUnavailableForAnalysis(duration: Double) throws {
        let replay = try ReplayDataset(archive: archive(laps: [RecordedLap(
            driverNumber: 16, lap: 1, startedAt: date(20), completedAt: date(90), duration: duration)]))
        #expect(replay.recordedLaps(for: 16)[0].duration == nil)
        #expect(replay.recordedLaps(for: 16)[0].completedAt == date(90))
        #expect(replay.lapStart(driver: 16, lap: 1) == date(20))
        #expect(replay.laps(for: 16, at: date(100)).isEmpty)
        #expect(replay.snapshot(at: date(100))[0].lastLap == nil)
        #expect(replay.snapshot(at: date(100))[0].bestLap == nil)
    }

    @Test func archivedStintAgesCannotOverflowPlaybackAfterReload() throws {
        var recorded = archive(laps: [
            RecordedLap(driverNumber: 16, lap: 1, startedAt: start, completedAt: date(30), duration: 30),
            RecordedLap(driverNumber: 16, lap: 2, startedAt: date(30), completedAt: date(60), duration: 30),
            RecordedLap(driverNumber: 16, lap: 3, startedAt: date(60), completedAt: date(90), duration: 30),
        ])
        recorded.stints = [
            StintSample(driverNumber: 16, compound: "SOFT", startLap: 1, endLap: 2, tyreAgeAtStart: Int.max),
            StintSample(driverNumber: 16, compound: "HARD", startLap: 3, endLap: 3, tyreAgeAtStart: Int.min),
        ]
        let saved = try JSONDecoder().decode(ReplayArchive.self, from: JSONEncoder().encode(recorded))
        let replay = try ReplayDataset(archive: saved)
        let reloaded = try ReplayDataset(archive: replay.archive)
        for dataset in [replay, reloaded] {
            #expect(dataset.archive.stints.map(\.tyreAgeAtStart) == [10000, 0])
            guard dataset.archive.stints.allSatisfy({ (0...10000).contains($0.tyreAgeAtStart) }) else {
                continue
            }
            #expect(dataset.snapshot(at: date(30))[0].tyreAge == 10001)
            #expect(dataset.snapshot(at: date(60))[0].tyreAge == 0)
            #expect(dataset.snapshot(at: date(29))[0].tyreAge == 10000)
        }
    }

    @Test func cancelledDatasetPreparationStopsBeforeBuildingIndexes() async {
        let recorded = archive()
        let preparation = Task {
            while !Task.isCancelled { await Task.yield() }
            return try ReplayDataset(archive: recorded)
        }
        preparation.cancel()
        switch await preparation.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("A cancelled replay preparation returned a dataset")
        }
    }

    @Test func nonFiniteRecordDatesCannotCorruptTimingIndexesOrDuration() throws {
        let invalid = Date(timeIntervalSince1970: .nan)
        var recorded = archive()
        recorded.laps.append(RecordedLap(driverNumber: 16, lap: 2, startedAt: date(95), completedAt: invalid, duration: 60))
        recorded.positions = [
            RecordedPosition(date: date(5), driver: 16, position: 1),
            RecordedPosition(date: invalid, driver: 16, position: 2),
        ]
        recorded.driverStatuses = [
            RecordedDriverStatus(date: date(5), driverNumber: 16, status: .racing),
            RecordedDriverStatus(date: invalid, driverNumber: 16, status: .retired),
        ]
        recorded.statuses = [
            RecordedStatus(date: start, kind: .session, status: "Started", phase: .q1),
            RecordedStatus(date: invalid, kind: .session, status: "Finished", phase: .q3),
        ]
        let replay = try ReplayDataset(archive: recorded)
        #expect(replay.duration == 100)
        #expect(replay.snapshot(at: date(100))[0].position == 1)
        #expect(replay.snapshot(at: date(100))[0].status == .racing)
        #expect(replay.laps.count == 1)
        #expect(replay.phase(at: date(100)) == .q1)
        recorded.session.startsAt = invalid
        #expect(throws: ProviderError.self) { try ReplayDataset(archive: recorded) }
    }
}
