import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable

enum Stage {
    case start
    case record
    case calibrate(videoURL: URL)
    case analyzing(videoURL: URL, p1: CGPoint, p2: CGPoint)
    case result(AnalysisOutput, videoURL: URL, p1: CGPoint, p2: CGPoint)
    case error(String)
}

struct ContentView: View {
    @State private var stage: Stage = .start
    @State private var isPickingFile = false
    @State private var isPickingFromPhotos = false
    @State private var isImportingMedia = false
    @State private var importError: String?
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showSourceChooser = false
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        switch stage {
        case .start:
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 4) {
                    Image(systemName: "stopwatch.fill")
                        .font(.system(size: 50))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 8)
                    Text("GYMKHANA")
                        .font(.appTitle(30))
                        .foregroundColor(.white)
                    Text("TIMING")
                        .font(.appTitle(30))
                        .foregroundColor(AppTheme.accent)
                }

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        stage = .record
                    } label: {
                        Label("Записать заезд", systemImage: "video.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        showSourceChooser = true
                    } label: {
                        Label("Загрузить видео", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isImportingMedia)
                    .confirmationDialog("Откуда загрузить видео?", isPresented: $showSourceChooser, titleVisibility: .visible) {
                        Button("Из файлов") { isPickingFile = true }
                        Button("Из галереи") { isPickingFromPhotos = true }
                    }

                    if isImportingMedia {
                        ProgressView("Загружаю видео...")
                            .tint(AppTheme.accent)
                            .foregroundColor(AppTheme.textSecondary)
                    }

                    if let importError {
                        Text(importError).foregroundColor(.red).font(.footnote)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .appBackground()
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url):
                    importPickedVideo(url)
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            // Привязка через собственный Binding, а не через .onChange —
            // двухпараметрический .onChange доступен только с iOS 17
            // (у нас deployment target 16.0, был бы compile error), а
            // старый однопараметрический помечен deprecated и ловится
            // CI-проверкой "любой warning — это провал сборки".
            .photosPicker(
                isPresented: $isPickingFromPhotos,
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
            )

        case .record:
            RecordView(onBack: { stage = .start }) { url in
                stage = .calibrate(videoURL: url)
            }

        case .calibrate(let videoURL):
            CalibrationView(videoURL: videoURL, onBack: { stage = .start }) { p1, p2 in
                stage = .analyzing(videoURL: videoURL, p1: p1, p2: p2)
                runAnalysis(videoURL: videoURL, p1: p1, p2: p2)
            }

        case .analyzing:
            VStack(spacing: 16) {
                ProgressView()
                    .tint(AppTheme.accent)
                    .scaleEffect(1.4)
                Text("Считаю время...")
                    .font(.appHeadline())
                    .foregroundColor(.white)
                Button("Отмена") {
                    analysisTask?.cancel()
                    analysisTask = nil
                    stage = .start
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 200)
                .padding(.top, 8)
            }
            .appBackground()

        case .result(let output, let videoURL, let p1, let p2):
            ResultView(output: output, videoURL: videoURL, p1: p1, p2: p2) {
                stage = .start
            }

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(AppTheme.accent)
                Text("Ошибка: \(message)")
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Button("Заново") { stage = .start }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 200)
            }
            .padding()
            .appBackground()
        }
    }

    private func runAnalysis(videoURL: URL, p1: CGPoint, p2: CGPoint) {
        analysisTask = Task {
            do {
                let output = try await VideoAnalyzer.analyze(videoURL: videoURL, p1: p1, p2: p2)
                guard !Task.isCancelled else { return }
                await MainActor.run { stage = .result(output, videoURL: videoURL, p1: p1, p2: p2) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { stage = .error("\(error)") }
            }
        }
    }

    /// Debug-режим: видео берётся не с камеры, а из Files, чтобы можно было
    /// прогнать VideoAnalyzer на заранее записанных тестовых заездах.
    private func importPickedVideo(_ pickedURL: URL) {
        isImportingMedia = true
        Task {
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }

            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "mov" : pickedURL.pathExtension)
            do {
                try? FileManager.default.removeItem(at: localURL)
                try FileManager.default.copyItem(at: pickedURL, to: localURL)
                await MainActor.run {
                    importError = nil
                    isImportingMedia = false
                    stage = .calibrate(videoURL: localURL)
                }
            } catch {
                await MainActor.run {
                    importError = "Не удалось загрузить файл: \(error.localizedDescription)"
                    isImportingMedia = false
                }
            }
        }
    }

    /// То же самое, но источник — системная галерея (Фото), а не Files.
    /// PhotosPicker отдаёт видео через Transferable, который сам копирует
    /// исходный файл во временную папку приложения — грузить весь ролик
    /// в память как Data не нужно (а на заезде в минуту-две это было бы
    /// соответствующим объёмом оперативной памяти).
    private func importPickedVideo(fromPhotos item: PhotosPickerItem) async {
        await MainActor.run { isImportingMedia = true }
        do {
            guard let video = try await item.loadTransferable(type: TransferableVideo.self) else {
                await MainActor.run {
                    importError = "Не удалось загрузить видео из галереи"
                    isImportingMedia = false
                }
                return
            }
            await MainActor.run {
                importError = nil
                photosPickerItem = nil
                isImportingMedia = false
                stage = .calibrate(videoURL: video.url)
            }
        } catch {
            await MainActor.run {
                importError = "Не удалось загрузить видео из галереи: \(error.localizedDescription)"
                isImportingMedia = false
            }
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
