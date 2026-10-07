import SwiftUI
import Charts
import PaddockCore

struct PaceView: View {
    let store: RaceStore
    @Binding var chosen: Set<Int>
    @Binding var includeSlowLaps: Bool

    var body: some View {
        let series = comparisonSeries()
        let availableNumbers = store.drivers.map(\.id).sorted()
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lap pace").font(.title3.weight(.semibold))
                        Text("Compare completed lap times at the current session position.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(store.drivers) { row in
                            Toggle(row.driver.name.localizedCapitalized, isOn: Binding(get: { chosen.contains(row.id) }, set: { selected in
                                if selected { chosen.insert(row.id) }
                                else { chosen.remove(row.id) }
                            }))
                            .disabled(!chosen.contains(row.id) && chosen.count >= 6)
                        }
                    } label: {
                        Label("Compare drivers", systemImage: "plus")
                    }
                    .help("Compare up to six drivers")
                }
                Toggle("Include slow laps", isOn: $includeSlowLaps)
                    .toggleStyle(.checkbox).font(.callout)
                    .help("Include laps over 120% of each driver's median, such as pit and interruption laps")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(series) { item in
                            HStack(spacing: 6) {
                                LineSwatch(color: Color(hex: item.driver.colorHex), dash: item.dash)
                                    .frame(width: 15, height: 8)
                                Text(item.driver.acronym).font(.caption.weight(.semibold))
                                Button { chosen.remove(item.id) } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.driver.name.localizedCapitalized) from comparison")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.4), in: Capsule())
                        }
                    }
                }
                if series.isEmpty {
                    ContentUnavailableView("Choose drivers to compare", systemImage: "chart.xyaxis.line",
                                           description: Text("Choose up to six drivers from Compare drivers."))
                        .frame(height: 300)
                } else if series.allSatisfy({ $0.laps.isEmpty }) {
                    ContentUnavailableView("No completed lap times yet", systemImage: "stopwatch",
                                           description: Text("Lap times appear after the selected drivers complete a measured lap."))
                        .frame(height: 300)
                } else {
                    PaceComparisonChart(series: series).equatable().frame(height: 320)
                }
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 20) {
                    ForEach(series) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 7) {
                                TeamMark(colorHex: item.driver.colorHex).frame(height: 16)
                                Text(item.driver.acronym).font(.caption.weight(.semibold))
                            }
                            Text(formatLapTime(item.bestLap)).font(.title2.monospacedDigit())
                            Text("Best completed lap").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(includeSlowLaps ? "All measured completed lap times are shown. Missing times are excluded." : "Laps over 120% of each driver’s median are excluded. Enable slow laps to see pit and interruption laps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onChange(of: availableNumbers, initial: true) { _, _ in updateChosenDrivers() }
        .onChange(of: store.session?.key) { _, _ in updateChosenDrivers() }
    }

    private func comparisonSeries() -> [PaceSeries] {
        let rows = store.drivers
        let firstNumbers = Dictionary(grouping: rows, by: { $0.driver.team }).mapValues { $0.map(\.id).min() ?? 0 }
        return rows.filter { chosen.contains($0.id) }.map { row in
            let measured = store.lapHistory(for: row.id).filter { $0.time.map { $0.isFinite && $0 > 0 } == true }
            let times = measured.compactMap(\.time).sorted()
            let median = times.isEmpty ? 0 : times[(times.count - 1) / 2]
            let plotted = includeSlowLaps ? measured : measured.filter { ($0.time ?? 0) <= median * 1.2 }
            return PaceSeries(driver: row.driver, laps: plotted, bestLap: times.first,
                              dash: firstNumbers[row.driver.team] == row.id ? [] : [5, 3])
        }
    }

    private func updateChosenDrivers() {
        chosen.formIntersection(Set(store.drivers.map(\.id)))
        if chosen.isEmpty {
            chosen = Set(store.drivers.prefix(3).map(\.id))
            if let selected = store.selectedDriverNumber, store.drivers.contains(where: { $0.id == selected }), chosen.count < 6 {
                chosen.insert(selected)
            }
        }
    }
}

private struct PaceSeries: Identifiable, Equatable {
    let driver: Driver
    let laps: [LapSample]
    let bestLap: Double?
    let dash: [CGFloat]
    var id: Int { driver.number }
}

private struct PaceComparisonChart: View, Equatable {
    let series: [PaceSeries]

    var body: some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.laps) { lap in
                    LineMark(x: .value("Lap", lap.lap), y: .value("Lap time", lap.time ?? 0),
                             series: .value("Driver", item.driver.acronym))
                        .foregroundStyle(by: .value("Driver", item.driver.acronym))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, dash: item.dash))
                        .accessibilityLabel("\(item.driver.name.localizedCapitalized), lap \(lap.lap)")
                        .accessibilityValue(formatLapTime(lap.time))
                }
            }
        }
        .chartYScale(domain: paceDomain(series.flatMap(\.laps)))
        .chartYAxisLabel("Lap time · seconds")
        .chartForegroundStyleScale(domain: series.map { $0.driver.acronym }, range: series.map { Color(hex: $0.driver.colorHex) })
        .chartLegend(.hidden)
        .chartXAxisLabel("Lap")
        .chartPlotStyle { $0.background(.quaternary.opacity(0.15)) }
        .accessibilityLabel("Completed lap times")
    }
}

struct LineSwatch: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
        }
        .accessibilityHidden(true)
    }
}
