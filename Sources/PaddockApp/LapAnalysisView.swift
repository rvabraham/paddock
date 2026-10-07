import SwiftUI
import Charts
import PaddockCore

enum LapTrace: String, CaseIterable { case speed = "Speed", throttle = "Throttle", brake = "Brake", gear = "Gear" }
extension Notification.Name { static let paddockReplayLap = Notification.Name("PaddockReplayLap") }

struct LapAnalysisView: View {
    let store: RaceStore
    @Binding var requestedLap: LapSelection?
    @State private var drivers: [Driver] = []
    @State private var laps: [RecordedLap] = []
    @State private var reference: LapSelection?
    @State private var comparison: LapSelection?
    @State private var phase: QualifyingPhase?
    @State private var referencePoints: [LapTelemetryPoint] = []
    @State private var comparedPoints: [LapTelemetryPoint] = []
    @State private var deltaPoints: [LapComparisonPoint] = []

    private var qualifying: Bool { store.session?.isQualifying == true }
    private var visibleLaps: [RecordedLap] { laps.filter { phase == nil || $0.phase == phase } }
    private var wholeLapDifference: Double? {
        guard let reference, let comparison,
              let referenceTime = laps.first(where: { $0.driverNumber == reference.driverNumber && $0.lap == reference.lap })?.duration,
              let comparisonTime = laps.first(where: { $0.driverNumber == comparison.driverNumber && $0.lap == comparison.lap })?.duration,
              referenceTime.isFinite, comparisonTime.isFinite else { return nil }
        return comparisonTime - referenceTime
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if qualifying {
                    HStack {
                        Text("Qualifying").font(.title3.weight(.semibold))
                        Spacer()
                        if store.channelAvailability.qualifyingPhases {
                            Picker("Qualifying phase", selection: $phase) {
                                Text("All").tag(Optional<QualifyingPhase>.none)
                                ForEach(QualifyingPhase.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        }
                    }
                    QualifyingResults(drivers: drivers, laps: laps, phase: phase, choose: choose)
                        .frame(height: min(230, max(90, CGFloat(drivers.count * 24 + 32))))
                    if !store.channelAvailability.qualifyingPhases {
                        Text("Qualifying phases were not recorded for this session.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                HStack {
                    Text("Lap comparison").font(.title3.weight(.semibold))
                    Spacer()
                    Toggle("Compare lap", isOn: Binding(get: { comparison != nil }, set: { enabled in
                        comparison = enabled ? defaultComparison() : nil
                    })).toggleStyle(.checkbox).font(.callout)
                    .disabled(reference == nil || defaultComparison() == nil)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        lapPicker("Reference", selection: $reference)
                        if comparison != nil { lapPicker("Compare", selection: $comparison) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        lapPicker("Reference", selection: $reference)
                        if comparison != nil { lapPicker("Compare", selection: $comparison) }
                    }
                }
                if let reference {
                    HStack(spacing: 16) {
                        lapLegend(reference, compared: false)
                        if let comparison { lapLegend(comparison, compared: true) }
                        Spacer()
                        Button("Replay lap", systemImage: "play") {
                            NotificationCenter.default.post(name: .paddockReplayLap, object: reference)
                        }.controlSize(.small)
                    }
                }
                if let difference = wholeLapDifference {
                    HStack {
                        Text("Whole lap · comparison minus reference").foregroundStyle(.secondary)
                        Text(String(format: "%+.3f s", difference)).monospacedDigit()
                    }.font(.caption)
                }
                if referencePoints.isEmpty && comparedPoints.isEmpty {
                    ContentUnavailableView("No recorded lap telemetry", systemImage: "waveform.path",
                        description: Text("Choose another measured lap, or download a session with telemetry."))
                        .frame(height: 240)
                } else {
                    LapTelemetryCharts(reference: referencePoints, comparison: comparedPoints, delta: deltaPoints,
                        selection: LapAnalysisSelection(sessionKey: store.session?.key, reference: reference, comparison: comparison),
                        referenceColor: color(reference), comparisonColor: color(comparison))
                }
            }.padding(18)
        }
        .task(id: store.session?.key) { phase = nil; loadLaps() }
        .onChange(of: store.channelAvailability) { _, _ in loadLaps() }
        .onChange(of: requestedLap) { _, selection in
            if let selection { choose(selection) }
        }
        .onChange(of: reference) { _, selection in
            if let selection { store.selectedDriverNumber = selection.driverNumber }
        }
        .onChange(of: phase) { _, _ in
            if let current = reference, !validLaps.contains(where: { $0.driverNumber == current.driverNumber && $0.lap == current.lap }) {
                reference = bestSelection(driver: current.driverNumber) ?? validLaps.first.map { LapSelection(driverNumber: $0.driverNumber, lap: $0.lap) }
            }
            if comparison != nil { comparison = defaultComparison() }
        }
        .task(id: LapAnalysisSelection(sessionKey: store.session?.key, reference: reference, comparison: comparison)) {
            referencePoints = reference.map { store.lapTelemetry(for: $0.driverNumber, lap: $0.lap) } ?? []
            comparedPoints = comparison.map { store.lapTelemetry(for: $0.driverNumber, lap: $0.lap) } ?? []
            if let reference, let comparison {
                deltaPoints = store.compareLaps(reference: reference, comparison: comparison)?.points ?? []
            } else { deltaPoints = [] }
        }
    }

    private var validLaps: [RecordedLap] { visibleLaps.filter { ($0.duration ?? 0) > 0 && $0.completedAt != nil } }
    private func loadLaps() {
        drivers = store.drivers.map(\.driver).sorted { $0.number < $1.number }
        laps = drivers.flatMap { store.recordedLaps(for: $0.number) }
        let desired = requestedLap ?? store.selectedDriverNumber.flatMap { bestSelection(driver: $0) }
        reference = desired.flatMap { selection in
            validLaps.contains { $0.driverNumber == selection.driverNumber && $0.lap == selection.lap } ? selection : nil
        } ?? validLaps.first.map { LapSelection(driverNumber: $0.driverNumber, lap: $0.lap) }
        comparison = nil
    }
    private func bestSelection(driver: Int) -> LapSelection? {
        validLaps.filter { $0.driverNumber == driver && $0.isValid != false && !$0.isPitIn && !$0.isPitOut }
            .min { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
            .map { LapSelection(driverNumber: driver, lap: $0.lap) }
    }
    private func defaultComparison() -> LapSelection? {
        let candidate = validLaps.filter { $0.driverNumber != reference?.driverNumber && $0.isValid != false && !$0.isPitIn && !$0.isPitOut }
            .min { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) } ?? validLaps.first {
                $0.isValid != false && !$0.isPitIn && !$0.isPitOut &&
                    ($0.driverNumber != reference?.driverNumber || $0.lap != reference?.lap)
            }
        return candidate.map { LapSelection(driverNumber: $0.driverNumber, lap: $0.lap) }
    }
    private func choose(_ selection: LapSelection) {
        if let lap = laps.first(where: { $0.driverNumber == selection.driverNumber && $0.lap == selection.lap }), phase != nil, phase != lap.phase { phase = lap.phase }
        reference = selection
        store.selectedDriverNumber = selection.driverNumber
    }
    private func lapPicker(_ title: String, selection: Binding<LapSelection?>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Picker("\(title) driver", selection: Binding(get: { selection.wrappedValue?.driverNumber ?? -1 }, set: { number in
                selection.wrappedValue = bestSelection(driver: number) ?? validLaps.first { $0.driverNumber == number }.map { LapSelection(driverNumber: number, lap: $0.lap) }
            })) {
                ForEach(drivers.filter { driver in validLaps.contains { $0.driverNumber == driver.number } }) { driver in
                    Text(driver.acronym).tag(driver.number)
                }
            }.labelsHidden().frame(width: 82)
            Picker("\(title) lap", selection: Binding(get: { selection.wrappedValue?.lap ?? -1 }, set: { lap in
                if let number = selection.wrappedValue?.driverNumber { selection.wrappedValue = LapSelection(driverNumber: number, lap: lap) }
            })) {
                ForEach(validLaps.filter { $0.driverNumber == selection.wrappedValue?.driverNumber }) { lap in
                    Text("\(lap.lap) · \(formatLapTime(lap.duration))\(lap.isValid == false ? " · Deleted" : "")").tag(lap.lap)
                }
            }.labelsHidden().frame(width: 155)
        }
    }
    private func color(_ selection: LapSelection?) -> Color {
        Color(hex: drivers.first { $0.number == selection?.driverNumber }?.colorHex ?? "888888")
    }
    private func lapLegend(_ selection: LapSelection, compared: Bool) -> some View {
        HStack(spacing: 6) {
            LineSwatch(color: color(selection), dash: compared ? [5, 3] : []).frame(width: 18, height: 10)
            Text("\(drivers.first { $0.number == selection.driverNumber }?.acronym ?? String(selection.driverNumber)) · Lap \(selection.lap)")
        }.font(.caption)
    }
}

private struct LapAnalysisSelection: Hashable { let sessionKey: Int?; let reference: LapSelection?; let comparison: LapSelection? }

private struct QualifyingResults: View {
    let drivers: [Driver]
    let laps: [RecordedLap]
    let phase: QualifyingPhase?
    let choose: (LapSelection) -> Void

