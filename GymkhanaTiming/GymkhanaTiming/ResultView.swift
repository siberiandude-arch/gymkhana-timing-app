import SwiftUI

struct ResultView: View {
    let result: AnalysisResult
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: "%.3f с", result.lap))
                .font(.system(size: 48, weight: .bold, design: .monospaced))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "старт:  %.3f с", result.start))
                Text(String(format: "финиш: %.3f с", result.finish))
                Text("пересечений линии всего: \(result.crossings.count)")
            }
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.secondary)

            Button("Новый заезд", action: onRestart)
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
        }
        .padding()
    }
}
