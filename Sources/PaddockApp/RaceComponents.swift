import SwiftUI
import PaddockCore

struct TyreBadge: View {
    var compound: String
    var body: some View {
        let known = ["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET"].contains(compound.uppercased())
        let label = known ? String(compound.prefix(1)).uppercased() : "—"
        Text(label).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
            .foregroundStyle(tyreColor(compound)).background(tyreColor(compound).opacity(0.08), in: Circle())
            .overlay(Circle().stroke(tyreColor(compound).opacity(0.6), lineWidth: 1.5))
            .accessibilityLabel(known ? "\(compound.capitalized) tyre" : "Tyre unavailable")
            .help(known ? "\(compound.capitalized) tyre" : "Tyre unavailable")
    }
}

let replayRates = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0]

func playbackRateLabel(_ rate: Double) -> String {
    "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
}

func tyreName(_ compound: String) -> String {
    switch compound.uppercased() {
    case "SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET": compound.capitalized
    default: "Unavailable"
    }
}

struct ControlMessageRow: View {
    let message: ControlMessage
    private var categoryName: String {
        switch message.category.uppercased() {
        case "DRS": "DRS"
        case "SESSIONSTATUS", "SESSION_STATUS": "Session status"
        case "SAFETYCAR", "SAFETY_CAR": "Safety car"
        case "RACECONTROL", "RACE_CONTROL": "Race control"
        default: message.category.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "(?<=[a-z])(?=[A-Z])", with: " ", options: .regularExpression)
            .localizedCapitalized
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.flag == nil ? "info.circle" : "flag.fill")
                .foregroundStyle(trackColor(message.flag ?? "")).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(message.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Text(message.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(categoryName)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 9)
    }
}

func tyreColor(_ compound: String) -> Color {
    switch compound.uppercased() {
    case "SOFT": Color(red: 0.9, green: 0.18, blue: 0.23)
    case "MEDIUM": Color(red: 0.68, green: 0.52, blue: 0.0)
    case "HARD": Color.secondary
    case "INTERMEDIATE": Color.green
    case "WET": Color.blue
    default: Color.secondary
    }
}
func trackColor(_ status: String) -> Color {
    let status = status.uppercased()
    if status.contains("RED") { return .red }
    if status.contains("YELLOW") || status.contains("SAFETY") || status.contains("VSC") { return .orange }
    if status.contains("GREEN") || status.contains("CLEAR") { return .green }
    if status.contains("BLUE") { return .blue }
    return .secondary
}

func paceDomain(_ samples: [LapSample]) -> ClosedRange<Double> {
    let times = samples.compactMap(\.time)
    guard let minimum = times.min(), let maximum = times.max() else { return 0...100 }
    return max(0, minimum - 1)...(maximum + 1)
}
