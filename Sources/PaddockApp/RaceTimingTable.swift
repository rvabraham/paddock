import SwiftUI
import PaddockCore

struct RaceTimingTable: View {
    @Bindable var store: RaceStore
    let filter: String
    let inspect: (Int) -> Void

    private var visibleDrivers: [DriverState] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.drivers }
        return store.drivers.filter {
            "\($0.driver.name) \($0.driver.team) \($0.driver.acronym) \($0.id)".localizedStandardContains(query)
        }
    }

    var body: some View {
        let rows = visibleDrivers
        return Table(rows, selection: Binding(get: { store.selectedDriverNumber }, set: { if let number = $0 { store.selectedDriverNumber = number } })) {
            TableColumn("Pos") { row in
                Text(row.position.map(String.init) ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(row.position == 1 ? Color.primary : Color.secondary)
            }.width(32)
            TableColumn("Driver") { row in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: row.driver.colorHex)).frame(width: 3, height: 18)
                    Text(row.driver.name.localizedCapitalized).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }.width(min: 135, ideal: 180)
            TableColumn("Gap") { row in Text(row.gap.isEmpty ? "—" : row.gap).monospacedDigit().font(.system(size: 12)) }.width(min: 65, ideal: 76)
            TableColumn("Interval") { row in Text(row.interval.isEmpty ? "—" : row.interval).monospacedDigit().font(.system(size: 12)).foregroundStyle(.secondary) }.width(min: 65, ideal: 76)
            TableColumn("Last lap") { row in Text(formatLapTime(row.lastLap)).monospacedDigit().font(.system(size: 12)) }.width(min: 70, ideal: 80)
            TableColumn("Best lap") { row in Text(formatLapTime(row.bestLap)).monospacedDigit().font(.system(size: 12)).foregroundStyle(.secondary) }.width(min: 70, ideal: 80)
            TableColumn("Tyre") { row in
                HStack(spacing: 5) {
                    TyreBadge(compound: row.compound)
                    Text(row.tyreAge.map { "\($0)L" } ?? "—").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    if row.status == .inPit || row.status == .retired {
                        Text(driverStatusLabel(row.status)).font(.system(size: 9, weight: .semibold)).foregroundStyle(driverStatusColor(row.status))
                    }
                }
            }.width(min: 63, ideal: 75)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int.self) { numbers in
            if let number = numbers.first {
                Button("Inspect driver") { inspect(number) }
            }
        } primaryAction: { numbers in
            if let number = numbers.first { inspect(number) }
        }
        .overlay {
            if !filter.isEmpty && rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .accessibilityLabel("Race timing. Select a driver to inspect their race.")
    }
}
