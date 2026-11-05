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
    @State private var importProgress: Double?
    @State private var importError: String?
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showSourceChooser = false
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        switch stage {
        case .start:
            startScreen

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

    // MARK: - Главный экран

    /// Горизонтально: картинка на весь экран, меню справа, как в игре
    /// (справа в картинке специально оставлено свободное место). В
    /// портрете такой кадр не влезает — картинка сверху, меню снизу.
    private var startScreen: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                ZStack(alignment: .trailing) {
                    Image("HomeBanner")
                        .resizable()
                        .scaledToFill()
                        // верх картинки (логотип) не должен обрезаться — при
                        // более вытянутом экране срезаем нижний край
                        .frame(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                               height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom,
                               alignment: .top)
                        .clipped()
                        .overlay(
                            LinearGradient(colors: [.clear, Color.black.opacity(0.5)],
                                           startPoint: .center, endPoint: .trailing)
                        )
                        .ignoresSafeArea()

                    menuPanel
                        .frame(width: min(340, geo.size.width * 0.42))
                        .padding(.trailing, 24)
                }
            } else {
                VStack(spacing: 0) {
                    Image("HomeBanner")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                    Spacer()
                    menuPanel.padding(.horizontal, 24)
                    Spacer()
                }
                .appBackground()
            }
        }
        .background(Color.black.ignoresSafeArea())
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
    }

    private var menuPanel: some View {
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
                if let importProgress {
                    ProgressView(value: importProgress) {
                        Text("Загружаю видео... \(Int(importProgress * 100))%")
                    }
                    .tint(AppTheme.accent)
                    .foregroundColor(AppTheme.textSecondary)
                } else {
                    ProgressView("Загружаю видео...")
                        .tint(AppTheme.accent)
                        .foregroundColor(AppTheme.textSecondary)
                    Text("Если видео хранится в iCloud, сначала оно скачается на телефон — это может занять время")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let importError {
                Text(importError).foregroundColor(.red).font(.footnote)
            }
        }
        .padding(18)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        importProgress = 0
        Task {
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }

            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "mov" : pickedURL.pathExtension)
            try? FileManager.default.removeItem(at: localURL)
            do {
                try copyWithProgress(from: pickedURL, to: localURL) { fraction in
                    Task { @MainActor in importProgress = fraction }
                }
                await MainActor.run {
                    importError = nil
                    isImportingMedia = false
                    importProgress = nil
                    stage = .calibrate(videoURL: localURL)
                }
            } catch {
                await MainActor.run {
                    importError = "Не удалось загрузить файл: \(error.localizedDescription)"
                    isImportingMedia = false
                    importProgress = nil
                }
            }
        }
    }

    /// Копирует файл чанками по 1МБ вместо FileManager.copyItem, чтобы
    /// можно было сообщать реальный процент — пользователь жаловался, что
    /// при загрузке "ничего не происходит" по несколько минут на больших
    /// видео. Для PhotosPicker-варианта (галерея) такого контроля нет —
    /// Transferable не отдаёт прогресс, так что там остаётся спиннер.
    private func copyWithProgress(from source: URL, to destination: URL, onProgress: @escaping (Double) -> Void) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let totalSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard let input = InputStream(url: source) else { throw CocoaError(.fileReadNoSuchFile) }
        guard let output = OutputStream(url: destination, append: false) else { throw CocoaError(.fileWriteUnknown) }
        input.open()
        output.open()
        defer { input.close(); output.close() }

        let bufferSize = 1 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var totalWritten: Int64 = 0
        var lastReportedFraction = -1.0

        while input.hasBytesAvailable {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                input.read(rawBuffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: bufferSize)
            }
            if bytesRead < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
            if bytesRead == 0 { break }

            var offset = 0
            while offset < bytesRead {
                let written = buffer.withUnsafeBytes { rawBuffer -> Int in
                    output.write(rawBuffer.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: bytesRead - offset)
                }
                if written <= 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
                offset += written
            }

            totalWritten += Int64(bytesRead)
            if totalSize > 0 {
                let fraction = min(1, Double(totalWritten) / Double(totalSize))
                if fraction - lastReportedFraction > 0.01 {
                    lastReportedFraction = fraction
                    onProgress(fraction)
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