    private func best(_ number: Int, phase: QualifyingPhase) -> RecordedLap? {
        laps.filter { $0.driverNumber == number && $0.phase == phase && $0.isValid != false && !$0.isPitIn && !$0.isPitOut && ($0.duration ?? 0) > 0 }
            .min(by: qualifyingLapPrecedes)
    }
    var body: some View {
        let bestByDriver = Dictionary(uniqueKeysWithValues: drivers.map { driver in
            (driver.number, Dictionary(uniqueKeysWithValues: QualifyingPhase.allCases.compactMap { segment in best(driver.number, phase: segment).map { (segment, $0) } }))
        })
        let rows = drivers.sorted { left, right in
            let leftResults = bestByDriver[left.number] ?? [:], rightResults = bestByDriver[right.number] ?? [:]
            let leftPhase = phase ?? QualifyingPhase.allCases.last { leftResults[$0] != nil }
            let rightPhase = phase ?? QualifyingPhase.allCases.last { rightResults[$0] != nil }
            let leftRank = leftPhase.flatMap { QualifyingPhase.allCases.firstIndex(of: $0) } ?? -1
            let rightRank = rightPhase.flatMap { QualifyingPhase.allCases.firstIndex(of: $0) } ?? -1
            if leftRank != rightRank { return leftRank > rightRank }
            let leftLap = leftPhase.flatMap { leftResults[$0] }
            let rightLap = rightPhase.flatMap { rightResults[$0] }
            if let leftLap, let rightLap { return qualifyingLapPrecedes(leftLap, rightLap) }
            if leftLap != nil { return true }
            if rightLap != nil { return false }
            return left.number < right.number
        }
        Table(rows) {
            TableColumn("Driver") { driver in
                HStack(spacing: 7) {
                    TeamMark(colorHex: driver.colorHex)
                    Text(driver.name.localizedCapitalized).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }.width(min: 130, ideal: 200)
            TableColumn("Q1") { driver in lapButton(bestByDriver[driver.number]?[.q1]) }
            TableColumn("Q2") { driver in lapButton(bestByDriver[driver.number]?[.q2]) }
            TableColumn("Q3") { driver in lapButton(bestByDriver[driver.number]?[.q3]) }
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
    }
    private func lapButton(_ lap: RecordedLap?) -> some View {
        Button { if let lap { choose(LapSelection(driverNumber: lap.driverNumber, lap: lap.lap)) } } label: {
            Text(formatLapTime(lap?.duration)).monospacedDigit()
        }.buttonStyle(.borderless).disabled(lap == nil).help("Analyze this qualifying lap")
    }
}

private func qualifyingLapPrecedes(_ left: RecordedLap, _ right: RecordedLap) -> Bool {
    (left.duration ?? .infinity, left.completedAt ?? .distantFuture, left.driverNumber, left.lap)
        < (right.duration ?? .infinity, right.completedAt ?? .distantFuture, right.driverNumber, right.lap)
}

private struct LapTelemetryCharts: View {
    let reference: [LapTelemetryPoint]
    let comparison: [LapTelemetryPoint]
    let delta: [LapComparisonPoint]
    let selection: LapAnalysisSelection
    let referenceColor: Color
    let comparisonColor: Color
    @State private var trace: LapTrace = .speed

    private var distanceDomain: ClosedRange<Double> {
        0...max(1, reference.last?.distance ?? 0, comparison.last?.distance ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Telemetry trace", selection: $trace) {
                ForEach(LapTrace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
            LapTelemetrySelection(reference: reference, comparison: comparison, delta: delta,
                selection: selection, trace: trace,
                referenceReadings: trace.readings(reference), comparisonReadings: trace.readings(comparison),
                referenceColor: referenceColor, comparisonColor: comparisonColor, distanceDomain: distanceDomain)
        }
    }
}

private struct LapTelemetrySelection: View {
    let reference: [LapTelemetryPoint]
    let comparison: [LapTelemetryPoint]
    let delta: [LapComparisonPoint]
    let selection: LapAnalysisSelection
    let trace: LapTrace
    let referenceReadings: [TraceReading]
    let comparisonReadings: [TraceReading]
    let referenceColor: Color
    let comparisonColor: Color
    let distanceDomain: ClosedRange<Double>
    @State private var selectedDistance: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LapTraceChart(reference: reference, comparison: comparison, trace: trace,
                hasComparison: selection.comparison != nil,
                referenceReadings: referenceReadings, comparisonReadings: comparisonReadings,
                referenceColor: referenceColor, comparisonColor: comparisonColor,
                distanceDomain: distanceDomain, selectedDistance: $selectedDistance)
                .frame(height: 240)
            if selection.comparison != nil {
                if delta.isEmpty {
                    Text("Not enough shared distance coverage for a time delta.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Time delta · shared distance").font(.callout.weight(.medium))
                    Text("Compared at equal recorded distance. Whole-lap difference uses recorded lap times.")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart {
                        RuleMark(y: .value("Reference", 0)).foregroundStyle(.secondary.opacity(0.4))
                        ForEach(delta) { point in
                            LineMark(x: .value("Distance", point.distance), y: .value("Delta", point.delta))
                                .foregroundStyle(comparisonColor).lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                        if let selectedDistance {
                            RuleMark(x: .value("Selected distance", selectedDistance)).foregroundStyle(.secondary)
                        }
                    }
                    .chartXScale(domain: distanceDomain)
                    .chartXSelection(value: $selectedDistance)
                    .chartXAxisLabel("Distance · metres").chartYAxisLabel("Seconds")
                    .frame(height: 130)
                    .accessibilityLabel("Comparison minus reference time over shared recorded distance")
                }
            }
        }
        .onChange(of: selection) { _, _ in selectedDistance = nil }
    }
}

private struct LapTraceChart: View {
    let reference: [LapTelemetryPoint]
    let comparison: [LapTelemetryPoint]
    let trace: LapTrace
    let hasComparison: Bool
    let referenceReadings: [TraceReading]
    let comparisonReadings: [TraceReading]
    let referenceColor: Color
    let comparisonColor: Color
    let distanceDomain: ClosedRange<Double>
    @Binding var selectedDistance: Double?
    private func readingLabel(_ value: Double) -> String {
        trace == .brake ? (value == 1 ? "On" : "Off") : value.formatted(.number.precision(.fractionLength(0...1)))
    }
    private func selectedReading(_ points: [LapTelemetryPoint], at distance: Double) -> Double? {
        guard let first = points.first, let last = points.last,
              distance >= first.distance, distance <= last.distance else { return nil }
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].distance <= distance { low = middle + 1 } else { high = middle }
        }
        let lower = max(0, low - 1)
        if distance == points[lower].distance { return trace.value(points[lower]) }
        guard low < points.count, trace.value(points[lower]) != nil, trace.value(points[low]) != nil else { return nil }
        if trace == .brake || trace == .gear { return trace.value(points[lower]) }
        return trace.value(distance - points[lower].distance <= points[low].distance - distance ? points[lower] : points[low])
    }
    var body: some View {
        Chart {
            ForEach(referenceReadings) { point in
                LineMark(x: .value("Distance", point.distance), y: .value(trace.rawValue, point.value), series: .value("Lap", "Reference \(point.segment)"))
                    .foregroundStyle(referenceColor).lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(trace == .brake || trace == .gear ? .stepEnd : .linear)
            }
            ForEach(comparisonReadings) { point in
                LineMark(x: .value("Distance", point.distance), y: .value(trace.rawValue, point.value), series: .value("Lap", "Comparison \(point.segment)"))
                    .foregroundStyle(comparisonColor).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .interpolationMethod(trace == .brake || trace == .gear ? .stepEnd : .linear)
            }
            if let selectedDistance {
                RuleMark(x: .value("Selected distance", selectedDistance)).foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(selectedDistance.formatted(.number.precision(.fractionLength(0)))) m").foregroundStyle(.secondary)
                            if let reading = selectedReading(reference, at: selectedDistance) {
                                Text("Reference · \(readingLabel(reading))")
                            } else {
                                Text("Reference · No data").foregroundStyle(.secondary)
                            }
                            if hasComparison {
                                if let reading = selectedReading(comparison, at: selectedDistance) {
                                    Text("Compare · \(readingLabel(reading))")
                                } else {
                                    Text("Compare · No data").foregroundStyle(.secondary)
                                }
                            }
                        }.font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: distanceDomain)
        .chartXSelection(value: $selectedDistance)
        .chartLegend(.hidden)
        .chartXAxisLabel("Distance · metres")
        .chartYAxis {
            if trace == .brake {
                AxisMarks(values: [0.0, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self) == 1 ? "On" : "Off") }
                }
            } else { AxisMarks() }
        }
        .chartYAxisLabel(trace == .speed ? "km/h" : trace == .gear ? "Gear" : trace == .brake ? "Brake" : "Percent")
        .accessibilityLabel("Recorded \(trace.rawValue.lowercased()) over lap distance")
        .overlay {
            if referenceReadings.isEmpty && comparisonReadings.isEmpty {
                Text("No recorded \(trace.rawValue.lowercased()) for these laps")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private extension LapTrace {
    func value(_ point: LapTelemetryPoint) -> Double? {
        switch self {
        case .speed: point.speed
        case .throttle: point.throttle
        case .brake: point.brake.map { $0 ? 1 : 0 }
        case .gear: point.gear.map(Double.init)
        }
    }
    func readings(_ points: [LapTelemetryPoint]) -> [TraceReading] {
        var segment = 0
        return points.compactMap { point in
            guard let reading = value(point), reading.isFinite else {
                segment += 1
                return nil
            }
            return TraceReading(id: point.id, distance: point.distance, value: reading, segment: segment)
        }
    }
}

private struct TraceReading: Identifiable {
    let id: Double
    let distance: Double
    let value: Double
    let segment: Int
}
