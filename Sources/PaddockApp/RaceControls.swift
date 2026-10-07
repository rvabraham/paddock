import SwiftUI
import PaddockCore

struct ReplayControls: View {
    @Bindable var store: RaceStore
    @State private var lapEntry = ""

    var body: some View {
        VStack(spacing: 7) {
            ReplayEventTimeline(events: store.replayEvents, start: store.session?.startsAt,
                duration: store.replayDuration, seek: store.seekEvent)
                .frame(height: 14)
            HStack(spacing: 10) {
                Text(formatRaceTime(store.replayTime)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
                Slider(value: Binding(get: { store.replayTime }, set: { store.setReplayTime($0) }), in: 0...max(1, store.replayDuration))
                    .accessibilityLabel("Replay position").accessibilityValue(formatRaceTime(store.replayTime))
                Text(formatRaceTime(store.replayDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            }
            HStack(spacing: 14) {
                HStack(spacing: 13) {
                    Button { store.restartReplay() } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Restart replay. Shift–Command–R").accessibilityLabel("Restart replay")
                    Button { store.skipLap(-1) } label: { Image(systemName: "backward.end") }
                        .help("Previous lap. Command–Left Arrow").accessibilityLabel("Previous lap")
                    Button { store.nudgeReplay(-10) } label: { Image(systemName: "gobackward.10") }
                        .help("Back 10 seconds").accessibilityLabel("Back 10 seconds")
                    Button { store.togglePlayback() } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14)).frame(width: 22)
                    }.help("Play or pause. Space").accessibilityLabel(store.isPlaying ? "Pause replay" : "Play replay")
                    Button { store.nudgeReplay(10) } label: { Image(systemName: "goforward.10") }
                        .help("Forward 10 seconds").accessibilityLabel("Forward 10 seconds")
                    Button { store.skipLap(1) } label: { Image(systemName: "forward.end") }
                        .help("Next lap. Command–Right Arrow").accessibilityLabel("Next lap")
                }.buttonStyle(.borderless)
                Divider().frame(height: 17)
                Picker("Playback speed", selection: $store.playbackRate) {
                    ForEach(replayRates, id: \.self) { Text(playbackRateLabel($0)).tag($0) }
                }.labelsHidden().frame(width: 76).controlSize(.small)
                HStack(spacing: 5) {
                    Text("Lap").font(.caption).foregroundStyle(.secondary)
                    TextField(String(max(1, store.currentLap)), text: $lapEntry)
                        .textFieldStyle(.roundedBorder).frame(width: 38)
                        .accessibilityLabel("Seek to lap")
                        .onSubmit {
                            guard let lap = Int(lapEntry), (1...10000).contains(lap) else { return }
                            store.seekLap(lap, driver: store.selectedDriverNumber)
                            lapEntry = ""
                        }
                }
                Spacer(minLength: 0)
                ReplayEventsMenu(store: store)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10).disabled(store.isLoading)
    }
}

private struct ReplayEventsMenu: View {
    let store: RaceStore
    private let groups: [(String, Set<ReplayEventKind>)] = [
        ("Session", [.start, .finish, .qualifying]),
        ("Flags and safety car", [.redFlag, .safetyCar, .flag]),
        ("Pit stops and retirements", [.pit, .retirement]),
        ("Race control", [.raceControl])
    ]
    var body: some View {
        let events = store.replayEvents
        Menu("Events") {
            ForEach(groups, id: \.0) { title, kinds in
                let values = events.filter { kinds.contains($0.kind) }
                if !values.isEmpty {
                    Menu(title) {
                        ForEach(values) { event in
                            Button { store.seekEvent(event) } label: {
                                Label("\(formatRaceTime(event.date.timeIntervalSince(store.session?.startsAt ?? event.date))) · \(event.title)",
                                    systemImage: replayEventSymbol(event.kind))
                            }
                        }
                    }
                }
            }
        }.controlSize(.small).disabled(events.isEmpty)
    }
}

private struct ReplayEventTimeline: View {
    let events: [ReplayEvent]
    let start: Date?
    let duration: Double
    let seek: (ReplayEvent) -> Void
    @State private var hovered: ReplayEvent?

    private var markedEvents: [ReplayEvent] { events.filter { $0.kind != .raceControl } }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let line = CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)
                context.fill(Path(line), with: .color(.secondary.opacity(0.18)))
                for event in markedEvents {
                    let x = eventX(event, width: size.width)
                    let height: CGFloat = event.kind == .pit ? 6 : 12
                    let tick = CGRect(x: x - 1, y: size.height / 2 - height / 2, width: hovered?.id == event.id ? 3 : 2, height: height)
                    context.fill(Path(tick), with: .color(replayEventColor(event.kind)))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = nearestEvent(x: point.x, width: geometry.size.width)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let event = nearestEvent(x: value.location.x, width: geometry.size.width) { seek(event) }
            })
            .help(hovered?.title ?? "Recorded session events. Choose Events for the full list.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recorded event timeline. Choose Events to seek to a named event.")
        }
    }
    private func eventX(_ event: ReplayEvent, width: CGFloat) -> CGFloat {
        guard let start else { return 0 }
        return min(1, max(0, event.date.timeIntervalSince(start) / max(1, duration))) * width
    }
    private func nearestEvent(x: CGFloat, width: CGFloat) -> ReplayEvent? {
        let closest = markedEvents.min { abs(eventX($0, width: width) - x) < abs(eventX($1, width: width) - x) }
        guard let closest, abs(eventX(closest, width: width) - x) <= 9 else { return nil }
        return closest
    }
}

func replayEventSymbol(_ kind: ReplayEventKind) -> String {
    switch kind {
    case .start: "play"
    case .finish: "flag.checkered"
    case .pit: "wrench"
    case .retirement: "xmark.circle"
    case .redFlag, .flag: "flag"
    case .safetyCar: "car"
    case .qualifying: "stopwatch"
    case .raceControl: "info.circle"
    }
}
func replayEventColor(_ kind: ReplayEventKind) -> Color {
    switch kind {
    case .redFlag: .red
    case .safetyCar, .flag: .orange
    case .retirement: .secondary
    default: .secondary.opacity(0.6)
    }
}
