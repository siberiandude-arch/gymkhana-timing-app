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

    var body: some View {
        VStack(spacing: 16) {
            if lap.finish == nil {
                Text("Заезд не завершён — финиш не зафиксирован (возврат мимо створа?)")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let exportedURL, let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                HStack(spacing: 12) {
                    Button("Сохранить в Фото") {
                        Task { await saveToPhotos(exportedURL) }
                    }
                    .buttonStyle(.bordered)

                    Button("Поделиться") { isSharing = true }
                        .buttonStyle(.bordered)
                }
                .sheet(isPresented: $isSharing) {
                    ShareSheet(items: [exportedURL])
                }
            } else if isExporting {
                ProgressView("Готовлю видео заезда...")
            }

            if let exportError {
                Text(exportError).foregroundColor(.red).font(.footnote)
            }
            if let saveMessage {
                Text(saveMessage).foregroundColor(.secondary).font(.footnote)
            }
        }
        .padding()
        .navigationTitle("Заезд \(lap.index)")
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
