import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable

enum Stage {
    case start
    case record
    case calibrate(videoURL: URL)
    case analyzing(videoURL: URL, p1: CGPoint, p2: CGPoint)
    case result(AnalysisResult, videoURL: URL, p1: CGPoint, p2: CGPoint)
    case error(String)
}

struct ContentView: View {
    @State private var stage: Stage = .start
    @State private var isImportingVideo = false
    @State private var importError: String?
    @State private var photosPickerItem: PhotosPickerItem?

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

                // Привязка через собственный Binding, а не через .onChange —
                // двухпараметрический .onChange доступен только с iOS 17
                // (у нас deployment target 16.0, был бы compile error), а
                // старый однопараметрический помечен deprecated и ловится
                // CI-проверкой "любой warning — это провал сборки".
                PhotosPicker(
                    selection: Binding(
                        get: { photosPickerItem },
                        set: { newItem in
                            photosPickerItem = newItem
                            if let newItem {
                                Task { await importPickedVideo(fromPhotos: newItem) }
                            }
                        }
                    ),
                    matching: .videos
                ) {
                    Text("Debug: загрузить видео из галереи")
                }
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

        case .result(let result, let videoURL, let p1, let p2):
            ResultView(result: result, videoURL: videoURL, p1: p1, p2: p2) {
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
                await MainActor.run { stage = .result(result, videoURL: videoURL, p1: p1, p2: p2) }
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

    /// То же самое, но источник — системная галерея (Фото), а не Files.
    /// PhotosPicker отдаёт видео через Transferable, который сам копирует
    /// исходный файл во временную папку приложения — грузить весь ролик
    /// в память как Data не нужно (а на заезде в минуту-две это было бы
    /// соответствующим объёмом оперативной памяти).
    private func importPickedVideo(fromPhotos item: PhotosPickerItem) async {
        do {
            guard let video = try await item.loadTransferable(type: TransferableVideo.self) else {
                await MainActor.run { importError = "Не удалось загрузить видео из галереи" }
                return
            }
            await MainActor.run {
                importError = nil
                photosPickerItem = nil
                stage = .calibrate(videoURL: video.url)
            }
        } catch {
            await MainActor.run { importError = "Не удалось загрузить видео из галереи: \(error.localizedDescription)" }
        }
    }
}

private struct TransferableVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.copyItem(at: received.file, to: localURL)
            return Self(url: localURL)
        }
    }
}
