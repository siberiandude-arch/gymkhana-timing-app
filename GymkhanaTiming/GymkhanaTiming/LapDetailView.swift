import SwiftUI
import AVKit

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
        VStack(spacing: 16) {
            if lap.finish == nil {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 36))
                    .foregroundColor(AppTheme.textSecondary)
                Text("Заезд не завершён — финиш не зафиксирован (возврат мимо створа?)")
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let exportedURL, let player {
                if let duration = lap.duration {
                    Text(String(format: "%.3f с", duration))
                        .font(.appTimer(36))
                        .foregroundColor(AppTheme.accent)
                }
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

                HStack(spacing: 12) {
                    Button("Сохранить в Фото") {
                        Task { await saveToPhotos(exportedURL) }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Поделиться") { isSharing = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .sheet(isPresented: $isSharing) {
                    ShareSheet(items: [exportedURL])
                }
            } else if isExporting {
                ProgressView("Готовлю видео заезда...")
                    .tint(AppTheme.accent)
                    .foregroundColor(.white)
            }

            if let exportError {
                Text(exportError).foregroundColor(.red).font(.footnote)
            }
            if let saveMessage {
                Text(saveMessage).foregroundColor(AppTheme.textSecondary).font(.footnote)
            }
        }
        .padding()
        .navigationTitle("Заезд \(lap.index)")
        .appBackground()
        .task { await exportIfNeeded() }
    }

    private func exportIfNeeded() async {
        guard lap.finish != nil, exportedURL == nil, !isExporting else { return }
        isExporting = true
        do {
            let url = try await VideoExporter.exportLap(videoURL: videoURL, lap: lap, p1: p1, p2: p2)
            await MainActor.run {
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
