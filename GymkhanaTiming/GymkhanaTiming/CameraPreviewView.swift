import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.applyLandscapeOrientation()

        // Коннекшн превью-слоя появляется только после того, как сессия
        // реально привязала вход/выход и запустилась (это происходит
        // асинхронно в CameraController на фоновой очереди) — без этого
        // наблюдателя ориентация иногда не успевает выставиться к моменту
        // makeUIView, и превью показывается в портретной ориентации,
        // втиснутой в альбомный контейнер (ровно то, что писали при
        // ручном тестировании на устройстве).
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: session,
            queue: .main
        ) { [weak view] _ in
            view?.applyLandscapeOrientation()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.applyLandscapeOrientation()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Та же ориентация, что принудительно выставлена для записи в
        /// CameraController — превью и фактическая запись должны совпадать,
        /// иначе картинка на экране и то, что реально пишется в файл,
        /// расходятся.
        func applyLandscapeOrientation() {
            guard let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported else { return }
            connection.videoOrientation = .landscapeRight
        }
    }
}
