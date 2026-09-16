import AVFoundation
import Combine

/// Управляет захватом видео. Съемка всегда в горизонтальной ориентации
/// (телефон на стойке лежит на боку) — это совпадает с допущением
/// исходного алгоритма (кадр 1920x1080, альбомная ориентация) и избавляет
/// от необходимости разворачивать пиксели при последующем анализе.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    @Published var isRecording = false
    @Published var recordedURL: URL?
    @Published var errorMessage: String?

    override init() {
        super.init()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.sessionQueue.async { self.configureSession() }
            } else {
                DispatchQueue.main.async { self.errorMessage = "Нет доступа к камере" }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            finishConfiguration(error: "Камера не найдена")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            finishConfiguration(error: "Не удалось открыть камеру: \(error.localizedDescription)")
            return
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        finishConfiguration(error: nil)
    }

    private func finishConfiguration(error: String?) {
        session.commitConfiguration()
        if let error {
            DispatchQueue.main.async { self.errorMessage = error }
            return
        }
        session.startRunning()
    }

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        DispatchQueue.main.async { self.isRecording = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                     didFinishRecordingTo outputFileURL: URL,
                     from connections: [AVCaptureConnection],
                     error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            if let error {
                self.errorMessage = error.localizedDescription
            } else {
                self.recordedURL = outputFileURL
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                     willFinishRecordingTo fileURL: URL,
                     from connections: [AVCaptureConnection],
                     error: Error?) {
    }
}
