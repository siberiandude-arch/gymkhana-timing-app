import SwiftUI

enum Stage {
    case record
    case calibrate(videoURL: URL)
    case analyzing(videoURL: URL, p1: CGPoint, p2: CGPoint)
    case result(AnalysisResult)
    case error(String)
}

struct ContentView: View {
    @State private var stage: Stage = .record

    var body: some View {
        switch stage {
        case .record:
            RecordView { url in
                stage = .calibrate(videoURL: url)
            }

        case .calibrate(let videoURL):
            CalibrationView(videoURL: videoURL) { p1, p2 in
                stage = .analyzing(videoURL: videoURL, p1: p1, p2: p2)
                runAnalysis(videoURL: videoURL, p1: p1, p2: p2)
            }

        case .analyzing:
            VStack(spacing: 16) {
                ProgressView()
                Text("Считаю время...")
            }

        case .result(let result):
            ResultView(result: result) {
                stage = .record
            }

        case .error(let message):
            VStack(spacing: 16) {
                Text("Ошибка: \(message)")
                Button("Заново") { stage = .record }
            }
            .padding()
        }
    }

    private func runAnalysis(videoURL: URL, p1: CGPoint, p2: CGPoint) {
        Task {
            do {
                let result = try await VideoAnalyzer.analyze(videoURL: videoURL, p1: p1, p2: p2)
                await MainActor.run { stage = .result(result) }
            } catch {
                await MainActor.run { stage = .error("\(error)") }
            }
        }
    }
}
