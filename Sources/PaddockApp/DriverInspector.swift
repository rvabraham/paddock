import SwiftUI
import Charts
import PaddockCore

struct DriverInspector: View {
    let store: RaceStore
    private var driver: DriverState? { store.drivers.first { $0.id == store.selectedDriverNumber } }

    var body: some View {
        Group {
            if let row = driver {
                let laps = store.lapHistory(for: row.id)
                let stints = store.stintHistory(for: row.id)
                let analysisLap = store.recordedLaps(for: row.id).last {
                    $0.completedAt != nil && $0.duration.map { $0.isFinite && $0 > 0 } == true
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(String(row.id)).foregroundStyle(Color(hex: row.driver.colorHex)).monospacedDigit()
                                Text(row.driver.name.localizedCapitalized).fontWeight(.semibold)
                            }.font(.headline)
                            Text(row.driver.team).font(.caption).foregroundStyle(.secondary)
                        }
                        if row.position != nil || row.lap > 0 || (!row.gap.isEmpty && row.gap != "—") {
                            HStack(spacing: 16) {
                                InspectorMetric(title: "Position", value: row.position.map { "P\($0)" } ?? "—")
                                Spacer()
                                InspectorMetric(title: "Gap", value: row.gap.isEmpty ? "—" : row.gap)
                                Spacer()
                                InspectorMetric(title: "Lap", value: row.lap > 0 ? String(row.lap) : "—")
                            }
                        } else {
                            Text("No timing update at this point").font(.caption).foregroundStyle(.secondary)
                        }
                        if row.status == .inPit || row.status == .retired || row.status == .finished {
                            Text(row.status == .inPit ? "In pit lane" : row.status == .retired ? "Retired" : "Finished")
                                .font(.caption).foregroundStyle(driverStatusColor(row.status))
                        }
                        Divider()
                        DriverTelemetryView(store: store, number: row.id)
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Lap timing").font(.callout.weight(.semibold))
                            if row.lastLap != nil { detailLine("Last", formatLapTime(row.lastLap)) }
                            if row.bestLap != nil { detailLine("Best", formatLapTime(row.bestLap)) }
                            if row.sector1 != nil || row.sector2 != nil || row.sector3 != nil {
                                HStack {
                                    if let time = row.sector1 { sector("S1", time: time) }
                                    Spacer()
                                    if let time = row.sector2 { sector("S2", time: time) }
                                    Spacer()
                                    if let time = row.sector3 { sector("S3", time: time) }
                                }
                            } else if row.lastLap == nil && row.bestLap == nil {
                                Text("No measured lap at this point").font(.caption).foregroundStyle(.secondary)
                            }
                            if !laps.isEmpty {
                                MiniPaceChart(laps: laps, color: Color(hex: row.driver.colorHex)).equatable().frame(height: 90)
                            }
                            HStack {
                                Button("Analyze laps", systemImage: "chart.xyaxis.line") {
                                    if let lap = analysisLap {
                                        NotificationCenter.default.post(name: .paddockAnalyzeLap, object: LapSelection(driverNumber: row.id, lap: lap.lap))
                                    }
                                }
                                .disabled(analysisLap == nil)
                                Spacer()
                            }.controlSize(.small)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tyres").font(.callout.weight(.semibold))
                            if !row.compound.isEmpty && row.compound.uppercased() != "UNKNOWN" || row.tyreAge != nil {
                                HStack(spacing: 8) {
                                    TyreBadge(compound: row.compound)
                                    Text(tyreName(row.compound)).font(.callout)
                                    Spacer()
                                    if let age = row.tyreAge {
                                        Text("\(age) laps").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("No tyre data at this point").font(.caption).foregroundStyle(.secondary)
                            }
                            if !stints.isEmpty {
                                DisclosureGroup("Stint history") {
                                    ForEach(Array(stints.enumerated()), id: \.offset) { index, stint in
                                        let end = min(stint.endLap ?? row.lap, row.lap)
                                        if end >= stint.startLap {
                                            HStack {
                                                Text("Stint \(index + 1)").foregroundStyle(.secondary)
                                                Spacer()
                                                TyreBadge(compound: stint.compound)
                                                Text("\(stint.startLap)–\(end)").monospacedDigit()
                                            }.font(.caption).padding(.top, 6)
                                        }
                                    }
                                }.font(.caption)
                            }
                        }
                        if let weather = store.weather, weather.air != nil || weather.track != nil || weather.windSpeed != nil {
                            Divider()
                            DisclosureGroup {
                                HStack {
                                    if let air = weather.air {
                                        InspectorMetric(title: "Air", value: String(format: "%.1f°", air))
                                    }
                                    Spacer()
                                    if let track = weather.track {
                                        InspectorMetric(title: "Track", value: String(format: "%.1f°", track))
                                    }
                                    Spacer()
                                    if let wind = weather.windSpeed {
                                        InspectorMetric(title: "Wind · m/s", value: String(format: "%.1f", wind))
                                    }
                                }.padding(.top, 10)
                            } label: {
                                Text("Conditions").font(.callout.weight(.semibold))
                            }
                        }
                    }.padding(18)
                }.id(row.id)
            } else {
                ContentUnavailableView("Driver detail", systemImage: "person.crop.square",
                    description: Text("Select a car or a driver in the timing list."))
            }
        }.background(.background)
    }
    private func detailLine(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value).font(.callout).monospacedDigit()
    }
    private func sector(_ label: String, time: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.3f", time)).font(.caption.monospacedDigit())
        }
    }
}

