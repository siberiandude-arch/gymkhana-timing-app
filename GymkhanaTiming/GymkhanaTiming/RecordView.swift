import SwiftUI

struct RecordView: View {
    @StateObject private var camera = CameraController()
    let onBack: () -> Void
    let onFinished: (URL) -> Void

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    // Скрыта во время записи — выход посреди заезда потерял бы
                    // отснятое видео, а camera.stopRecording() асинхронно
                    // долетает до onFinished уже после ухода с этого экрана.
                    if !camera.isRecording {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(RoundIconButtonStyle())
                        .padding([.top, .leading])
                    }
                    Spacer()
                }
                Spacer()
                if camera.isRecording {
                    Label("ЗАПИСЬ", systemImage: "circle.fill")
                        .font(.appHeadline(14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                }
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
