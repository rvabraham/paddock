import SwiftUI
import AppKit
import PaddockCore

struct TrackView: View {
    @Bindable var store: RaceStore
    let filter: String
    let inspect: (Int) -> Void
    @State private var showAllLabels = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(store.session?.circuit ?? "Circuit").font(.callout.weight(.medium))
                    Spacer()
                    Menu {
                        Toggle("Show all driver labels", isOn: $showAllLabels)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24).help("Map options")
                }.padding(.horizontal, 18).padding(.vertical, 10)
                if store.trackOutline.count >= 3 {
                    let clock = store.replayClock
                    let circuit = CircuitGeometry(outline: store.trackOutline)
                    let metadata = Dictionary(store.drivers.map {
                        ($0.id, CircuitDriver(acronym: $0.driver.acronym, color: Color(hex: $0.driver.colorHex)))
                    }, uniquingKeysWith: { first, _ in first })
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.isRunning)) { context in
                        let date = clock.sessionDate(at: context.date)
                        CircuitCanvas(circuit: circuit, positions: store.renderedPositions(at: date),
                            metadata: metadata, selected: store.selectedDriverNumber,
                            compared: store.comparisonDriverNumbers, showAllLabels: showAllLabels,
                            trackStatus: store.trackStatus) { number, compare in
                                if compare { store.toggleComparisonDriver(number) }
                                else { inspect(number) }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No recorded map", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("This session does not contain enough recorded coordinates to draw the circuit."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    if !store.channelAvailability.coordinates {
                        Text("Coordinates unavailable in this recording")
                    } else {
                        Text("Recorded positions")
                        Text("·")
                        Text("Shift-click to compare")
                    }
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ReplayLeaderboard(store: store, filter: filter, inspect: inspect)
                .frame(width: 360).frame(maxHeight: .infinity)
        }
    }
}

private struct ReplayLeaderboard: View {
    @Bindable var store: RaceStore
    let filter: String
    let inspect: (Int) -> Void

    private var rows: [DriverState] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.drivers : store.drivers.filter {
            "\($0.driver.name) \($0.driver.team) \($0.driver.acronym) \($0.id)".localizedStandardContains(query)
        }
    }

    var body: some View {
        Table(rows, selection: Binding(get: { store.selectedDriverNumber }, set: { if let number = $0 { store.selectedDriverNumber = number } })) {
            TableColumn("P") { row in
                Text(row.position.map(String.init) ?? "—").monospacedDigit().font(.caption)
            }.width(24)
            TableColumn("Driver") { row in
                HStack(spacing: 6) {
                    Rectangle().fill(Color(hex: row.driver.colorHex)).frame(width: 3, height: 15)
                    Text(row.driver.acronym).font(.callout.weight(.medium))
                    if store.comparisonDriverNumbers.contains(row.id) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                .help(row.driver.name.localizedCapitalized)
                .accessibilityLabel(row.driver.name.localizedCapitalized)
            }.width(min: 57, ideal: 67, max: 85)
            TableColumn("Gap") { row in
                Text(row.gap.isEmpty ? "—" : row.gap).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }.width(min: 47, ideal: 60, max: 76)
            TableColumn("Tyre") { row in
                TyreBadge(compound: row.compound)
            }.width(34)
            TableColumn("State") { row in
                Text(driverStatusLabel(row.status)).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(driverStatusColor(row.status))
            }.width(44)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int.self) { numbers in
            if let number = numbers.first {
                Button("Inspect driver") { inspect(number) }
                Button(store.comparisonDriverNumbers.contains(number) ? "Remove from comparison" : "Add to comparison") {
                    store.toggleComparisonDriver(number)
                }
                .disabled(!store.comparisonDriverNumbers.contains(number) && store.comparisonDriverNumbers.count >= 6)
            }
        } primaryAction: { numbers in
            if let number = numbers.first { inspect(number) }
        }
        .overlay {
            if !filter.isEmpty && rows.isEmpty { ContentUnavailableView.search(text: filter) }
        }
        .accessibilityLabel("Replay timing. Select a driver for synchronized detail.")
    }
}

