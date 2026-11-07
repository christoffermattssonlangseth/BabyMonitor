import AVFoundation
import CoreImage
import ImageIO
import QuartzCore

/// Runs the camera and delivers JPEG frames a few times a second.
/// A crib doesn't move much, so a low frame rate keeps the phone cool.
final class VideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Called on a background queue with each JPEG frame.
    var onFrame: ((Data) -> Void)?
    var framesPerSecond: Double = 8

    /// Encode frames only while someone is watching.
    var wantsFrames: Bool {
        get { lock.withLock { _wantsFrames } }
        set { lock.withLock { _wantsFrames = newValue } }
    }

    private let sessionQueue = DispatchQueue(label: "VideoCapture.session")
    private let frameQueue = DispatchQueue(label: "VideoCapture.frames")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var _wantsFrames = false
    private var lastFrameTime: CFTimeInterval = 0

    /// Selects the camera and starts it if `run` is true. `completion` runs on a background queue.
    func configure(frontCamera: Bool, run: Bool, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            do {
                try self.configureSession(frontCamera: frontCamera)
                if run, !self.session.isRunning { self.session.startRunning() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func setRunning(_ running: Bool) {
        sessionQueue.async {
            if running, !self.session.isRunning, !self.session.inputs.isEmpty {
                self.session.startRunning()
            } else if !running, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession(frontCamera: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // We only capture video here; the microphone is handled by AudioCapture.
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        for input in session.inputs {
            session.removeInput(input)
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: frontCamera ? .front : .back) else {
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)

        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        // Upright image for a phone standing in portrait. Parents can rotate further.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        // Brighter picture in a dark nursery, on cameras that support it.
        if (try? device.lockForConfiguration()) != nil {
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.unlockForConfiguration()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wantsFrames else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1 / framesPerSecond else { return }
        lastFrameTime = now

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5,
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }
        onFrame?(jpeg)
    }
}
