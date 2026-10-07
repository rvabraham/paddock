import Foundation

enum LapValidity {
    private static let driverPattern = try! NSRegularExpression(
        pattern: #"\bCAR\s+(\d{1,3})\b"#, options: .caseInsensitive)
    private static let timePattern = try! NSRegularExpression(
        pattern: #"\bLAP\s*TIME\s+((?:\d{1,2}:)?\d{1,2}\.\d{1,3})\b"#, options: .caseInsensitive)

    static func attribute(_ messages: [ControlMessage], to laps: inout [RecordedLap]) {
        for index in laps.indices {
            var changes = laps[index].validityChanges ?? []
            if changes.isEmpty, let valid = laps[index].isValid, let completed = laps[index].completedAt,
                completed.timeIntervalSince1970.isFinite
            {
                changes.append(LapValidityChange(date: completed, isValid: valid))
            }
            changes.removeAll { !$0.date.timeIntervalSince1970.isFinite }
            changes.sort { $0.date < $1.date }
            if !changes.isEmpty {
                laps[index].validityChanges = changes
                laps[index].isValid = changes.last?.isValid
            }
        }
        let indices = Dictionary(grouping: laps.indices, by: { laps[$0].driverNumber })
        for message in messages {
            let text = message.text.uppercased()
            let valid: Bool
            if text.contains("REINSTATED") {
                valid = true
            } else if text.contains("DELETED") {
                valid = false
            } else {
                continue
            }
            guard let driverText = capture(driverPattern, in: message.text), let driver = Int(driverText),
                let timeText = capture(timePattern, in: message.text),
                let time = ProviderDecoders.lapTime(.string(timeText)),
                let driverIndices = indices[driver]
            else { continue }
            var closest: Int?
            var closestDate: Date?
            var ambiguous = false
            for index in driverIndices {
                guard let completion = laps[index].completedAt, let duration = laps[index].duration,
                    completion <= message.date, abs(duration - time) <= 0.0005
                else { continue }
                if closestDate == nil || completion > closestDate! {
                    closest = index
                    closestDate = completion
                    ambiguous = false
                } else if completion == closestDate {
                    ambiguous = true
                }
            }
            guard let index = closest, !ambiguous else { continue }
            let change = LapValidityChange(date: message.date, isValid: valid)
            var changes = laps[index].validityChanges ?? []
            if !changes.contains(change) { changes.append(change) }
            changes.sort { $0.date < $1.date }
            laps[index].validityChanges = changes
            laps[index].isValid = changes.last?.isValid
        }
    }
    private static func capture(_ expression: NSRegularExpression, in text: String) -> String? {
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

struct BestLapObservation: Sendable {
    var date: Date
    var time: Double?
}

enum BestLapHistory {
    private struct Event {
        var date: Date
        var lap: Int
        var eligible: Bool
        var completion: Bool
    }
    static func observations(for laps: [RecordedLap]) -> [BestLapObservation] {
        let measured = laps.filter {
            guard let duration = $0.duration, let completed = $0.completedAt else { return false }
            return duration.isFinite && duration > 0 && duration <= 86400
                && completed.timeIntervalSince1970.isFinite && completed >= $0.startedAt
        }
        let ranked = measured.sorted { ($0.duration!, $0.lap) < ($1.duration!, $1.lap) }
        var events: [Event] = []
        for lap in measured {
            let completed = lap.completedAt!
            events.append(
                Event(
                    date: completed, lap: lap.lap, eligible: lap.validity(at: completed) != false,
                    completion: true))
            for change in lap.validityChanges ?? [] where change.date > completed {
                events.append(
                    Event(date: change.date, lap: lap.lap, eligible: change.isValid, completion: false))
            }
        }
        events.sort { ($0.date, $0.completion ? 0 : 1, $0.lap) < ($1.date, $1.completion ? 0 : 1, $1.lap) }
        var eligible: Set<Int> = []
        var result: [BestLapObservation] = []
        for event in events {
            if event.eligible { eligible.insert(event.lap) } else { eligible.remove(event.lap) }
            let best = ranked.first { eligible.contains($0.lap) }?.duration
            result.append(BestLapObservation(date: event.date, time: best))
        }
        return result
    }
}