private struct CircuitCanvas: View {
    let circuit: CircuitGeometry
    let positions: [CarPosition]
    let metadata: [Int: CircuitDriver]
    let selected: Int?
    let compared: Set<Int>
    let showAllLabels: Bool
    let trackStatus: String
    let select: (Int, Bool) -> Void
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let projection = CircuitProjection(circuit: circuit, size: geometry.size)
            let cars = positions.map { CircuitCar(position: $0, center: projection.point($0.x, $0.y)) }
            let labels = placedLabels(cars: cars, metadata: metadata, size: geometry.size)
            Canvas { context, _ in
                for car in cars.sorted(by: { priority($0.position.driverNumber) > priority($1.position.driverNumber) }) {
                    let number = car.position.driverNumber
                    let color = metadata[number]?.color ?? .secondary
                    let emphasized = number == selected || number == hovered || compared.contains(number)
                    let diameter: CGFloat = emphasized ? 11 : 7
                    let dot = CGRect(x: car.center.x - diameter / 2, y: car.center.y - diameter / 2, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                    context.stroke(Path(ellipseIn: dot), with: .color(.primary.opacity(0.75)), lineWidth: emphasized ? 1.5 : 0.7)
                }
                for label in labels {
                    let color = metadata[label.number]?.color ?? .secondary
                    var connector = Path()
                    connector.move(to: label.center)
                    connector.addLine(to: CGPoint(x: label.rect.midX, y: label.rect.midY))
                    context.stroke(connector, with: .color(color.opacity(0.45)), lineWidth: 0.7)
                    context.fill(Path(roundedRect: label.rect, cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
                    context.draw(Text(metadata[label.number]?.acronym ?? String(label.number))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary),
                        at: CGPoint(x: label.rect.midX, y: label.rect.midY))
                }
            }
            .background {
                CircuitOutline(circuit: circuit, projection: projection, status: trackStatus).equatable()
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = nearestCar(to: location, cars: cars)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let number = nearestCar(to: value.location, cars: cars) {
                    select(number, NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(positions.count) recorded car positions on the circuit. Use the timing list to select a driver.")
            .overlay {
                if positions.isEmpty {
                    Text("No recorded car positions at this time")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func priority(_ number: Int) -> Int {
        if number == selected { return 0 }
        if number == hovered { return 1 }
        if compared.contains(number) { return 2 }
        return 3
    }

    private func nearestCar(to point: CGPoint, cars: [CircuitCar]) -> Int? {
        let nearest = cars.min {
            hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y)
        }
        guard let nearest, hypot(nearest.center.x - point.x, nearest.center.y - point.y) <= 18 else { return nil }
        return nearest.position.driverNumber
    }

    private func placedLabels(cars: [CircuitCar], metadata: [Int: CircuitDriver], size: CGSize) -> [CircuitLabel] {
        let ordered = cars.filter { showAllLabels || priority($0.position.driverNumber) < 3 }
            .sorted {
                let left = priority($0.position.driverNumber), right = priority($1.position.driverNumber)
                return left == right ? $0.position.driverNumber < $1.position.driverNumber : left < right
            }
        let dots = cars.map { CGRect(x: $0.center.x - 6, y: $0.center.y - 6, width: 12, height: 12) }
        var labels: [CircuitLabel] = []
        for car in ordered {
            guard metadata[car.position.driverNumber] != nil else { continue }
            var candidates: [CGRect] = []
            for radius: CGFloat in [18, 38, 58, 78, 98] {
                for offset in [CGPoint(x: radius, y: -8), CGPoint(x: -radius - 36, y: -8),
                               CGPoint(x: -18, y: -radius - 16), CGPoint(x: -18, y: radius),
                               CGPoint(x: radius, y: -radius), CGPoint(x: -radius - 36, y: radius)] {
                    let x = min(max(5, car.center.x + offset.x), max(5, size.width - 41))
                    let y = min(max(5, car.center.y + offset.y), max(5, size.height - 21))
                    candidates.append(CGRect(x: x, y: y, width: 36, height: 16))
                }
            }
            if let rect = candidates.first(where: { candidate in
                !labels.contains(where: { $0.rect.insetBy(dx: -3, dy: -3).intersects(candidate) }) &&
                !dots.contains(where: { $0.intersects(candidate) })
            }) {
                labels.append(CircuitLabel(number: car.position.driverNumber, center: car.center, rect: rect))
            }
        }
        return labels
    }
}

private struct CircuitDriver {
    let acronym: String
    let color: Color
}

private struct CircuitGeometry: Equatable {
    let outline: [TrackPoint]
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double

    init(outline: [TrackPoint]) {
        var minX = outline.first?.x ?? 0, maxX = minX, minY = outline.first?.y ?? 0, maxY = minY
        for point in outline { minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y) }
        self.outline = outline
        centerX = (minX + maxX) / 2
        centerY = (minY + maxY) / 2
        width = max(1, maxX - minX)
        height = max(1, maxY - minY)
    }
}

private struct CircuitOutline: View, Equatable {
    let circuit: CircuitGeometry
    let projection: CircuitProjection
    let status: String

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for (index, sample) in circuit.outline.enumerated() {
                let point = projection.point(sample.x, sample.y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.secondary.opacity(0.1)), style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(trackColor(status).opacity(0.45)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct CircuitProjection: Equatable {
    let centerX: Double
    let centerY: Double
    let scale: Double
    let size: CGSize
    init(circuit: CircuitGeometry, size: CGSize) {
        centerX = circuit.centerX
        centerY = circuit.centerY
        scale = min(max(1, size.width - 70) / circuit.width, max(1, size.height - 70) / circuit.height)
        self.size = size
    }
    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (x - centerX) * scale + size.width / 2, y: -(y - centerY) * scale + size.height / 2)
    }
}
private struct CircuitCar { let position: CarPosition; let center: CGPoint }
private struct CircuitLabel { let number: Int; let center: CGPoint; let rect: CGRect }

func driverStatusLabel(_ status: DriverRaceStatus) -> String {
    switch status {
    case .racing: ""
    case .inPit: "PIT"
    case .retired: "OUT"
    case .finished: "END"
    case .unknown: "—"
    }
}
func driverStatusColor(_ status: DriverRaceStatus) -> Color {
    switch status {
    case .inPit: .orange
    case .retired: .secondary
    default: .secondary
    }
}
