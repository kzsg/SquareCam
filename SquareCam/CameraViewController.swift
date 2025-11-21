import AVFoundation
import Photos
import UIKit
import Vision

final class CameraViewController: UIViewController {
    private let previewView = CameraPreviewView()
    private let captureButton = UIButton(type: .system)
    private let cameraToggleButton = UIButton(type: .system)
    private let faceToggleButton = UIButton(type: .system)
    private let overlayLayer = CAShapeLayer()

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var sessionQueue = DispatchQueue(label: "com.squarecam.camera-session")
    private var isSessionRunning = false
    private var faceDetectionEnabled = true
    private var currentOrientation: AVCaptureVideoOrientation = .portrait
    private let visionSequenceHandler = VNSequenceRequestHandler()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SquareCam"
        view.backgroundColor = .black
        configureButtons()
        configureOverlay()
        layoutUI()
        configureSession()
        NotificationCenter.default.addObserver(self, selector: #selector(handleOrientationChange), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            self?.startSessionIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.isSessionRunning = false
        }
    }

    // MARK: - Setup

    private func configureButtons() {
        captureButton.setTitle("Capture", for: .normal)
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        captureButton.layer.cornerRadius = 8
        captureButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        cameraToggleButton.setTitle("Flip", for: .normal)
        cameraToggleButton.setTitleColor(.white, for: .normal)
        cameraToggleButton.backgroundColor = UIColor.systemGray.withAlphaComponent(0.8)
        cameraToggleButton.layer.cornerRadius = 8
        cameraToggleButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        cameraToggleButton.addTarget(self, action: #selector(toggleCamera), for: .touchUpInside)

        faceToggleButton.setTitle("Faces On", for: .normal)
        faceToggleButton.setTitleColor(.white, for: .normal)
        faceToggleButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        faceToggleButton.layer.cornerRadius = 8
        faceToggleButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        faceToggleButton.addTarget(self, action: #selector(toggleFaceDetection), for: .touchUpInside)
    }

    private func configureOverlay() {
        overlayLayer.strokeColor = UIColor.systemYellow.cgColor
        overlayLayer.fillColor = UIColor.clear.cgColor
        overlayLayer.lineWidth = 2
        overlayLayer.frame = view.bounds
        previewView.layer.addSublayer(overlayLayer)
    }

    private func layoutUI() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        cameraToggleButton.translatesAutoresizingMaskIntoConstraints = false
        faceToggleButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(previewView)
        view.addSubview(captureButton)
        view.addSubview(cameraToggleButton)
        view.addSubview(faceToggleButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),

            captureButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),

            cameraToggleButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            cameraToggleButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),

            faceToggleButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            faceToggleButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor)
        ])
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo

            do {
                let defaultDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video)
                guard let videoDevice = defaultDevice else { throw CameraError.cameraUnavailable }
                let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoDeviceInput) {
                    session.addInput(videoDeviceInput)
                    self.videoDeviceInput = videoDeviceInput
                } else {
                    throw CameraError.cameraUnavailable
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.presentError(error)
                }
                session.commitConfiguration()
                return
            }

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.isHighResolutionCaptureEnabled = true
            }

            if session.canAddOutput(videoOutput) {
                videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.squarecam.video-output"))
                videoOutput.alwaysDiscardsLateVideoFrames = true
                session.addOutput(videoOutput)
                videoOutput.connections.first?.videoOrientation = currentOrientation
            }

            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.previewView.previewLayer.session = self?.session
            }
        }
    }

    // MARK: - Actions

    @objc private func capturePhoto() {
        requestPhotoLibraryAccessIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentError(CameraError.photoLibraryUnauthorized)
                }
                return
            }

            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.isHighResolutionPhotoEnabled = true
            settings.flashMode = .auto
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                if let connection = self.photoOutput.connection(with: .video) {
                    connection.videoOrientation = self.currentOrientation
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    @objc private func toggleCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let currentInput = self.videoDeviceInput else { return }
            let currentPosition = currentInput.device.position
            let preferredPosition: AVCaptureDevice.Position = currentPosition == .front ? .back : .front
            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: preferredPosition) else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentError(CameraError.cameraUnavailable)
                }
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                self.session.beginConfiguration()
                self.session.removeInput(currentInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoDeviceInput = newInput
                } else {
                    self.session.addInput(currentInput)
                }
                self.session.commitConfiguration()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.presentError(error)
                }
            }
        }
    }

    @objc private func toggleFaceDetection() {
        faceDetectionEnabled.toggle()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let title = faceDetectionEnabled ? "Faces On" : "Faces Off"
            let background = faceDetectionEnabled ? UIColor.systemGreen : UIColor.systemGray
            faceToggleButton.setTitle(title, for: .normal)
            faceToggleButton.backgroundColor = background.withAlphaComponent(0.8)
            overlayLayer.isHidden = !faceDetectionEnabled
            if !faceDetectionEnabled {
                overlayLayer.path = nil
            }
        }
    }

    @objc private func handleOrientationChange() {
        guard let connection = previewView.previewLayer.connection else { return }
        if let orientation = UIDevice.current.orientation.videoOrientation {
            currentOrientation = orientation
            connection.videoOrientation = orientation
            videoOutput.connections.forEach { $0.videoOrientation = orientation }
            if let photoConnection = photoOutput.connection(with: .video) {
                photoConnection.videoOrientation = orientation
            }
        }
    }

    // MARK: - Session Control

    private func startSessionIfNeeded() {
        guard !isSessionRunning else { return }
        session.startRunning()
        isSessionRunning = true
    }

    private func requestPhotoLibraryAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        default:
            completion(false)
        }
    }

    private func savePhoto(_ photoData: Data) {
        PHPhotoLibrary.shared().performChanges({
            let options = PHAssetResourceCreationOptions()
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: photoData, options: options)
        }, completionHandler: { [weak self] success, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.presentError(error)
                } else if success {
                    let alert = UIAlertController(title: "Saved", message: "Photo added to your library.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        })
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.presentError(error)
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else { return }
        savePhoto(data)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard faceDetectionEnabled else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let observations = request.results as? [VNFaceObservation] else { return }
            DispatchQueue.main.async {
                self?.drawFaces(observations: observations)
            }
        }

        do {
            try visionSequenceHandler.perform([request], on: pixelBuffer, orientation: currentOrientation.cgImageOrientation)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.presentError(error)
            }
        }
    }

    private func drawFaces(observations: [VNFaceObservation]) {
        guard !observations.isEmpty else {
            overlayLayer.path = nil
            return
        }

        let convertedRects = observations.map { observation -> CGRect in
            let boundingBox = observation.boundingBox
            let size = CGSize(width: boundingBox.width * previewView.bounds.width, height: boundingBox.height * previewView.bounds.height)
            let origin = CGPoint(x: boundingBox.minX * previewView.bounds.width, y: (1 - boundingBox.maxY) * previewView.bounds.height)
            return CGRect(origin: origin, size: size)
        }

        let path = UIBezierPath()
        convertedRects.forEach { path.append(UIBezierPath(rect: $0)) }
        overlayLayer.frame = previewView.bounds
        overlayLayer.path = path.cgPath
    }
}

// MARK: - Helpers

private enum CameraError: LocalizedError {
    case cameraUnavailable
    case photoLibraryUnauthorized

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Unable to access the camera on this device."
        case .photoLibraryUnauthorized:
            return "Photo library access is required to save photos."
        }
    }
}

private extension UIDeviceOrientation {
    var videoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }
}

private extension AVCaptureVideoOrientation {
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        @unknown default: return .right
        }
    }
}
