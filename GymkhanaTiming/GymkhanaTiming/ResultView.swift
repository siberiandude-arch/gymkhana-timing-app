import SwiftUI

struct ResultView: View {
    let output: AnalysisOutput
    let videoURL: URL
    let p1: CGPoint
    let p2: CGPoint
    let onRestart: () -> Void

    @State private var rule: TimingRule = .frontToRear

    private var laps: [LapAttempt] { output.laps.map { $0.with(rule: rule) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Правило", selection: $rule) {
                        ForEach(TimingRule.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    ForEach(laps) { lap in
                        NavigationLink {
                            LapDetailView(lap: lap, videoURL: videoURL, p1: p1, p2: p2)
                        } label: {
                            LapRow(lap: lap)
                        }
                    }
                }

                // Сырой список пересечений створа — чтобы можно было
                // разобраться, почему заезд не состыковался (нет финиша,
                // лишние попытки), не выковыривая видео и логи вручную.
                Section("Отладка: пересечения створа (\(output.crossings.count))") {
                    DisclosureGroup("Показать") {
                        ForEach(output.crossings) { crossing in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(String(format: "%.3f с", crossing.time))
                                        .font(.system(.footnote, design: .monospaced))
                                    Spacer()
                                    Text(crossing.isExit ? "выезд →" : "← возврат")
                                        .font(.footnote)
                                        .foregroundColor(crossing.isExit ? .orange : .blue)
                                }
                                Text(String(format: "перед %.3f · зад %.3f · Δ %.2f · у камеры: %@%@",
                                            crossing.tFront, crossing.tRear, crossing.delta,
                                            crossing.nearIsFront ? "перед" : "зад",
                                            crossing.compensated ? "" : " (без поправки)"))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(AppTheme.textSecondary)
                            }
                        }
                    }
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
            Image(systemName: lap.duration != nil ? "flag.checkered" : "xmark.circle")
                .foregroundColor(lap.duration != nil ? AppTheme.accent : AppTheme.textSecondary)
            Text("Заезд \(lap.index)")
                .font(.appHeadline(16))
            Spacer()
            if let duration = lap.duration {
                Text(String(format: "%.3f с", duration))
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(AppTheme.accent)
            } else {
                Text("не завершён")
                    .foregroundColor(AppTheme.textSecondary)
                    .italic()
            }
        }
    }
}
