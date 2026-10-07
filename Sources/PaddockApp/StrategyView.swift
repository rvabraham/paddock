import SwiftUI
import PaddockCore

struct StrategyView: View {
    let store: RaceStore
    let inspect: (Int) -> Void

    var body: some View {
        let currentLap = max(1, store.currentLap)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tyre stints").font(.title3.weight(.semibold))
                        Text(store.currentLap > 0 ? "Stints observed through lap \(currentLap). Select a driver for detail." : "Tyre stints appear as completed laps are recorded.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET"], id: \.self) { TyreBadge(compound: $0) }
                    }
                }
                HStack(spacing: 16) {
                    Text("Driver").frame(width: 95, alignment: .leading)
                    HStack {
                        Text("1")
                        Spacer()
                        Text("Lap \(currentLap)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                LazyVStack(spacing: 0) {
                    ForEach(store.drivers) { row in
                        let stints = store.stintHistory(for: row.id)
                        Button { inspect(row.id) } label: {
                            StrategyStints(driver: row.driver, position: row.position, lap: row.lap, stints: stints, currentLap: currentLap)
                                .equatable()
                                .padding(.vertical, 9).padding(.horizontal, 10)
                                .contentShape(Rectangle())
                                .background(row.id == store.selectedDriverNumber ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Inspect \(row.driver.name.localizedCapitalized)")
                        .accessibilityLabel("\(row.driver.name.localizedCapitalized), \(tyreName(row.compound)) tyres, \(row.tyreAge.map { "\($0) laps" } ?? "age unavailable")")
                        .accessibilityAddTraits(row.id == store.selectedDriverNumber ? .isSelected : [])
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct StrategyStints: View, Equatable {
    let driver: Driver
    let position: Int?
    let lap: Int
    let stints: [StintSample]
    let currentLap: Int

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                TeamMark(colorHex: driver.colorHex)
                Text(driver.acronym).font(.callout.weight(.medium))
                Text(position.map(String.init) ?? "—").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 95, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4))
                    ForEach(Array(stints.enumerated()), id: \.offset) { _, stint in
                        let start = max(0, stint.startLap - 1)
                        let end = min(stint.endLap ?? lap, lap)
                        if end > start {
                            let width = Double(end - start) / Double(currentLap) * geometry.size.width
                            RoundedRectangle(cornerRadius: 4).fill(tyreColor(stint.compound).opacity(0.8))
                                .overlay {
                                    if width > 42 {
                                        Text("\(stint.compound.prefix(1)) · \(end - start)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(stint.compound.uppercased() == "WET" ? .white : .black)
                                    }
                                }
                                .frame(width: max(2, width - 2))
                                .offset(x: Double(start) / Double(currentLap) * geometry.size.width)
                        }
                    }
                }
            }
            .frame(height: 24)
            .accessibilityHidden(true)
        }
    }
}