private struct DriverTelemetryView: View {
    let store: RaceStore
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry").font(.callout.weight(.semibold))
            if store.channelAvailability.telemetry {
                let clock = store.replayClock
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !clock.isRunning)) { context in
                    let telemetry = store.telemetry(for: number, at: clock.sessionDate(at: context.date))
                    if telemetry.isStale || (telemetry.speed == nil && telemetry.gear == nil && telemetry.drs == nil && telemetry.throttle == nil && telemetry.brake == nil) {
                        Text("No recorded telemetry at this time").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                if let speed = telemetry.speed {
                                    InspectorMetric(title: "Speed · km/h", value: speed.formatted(.number.precision(.fractionLength(0))))
                                }
                                Spacer()
                                if let gear = telemetry.gear {
                                    InspectorMetric(title: "Gear", value: String(gear))
                                }
                                Spacer()
                                if let drs = telemetry.drs {
                                    InspectorMetric(title: "DRS", value: drs.label)
                                }
                            }
                            if let throttle = telemetry.throttle {
                                PedalReading(title: "Throttle", value: throttle, color: .green)
                            }
                            if let braking = telemetry.brake {
                                PedalReading(title: "Brake", value: braking ? 100 : 0, color: .red,
                                    reading: braking ? "On" : "Off")
                            }
                        }
                    }
                }
            } else {
                Text("Not recorded for this session").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PedalReading: View {
    let title: String
    let value: Double
    let color: Color
    var reading: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            if value.isFinite {
                ProgressView(value: min(100, max(0, value)), total: 100).tint(color)
                    .accessibilityLabel(title).accessibilityValue(reading ?? "\(Int(min(100, max(0, value)))) percent")
                Text(reading ?? "\(Int(min(100, max(0, value))))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

struct InspectorMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct MiniPaceChart: View, Equatable {
    let laps: [LapSample]
    let color: Color
    var body: some View {
        let samples = Array(laps.filter { $0.time.map { $0.isFinite && $0 > 0 } == true }.suffix(12))
        Chart(samples) { lap in
            LineMark(x: .value("Lap", lap.lap), y: .value("Seconds", lap.time ?? 0)).foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: paceDomain(samples)).chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) }
        .accessibilityLabel("Recent completed lap times")
    }
}
