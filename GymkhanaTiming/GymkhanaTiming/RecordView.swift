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
                // Классическая "кнопка-затвор": белое кольцо снаружи, внутри —
                // красный кружок в режиме ожидания и красный квадрат во время
                // записи (как в системной Камере) — предыдущий вариант (просто
                // залитый белый круг) не читался как кнопка записи вообще.
                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 30, height: 30)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            camera.onRecordingFinished = onFinished
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
