import SwiftUI
import PaddockCore

struct CalendarView: View {
    @Bindable var store: RaceStore
    let onOpenSession: () -> Void
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = 0
    @State private var expandedRounds: Set<Int> = []
    @State private var openingSession = false
    @State private var openingTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshing = false
    @State private var calendarError: String?
    @State private var isVisible = false

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var weekends: [RaceWeekend] {
        store.calendar.filter { Calendar.current.component(.year, from: $0.date) == year }
            .sorted { $0.date < $1.date }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: scenePhase != .active)) { context in
            content(at: context.date)
        }
        .navigationTitle("Calendar")
        .toolbar {
            Button("Refresh calendar", systemImage: "arrow.clockwise") {
                Task { await refresh(force: true) }
            }
            .disabled(refreshing || openingSession)
        }
        .task(id: year) { await refresh() }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            if openingSession { openingTask?.cancel(); store.cancelLoading() }
        }
        .onChange(of: year) { _, _ in
            month = 0
            expandedRounds = []
        }
    }

    private func content(at now: Date) -> some View {
        let values = weekends
        let groups = Dictionary(grouping: values) { Calendar.current.component(.month, from: $0.date) }
        let monthNumbers = groups.keys.sorted()
        let upcoming = values.first { $0.hasKnownTime ? $0.date.addingTimeInterval(3 * 3600) > now : ($0.date > now || Calendar.current.isDate($0.date, inSameDayAs: now)) }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Race calendar").font(.largeTitle.weight(.bold))
                    Text("Session times in your Mac’s time zone.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Month", selection: $month) {
                    Text("All months").tag(0)
                    ForEach(monthNumbers, id: \.self) { number in
                        Text(Calendar.current.monthSymbols[number - 1]).tag(number)
                    }
                }
                .labelsHidden().frame(width: 135)
                Picker("Season", selection: $year) {
                    ForEach((2018...(currentYear + 1)).reversed(), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
                .labelsHidden().frame(width: 90)
                .disabled(refreshing || openingSession)
            }
            .padding(24)

            if let calendarError { PaddockInlineError(message: calendarError) }
            if openingSession {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.isLoading ? store.loadingLabel : "Finding session timing…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { openingTask?.cancel(); store.cancelLoading() }
                        .controlSize(.small).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
            }

            if values.isEmpty {
                if refreshing || store.isCalendarLoading {
                    ProgressView("Loading the calendar…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PaddockEmptyState(title: "No calendar available", systemImage: "calendar",
                                      description: "Choose another season or refresh to try again.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if month == 0, let upcoming { nextWeekend(upcoming, now: now) }
                        ForEach(monthNumbers.filter { month == 0 || month == $0 }, id: \.self) { number in
                            Text(Calendar.current.monthSymbols[number - 1])
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 26)
                                .padding(.bottom, 12)
                            VStack(spacing: 0) {
                                ForEach(groups[number] ?? []) { weekend in
                                    weekendRow(weekend, now: now)
                                    Divider().padding(.leading, 82)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            SourceFooter(text: "Local times · \(TimeZone.current.identifier.replacingOccurrences(of: "_", with: " ")) · Calendar from Jolpica F1")
        }
    }

    private func nextWeekend(_ weekend: RaceWeekend, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Up next", systemImage: "flag.checkered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Round \(weekend.round)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) {
                    nextWeekendTitle(weekend)
                    Spacer(minLength: 16)
                    nextSessionCountdown(weekend, now: now)
                }
                VStack(alignment: .leading, spacing: 16) {
                    nextWeekendTitle(weekend)
                    nextSessionCountdown(weekend, now: now)
                }
            }
            if let first = weekend.sessions.filter({ $0.hasKnownTime && $0.date > now }).min(by: { $0.date < $1.date }) {
                Text("\(first.name) · \(first.date.formatted(.dateTime.weekday(.wide).hour().minute()))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.f1Red)
                .frame(width: 3).padding(.vertical, 24)
        }
    }

    private func nextWeekendTitle(_ weekend: RaceWeekend) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(weekend.name).font(.system(size: 28, weight: .semibold))
            Text(weekend.circuit).foregroundStyle(.secondary)
        }
    }

    private func nextSessionCountdown(_ weekend: RaceWeekend, now: Date) -> some View {
        let nextDate = weekend.sessions.filter(\.hasKnownTime).map(\.date)
            .filter { $0 > now }.min() ?? (weekend.hasKnownTime ? weekend.date : nil)
        return VStack(alignment: .trailing, spacing: 4) {
            if let nextDate, nextDate > now {
                Text(countdown(to: nextDate, from: now)).font(.title2.weight(.medium)).monospacedDigit()
                Text("until the next session").font(.caption).foregroundStyle(.secondary)
            } else if nextDate != nil {
                Text("Race weekend").font(.title2.weight(.medium))
                Text("Recorded sessions appear after the weekend").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Time TBA").font(.title2.weight(.medium))
                Text("Session times to be confirmed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        let days = minutes / 1440
        let hours = minutes / 60 % 24
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    private func weekendRow(_ weekend: RaceWeekend, now: Date) -> some View {
        let expanded = expandedRounds.contains(weekend.round)
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedRounds.remove(weekend.round) }
                else { expandedRounds.insert(weekend.round) }
            } label: {
                HStack(spacing: 20) {
                    VStack(spacing: 3) {
                        Text(weekend.date.formatted(.dateTime.day())).font(.title2.weight(.semibold)).monospacedDigit()
                        Text(weekend.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(weekend.name).font(.headline)
                        Text(weekend.circuit).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(weekend.hasKnownTime ? weekend.date.formatted(.dateTime.hour().minute()) : "Time TBA").monospacedDigit()
                        Text("Round \(weekend.round)").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 16)
                }
                .padding(.vertical, 17)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(weekend.name), round \(weekend.round), \(weekend.date.formatted(date: .complete, time: weekend.hasKnownTime ? .shortened : .omitted))\(weekend.hasKnownTime ? "" : ", time to be announced")")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show the weekend’s session times")

            if expanded {
                VStack(spacing: 12) {
                    ForEach(weekend.sessions, id: \.self) { session in
                        HStack(spacing: 14) {
                            Text(session.name).frame(minWidth: 120, alignment: .leading)
                            Text(session.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(session.hasKnownTime ? session.date.formatted(.dateTime.hour().minute()) : "Time TBA").monospacedDigit()
                            if session.hasKnownTime && session.date < now {
                                Button("Open", systemImage: "play.fill") {
                                    beginOpening(session)
                                }
                                .controlSize(.small)
                                .disabled(openingSession || store.isLoading)
                                .help("Open recorded \(session.name)")
                            } else {
                                Text(session.hasKnownTime ? "Upcoming" : "Unconfirmed").font(.caption).foregroundStyle(.tertiary).frame(width: 75)
                            }
                        }
                        .font(.callout)
                    }
                    if weekend.sessions.isEmpty {
                        Text("Session times have not been published.").foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 68)
                .padding(.trailing, 36)
                .padding(.bottom, 20)
            }
        }
    }

    private func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        calendarError = nil
        await store.refreshCalendar(year: year, force: force)
        guard !Task.isCancelled else { return }
        calendarError = store.calendarError
    }

    private func beginOpening(_ session: WeekendSession) {
        guard !openingSession, !store.isLoading else { return }
        openingSession = true
        calendarError = nil
        openingTask = Task { await open(session) }
    }

    private func open(_ scheduled: WeekendSession) async {
        defer { openingSession = false; openingTask = nil }
        let selectedYear = year
        await store.fetchSessions(year: selectedYear)
        guard !Task.isCancelled else { return }
        let candidates = store.sessions.filter {
            $0.year == selectedYear && $0.matchesScheduledName(scheduled.name) && abs($0.startsAt.timeIntervalSince(scheduled.date)) < 2 * 3600
        }
        guard let session = candidates.min(by: {
            abs($0.startsAt.timeIntervalSince(scheduled.date)) < abs($1.startsAt.timeIntervalSince(scheduled.date))
        }) else {
            calendarError = store.sessionsError ?? "Timing data for this session is not available yet. Try again after the session."
            return
        }
        await store.loadSession(session)
        if isVisible, !Task.isCancelled, store.errorMessage == nil, store.session?.key == session.key { onOpenSession() }
        guard !Task.isCancelled else { return }
        calendarError = store.errorMessage
    }
}
