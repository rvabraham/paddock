import SwiftUI
import PaddockCore

struct StandingsView: View {
    let store: RaceStore
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var category = "Drivers"
    @State private var standingsError: String?
    @State private var refreshing = false

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var standings: [Standing] {
        guard store.standingsYear == year else { return [] }
        return (category == "Drivers" ? store.driverStandings : store.constructorStandings)
            .sorted { $0.position < $1.position }
    }
    private var sourceNote: String {
        if store.standingsYear == year, let round = store.standingsRound {
            return "\(String(year)) season · After round \(round) · Jolpica F1"
        }
        return "\(String(year)) season · Championship standings from Jolpica F1"
    }

    var body: some View {
        let entries = standings
        let leadingPoints = entries.first?.points ?? 0
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    headerTitle.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 16)
                    headerControls
                }
                VStack(alignment: .leading, spacing: 16) {
                    headerTitle
                    HStack {
                        headerControls
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(24)

            if let standingsError { PaddockInlineError(message: standingsError) }

            if entries.isEmpty {
                if refreshing || store.isStandingsLoading {
                    ProgressView("Loading the championship…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PaddockEmptyState(title: "Standings unavailable", systemImage: "trophy",
                                      description: "Choose another season or refresh to try again.")
                }
            } else {
                Table(entries) {
                    TableColumn("Pos") { entry in
                        Text(String(entry.position))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(entry.position <= 3 ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(42)
                    TableColumn(category == "Drivers" ? "Driver" : "Constructor") { entry in
                        HStack(spacing: 12) {
                            TeamMark(colorHex: entry.colorHex)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).fontWeight(.semibold)
                                if category == "Drivers" {
                                    Text(entry.team).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                    .width(min: 180, ideal: 270)
                    TableColumn("Points") { entry in
                        HStack(spacing: 14) {
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: entry.colorHex).opacity(0.8))
                                    .frame(width: geometry.size.width * (leadingPoints > 0 ? min(1, max(0, entry.points / leadingPoints)) : 0), height: 4)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(minWidth: 40, maxWidth: 180, minHeight: 20, maxHeight: 20)
                            .accessibilityHidden(true)
                            Text(entry.points.formatted(.number.precision(.fractionLength(0...1))))
                                .fontWeight(.semibold).monospacedDigit()
                                .frame(width: 45, alignment: .trailing)
                        }
                    }
                    .width(min: 130, ideal: 240)
                    TableColumn("To leader") { entry in
                        Text(entry.position == 1 ? "Leader" : entry.points == leadingPoints ? "Level" : "−\((leadingPoints - entry.points).formatted(.number.precision(.fractionLength(0...1))))")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 85, ideal: 95, max: 105)
                    TableColumn("Wins") { entry in
                        Text(String(entry.wins)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(50)
                }
            }
            Divider()
            SourceFooter(text: sourceNote)
        }
        .navigationTitle("Standings")
        .toolbar {
            Button("Refresh standings", systemImage: "arrow.clockwise") { Task { await refresh(force: true) } }
                .disabled(refreshing)
        }
        .task(id: year) { await refresh() }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Championship").font(.largeTitle.weight(.bold))
            Text("Driver and constructor championship points.").foregroundStyle(.secondary)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 16) {
            Picker("Championship", selection: $category) {
                Text("Drivers").tag("Drivers")
                Text("Constructors").tag("Constructors")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 225)
            Picker("Season", selection: $year) {
                ForEach((2023...currentYear).reversed(), id: \.self) { value in
                    Text(String(value)).tag(value)
                }
            }
            .labelsHidden().frame(width: 90)
            .disabled(refreshing)
        }
    }

    private func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        standingsError = nil
        await store.refreshStandings(year: year, force: force)
        guard !Task.isCancelled else { return }
        standingsError = store.standingsError
    }
}
