import SwiftUI
import UniformTypeIdentifiers

enum Stage {
    case start
    case record
    case calibrate(videoURL: URL)
    case analyzing(videoURL: URL, p1: CGPoint, p2: CGPoint)
    case result(AnalysisResult)
    case error(String)
}

struct ContentView: View {
    @State private var stage: Stage = .start
    @State private var isImportingVideo = false
    @State private var importError: String?

    var body: some View {
        switch stage {
        case .start:
            VStack(spacing: 20) {
                Text("Gymkhana Timing")
                    .font(.title2.bold())

                Button("Записать заезд") { stage = .record }
                    .buttonStyle(.borderedProminent)

                Button("Debug: загрузить видео из файлов") { isImportingVideo = true }
                    .buttonStyle(.bordered)

                if let importError {
                    Text(importError).foregroundColor(.red).font(.footnote)
                }
            }
            .padding()
            .fileImporter(isPresented: $isImportingVideo, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url):
                    importPickedVideo(url)
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }

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
                stage = .start
            }

        case .error(let message):
            VStack(spacing: 16) {
                Text("Ошибка: \(message)")
                Button("Заново") { stage = .start }
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

    /// Debug-режим: видео берётся не с камеры, а из Files, чтобы можно было
    /// прогнать VideoAnalyzer на заранее записанных тестовых заездах.
    private func importPickedVideo(_ pickedURL: URL) {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "mov" : pickedURL.pathExtension)
        do {
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.copyItem(at: pickedURL, to: localURL)
            importError = nil
            stage = .calibrate(videoURL: localURL)
        } catch {
            importError = "Не удалось загрузить файл: \(error.localizedDescription)"
        }
    }
}
