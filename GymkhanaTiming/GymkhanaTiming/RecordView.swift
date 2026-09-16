import SwiftUI

struct RecordView: View {
    @StateObject private var camera = CameraController()
    let onFinished: (URL) -> Void

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                Spacer()
                if let error = camera.errorMessage {
                    Text(error)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                }
                Button(action: toggleRecording) {
                    Circle()
                        .fill(camera.isRecording ? Color.red : Color.white)
                        .frame(width: 74, height: 74)
                        .overlay(Circle().stroke(Color.white, lineWidth: 4).padding(4))
                }
                .padding(.bottom, 30)
            }
        }
        .onChange(of: camera.recordedURL) { url in
            if let url {
                onFinished(url)
            }
        }
    }

    private func toggleRecording() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.startRecording()
        }
    }
}
