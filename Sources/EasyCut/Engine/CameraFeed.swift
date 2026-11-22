import AVFoundation
import Combine
import CoreImage

/// Only one thumbnail can await display at a time if the main thread is busy.
final class CameraPreviewFrames: ObservableObject {
    @Published private(set) var frame: CGImage?
    private let delivery = NSLock()
    private var pending = false
    private var lastTime = -Double.infinity

    func offer(_ sample: CMSampleBuffer, processor: CameraBackdropProcessor) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTime >= 0.095, let pixel = sample.imageBuffer else { return }
        let available = delivery.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
        guard available else { return }
        lastTime = now
        let image = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 400 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let thumbnail = processor.context.createCGImage(small, from: small.extent)
        DispatchQueue.main.async {
            self.frame = thumbnail
            self.delivery.withLock { self.pending = false }
        }
    }
}

final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "easycut.camera.background", qos: .userInitiated)
    private let processor = CameraBackdropProcessor()
    let preview: CameraPreviewFrames?
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    init(backdrop: CameraBackdrop = .off, preview: Bool) {
        self.preview = preview ? CameraPreviewFrames() : nil
        super.init()
        processor.backdrop = backdrop
    }

    func setBackdrop(_ backdrop: CameraBackdrop) {
        queue.async { self.processor.backdrop = backdrop }
    }

    /// Called inside the caller's capture session configuration.
    func addCamera(_ device: AVCaptureDevice, to session: AVCaptureSession) throws {
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraBackdropError.frame }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraBackdropError.frame }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            do {
                let frame = try processor.process(sample)
                onFrame?(frame)
                preview?.offer(frame, processor: processor)
            } catch { onError?(error) }
        }
    }
}
