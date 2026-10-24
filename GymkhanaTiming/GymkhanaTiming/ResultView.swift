import SwiftUI

struct ResultView: View {
    let laps: [LapAttempt]
    let videoURL: URL
    let p1: CGPoint
    let p2: CGPoint
    let onRestart: () -> Void

    var body: some View {
        NavigationStack {
            List(laps) { lap in
                NavigationLink {
                    LapDetailView(lap: lap, videoURL: videoURL, p1: p1, p2: p2)
                } label: {
                    LapRow(lap: lap)
                }
            }
            .navigationTitle("Заезды (\(laps.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Новая сессия", action: onRestart)
                }
            }
        }
    }
}

private struct LapRow: View {
    let lap: LapAttempt

    var body: some View {
        HStack {
            Text("Заезд \(lap.index)")
            Spacer()
            if let duration = lap.duration {
                Text(String(format: "%.3f с", duration))
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("не завершён")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
