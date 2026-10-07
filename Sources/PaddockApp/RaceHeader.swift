import SwiftUI
import PaddockCore

struct RaceHeader: View {
    let store: RaceStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.session?.title ?? "Replay").font(.headline).lineLimit(1)
                if let session = store.session {
                    Text("\(session.sessionName) · \(session.startsAt.formatted(.dateTime.day().month(.abbreviated).year()))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if store.session?.isQualifying == true, let phase = store.qualifyingPhase {
                Text(phase.rawValue).font(.callout.monospacedDigit())
            } else if store.currentLap > 0 {
                Text("Lap \(store.currentLap)").font(.callout.monospacedDigit())
            }
            if store.session != nil {
                Text(store.trackStatus).font(.caption).foregroundStyle(trackColor(store.trackStatus))
                    .lineLimit(1).help(store.trackStatus)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}
