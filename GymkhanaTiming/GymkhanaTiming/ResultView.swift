import SwiftUI

struct ResultView: View {
    let output: AnalysisOutput
    let videoURL: URL
    let p1: CGPoint
    let p2: CGPoint
    let onRestart: () -> Void

    @State private var diagnosticsURL: URL?
    @State private var isSharingDiagnostics = false

    /// Только завершённые заезды, пронумерованные подряд. Попытки без
    /// финиша (райдер выехал и не вернулся через створ, или проехал линию
    /// уже после финиша) — это не заезды, показывать их в списке только
    /// путает.
    private var laps: [LapAttempt] {
        output.laps
            .filter { $0.finish != nil }
            .enumerated()
            .map { $1.with(index: $0 + 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if laps.isEmpty {
                    Text("Не удалось засечь ни одного завершённого заезда. Проверьте, что линия проведена по основаниям стартовых конусов.")
                        .foregroundColor(AppTheme.textSecondary)
                } else {
                    ForEach(laps) { lap in
                        NavigationLink {
                            LapDetailView(lap: lap, videoURL: videoURL, p1: p1, p2: p2)
                        } label: {
                            LapRow(lap: lap)
                        }
                    }
                }
            }
            .navigationTitle("Заезды (\(laps.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            shareDiagnostics()
                        } label: {
                            Label("Отправить диагностику", systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Новая сессия", action: onRestart)
                }
            }
            .sheet(isPresented: $isSharingDiagnostics) {
                if let diagnosticsURL { ShareSheet(items: [diagnosticsURL]) }
            }
        }
    }
}

extension ResultView {
    /// Сохраняет текстовый отчёт анализа во временный файл и открывает
    /// системное окно «Поделиться» — чтобы переслать его разработчику.
    fileprivate func shareDiagnostics() {
        let device = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
        let text = "device=\(device)\n" + output.diagnostics
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gymkhana-diagnostics.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsURL = url
            isSharingDiagnostics = true
        } catch {
            diagnosticsURL = nil
        }
    }
}

private struct LapRow: View {
    let lap: LapAttempt

    var body: some View {
        HStack {
            Image(systemName: "flag.checkered")
                .foregroundColor(AppTheme.accent)
            Text("Заезд \(lap.index)")
                .font(.appHeadline(16))
            Spacer()
            if let duration = lap.duration {
                Text(String(format: "%.3f с", duration))
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(AppTheme.accent)
            }
        }
    }
}
