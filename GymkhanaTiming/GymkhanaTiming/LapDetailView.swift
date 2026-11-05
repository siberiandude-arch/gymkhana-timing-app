import SwiftUI
import AVKit

/// Готовые клипы заездов: если вернуться к списку и открыть тот же заезд
/// снова, ролик берётся отсюда, а не собирается заново (это ~минута).
private final class LapExportCache: @unchecked Sendable {
    static let shared = LapExportCache()
    private let lock = NSLock()
    private var urls: [UUID: URL] = [:]

    func url(for id: UUID) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let url = urls[id], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func store(_ url: URL, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        urls[id] = url
    }
}

struct LapDetailView: View {
    let lap: LapAttempt
    let videoURL: URL
    let p1: CGPoint
    let p2: CGPoint

    @State private var exportedURL: URL?
    @State private var player: AVPlayer?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var isSharing = false
    @State private var saveMessage: String?
    @State private var isFullscreen = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width > geo.size.height {
                    HStack(alignment: .top, spacing: 16) {
                        videoArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        sidePanel(showTime: true)
                            .frame(width: min(210, geo.size.width * 0.26))
                    }
                } else {
                    VStack(spacing: 16) {
                        timeLabel
                        videoArea
                        sidePanel(showTime: false)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Заезд \(lap.index)")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
        .task { await exportIfNeeded() }
    }

    private var timeLabel: some View {
        Group {
            if let duration = lap.duration {
                Text(String(format: "%.3f с", duration))
                    .font(.appTimer(32))
                    .foregroundColor(AppTheme.accent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var videoArea: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        isFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(RoundIconButtonStyle())
                    .padding(8)
                }
                .fullScreenCover(isPresented: $isFullscreen) {
                    FullscreenPlayer(player: player) { isFullscreen = false }
                }
        } else if isExporting {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(AppTheme.accent)
                Text("Готовлю видео заезда...")
                    .foregroundColor(.white)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let exportError {
            Text(exportError).foregroundColor(.red).font(.footnote)
        }
    }

    /// Время и кнопки справа от видео (в портрете — под ним).
    private func sidePanel(showTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showTime { timeLabel }
            if let exportedURL {
                Button {
                    Task { await saveToPhotos(exportedURL) }
                } label: {
                    Label("В Фото", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(CompactButtonStyle())

                Button {
                    isSharing = true
                } label: {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CompactButtonStyle())
                .sheet(isPresented: $isSharing) {
                    ShareSheet(items: [exportedURL])
                }
            }
            if let saveMessage {
                Text(saveMessage).foregroundColor(AppTheme.textSecondary).font(.footnote)
            }
            Spacer(minLength: 0)
        }
    }

    private func exportIfNeeded() async {
        guard lap.finish != nil, exportedURL == nil, !isExporting else { return }
        if let cached = LapExportCache.shared.url(for: lap.id) {
            exportedURL = cached
            player = AVPlayer(url: cached)
            return
        }
        isExporting = true
        do {
            let url = try await VideoExporter.exportLap(videoURL: videoURL, lap: lap, p1: p1, p2: p2)
            await MainActor.run {
                LapExportCache.shared.store(url, for: lap.id)
                exportedURL = url
                player = AVPlayer(url: url)
                isExporting = false
            }
        } catch {
            await MainActor.run {
                exportError = "Не удалось подготовить видео: \(error)"
                isExporting = false
            }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        do {
            try await PhotoLibrarySaver.save(videoURL: url)
            await MainActor.run { saveMessage = "Сохранено в Фото" }
        } catch {
            await MainActor.run { saveMessage = "Не удалось сохранить: \(error)" }
        }
    }
}

private struct FullscreenPlayer: View {
    let player: AVPlayer
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(RoundIconButtonStyle())
            .padding(16)
        }
    }
}
