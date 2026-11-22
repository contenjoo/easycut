import AVFoundation
import CoreImage

/// Source boxes on the 16:9 program canvas, measured from the top left.
struct StudioCustomLayout: Codable, Equatable {
    private static let fullScreen = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let insetCamera = CGRect(x: 0.70, y: 0.70, width: 0.28, height: 0.28)
    static let standard = Self(screen: fullScreen, camera: insetCamera)

    let screen: CGRect
    let camera: CGRect

    init(screen: CGRect, camera: CGRect) {
        self.screen = Self.bounded(screen, fallback: Self.fullScreen)
        self.camera = Self.bounded(camera, fallback: Self.insetCamera)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(screen: try values.decode(CGRect.self, forKey: .screen),
                  camera: try values.decode(CGRect.self, forKey: .camera))
    }

    private static func bounded(_ rect: CGRect, fallback: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return fallback }
        let width = min(1, max(0.05, rect.size.width))
        let height = min(1, max(0.05, rect.size.height))
        return CGRect(x: min(max(0, rect.origin.x), 1 - width),
                      y: min(max(0, rect.origin.y), 1 - height),
                      width: width, height: height)
    }
}

enum StudioScene: String, Codable, CaseIterable {
    case screen, camera, pictureInPicture, sideBySide
    case pictureInPictureTopLeft, pictureInPictureTopRight, pictureInPictureBottomLeft
    case custom

    var isPictureInPicture: Bool {
        switch self {
        case .screen, .camera, .sideBySide, .custom: return false
        case .pictureInPicture, .pictureInPictureTopLeft, .pictureInPictureTopRight, .pictureInPictureBottomLeft: return true
        }
    }

    var title: String {
        switch self {
        case .screen: return "화면만"
        case .camera: return "카메라만"
        case .pictureInPicture: return "화면 속 카메라"
        case .sideBySide: return "나란히"
        case .pictureInPictureTopLeft: return "화면 속 카메라 (왼쪽 위)"
        case .pictureInPictureTopRight: return "화면 속 카메라 (오른쪽 위)"
        case .pictureInPictureBottomLeft: return "화면 속 카메라 (왼쪽 아래)"
        case .custom: return "내 배치"
        }
    }

    /// Actual image bounds, in normalized coordinates with the top left as origin.
    func frames(screenAspect: CGFloat, cameraAspect: CGFloat, customLayout: StudioCustomLayout = .standard)
        -> (screen: CGRect?, camera: CGRect?) {
        let canvas = CGRect(x: 0, y: 0, width: 1, height: 1)
        func fit(_ aspect: CGFloat, _ box: CGRect) -> CGRect {
            let ratio = (aspect > 0 && aspect.isFinite ? aspect : 16 / 9) / (16 / 9)
            let width = min(box.width, box.height * ratio)
            let height = width / ratio
            return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        }
        switch self {
        case .screen: return (fit(screenAspect, canvas), nil)
        case .camera: return (nil, fit(cameraAspect, canvas))
        case .custom: return (fit(screenAspect, customLayout.screen), fit(cameraAspect, customLayout.camera))
        case .sideBySide:
            return (fit(screenAspect, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                    fit(cameraAspect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        case .pictureInPicture, .pictureInPictureTopLeft, .pictureInPictureTopRight, .pictureInPictureBottomLeft:
            var face = fit(cameraAspect, CGRect(x: 0, y: 0, width: 0.28, height: 0.42))
            let left = self == .pictureInPictureTopLeft || self == .pictureInPictureBottomLeft
            let top = self == .pictureInPictureTopLeft || self == .pictureInPictureTopRight
            face.origin = CGPoint(x: left ? 0.02 : 0.98 - face.width, y: top ? 0.02 : 0.98 - face.height)
            return (fit(screenAspect, canvas), face)
        }
    }
}

/// Capture callbacks only replace retained frames. Rendering and encoding use a separate clock,
/// so camera movement and scene changes continue when ScreenCaptureKit marks a screen idle.
final class StudioProgram: @unchecked Sendable {
    static let size = CGSize(width: 1280, height: 720)
    private let queue = DispatchQueue(label: "easycut.studio.program", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let liveURL: URL?
    private let onPreview: (CGImage) -> Void
    private let onLiveStatus: (String) -> Void
    private var scene: StudioScene
    private var customLayout: StudioCustomLayout
    private var screenFrame: CVPixelBuffer?
    private var cameraFrame: CVPixelBuffer?
    private var cameraFrameAt = 0.0
    private var previewPending = false
    private var timer: DispatchSourceTimer?
    private var encoder: StudioBroadcast?
    private var epoch = CMTime.zero
    private var lastPreview = -Double.infinity
    private var audioFrame: Int64 = 0
    /// 송출이 끊기면 이 시각(초)에 다시 연결한다. 간격은 2초부터 두 배씩, 최대 30초.
    private var reconnectAt: Double?
    private var reconnectDelay = 2.0
    private var reconnectAttempts = 0
    private let audio = StudioAudioMix()

    init(initialScene: StudioScene, customLayout: StudioCustomLayout = .standard,
         liveURL: URL?, onPreview: @escaping (CGImage) -> Void,
         onLiveStatus: @escaping (String) -> Void) throws {
        if let liveURL { _ = try StudioEndpoint(liveURL) }
        self.scene = initialScene
        self.customLayout = customLayout
        self.liveURL = liveURL
        self.onPreview = onPreview
        self.onLiveStatus = onLiveStatus
    }

    static func destination(server: String, key: String) throws -> URL {
        try StudioEndpoint.destination(server: server, key: key)
    }

    func start() throws {
        queue.sync {
            guard timer == nil else { return }
            epoch = CMClockGetTime(CMClockGetHostTimeClock())
            audio.begin(at: epoch)
            audioFrame = 0
            lastPreview = -.infinity
            reconnectAt = nil
            reconnectDelay = 2
            reconnectAttempts = 0
            if let liveURL {
                do {
                    encoder = try StudioBroadcast(url: liveURL, onStatus: onLiveStatus)
                } catch {
                    scheduleReconnect(after: 0)
                }
            }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.render() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            reconnectAt = nil
            encoder?.finish()
            encoder = nil
            lock.withLock {
                screenFrame = nil
                cameraFrame = nil
            }
        }
    }

    func setScene(_ scene: StudioScene, customLayout: StudioCustomLayout = .standard) {
        lock.withLock {
            self.scene = scene
            self.customLayout = customLayout
        }
    }
    func screen(_ sample: CMSampleBuffer) { lock.withLock { screenFrame = sample.imageBuffer } }
    func camera(_ sample: CMSampleBuffer) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        lock.withLock { cameraFrame = sample.imageBuffer; cameraFrameAt = now }
    }
    func microphone(_ sample: CMSampleBuffer) { if liveURL != nil { audio.add(sample) } }
    func systemAudio(_ sample: CMSampleBuffer) { if liveURL != nil { audio.add(sample) } }

    /// 송출이 끊겼을 때 로컬 녹화는 그대로 두고, 점점 긴 간격으로 다시 연결한다
    private func scheduleReconnect(after now: Double) {
        let delay = reconnectDelay
        reconnectAt = now + delay
        reconnectDelay = min(30, reconnectDelay * 2)
        let message = "송출이 끊겼습니다. \(Int(delay))초 뒤 다시 연결합니다. 로컬 녹화는 계속됩니다."  // 화면에서 L()로 번역
        DispatchQueue.main.async { self.onLiveStatus(message) }
    }

    private func render() {
        autoreleasepool {
            let pts = CMClockGetTime(CMClockGetHostTimeClock()) - epoch
            if encoder?.hasFailed == true {
                encoder?.finish()
                encoder = nil
                scheduleReconnect(after: pts.seconds)
            } else if encoder?.isConnected == true, reconnectAttempts > 0 {
                reconnectAttempts = 0
                reconnectDelay = 2
            }
            if encoder == nil, let liveURL, let at = reconnectAt, pts.seconds >= at {
                reconnectAt = nil
                reconnectAttempts += 1
                do {
                    encoder = try StudioBroadcast(url: liveURL, origin: pts, onStatus: onLiveStatus)
                } catch {
                    scheduleReconnect(after: pts.seconds)
                }
            }
            let previewDue = pts.seconds - lastPreview >= 0.1 && !lock.withLock { previewPending }
            guard previewDue || encoder != nil else { return }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            // 카메라 프레임이 1.5초 넘게 안 오면(분리·다른 앱 점유) 멈춘 얼굴을 계속 내보내지 않는다
            let (selected, custom, screen, camera) = lock.withLock {
                (scene, customLayout, screenFrame, hostNow - cameraFrameAt > 1.5 ? nil : cameraFrame)
            }
            func aspect(_ frame: CVPixelBuffer?) -> CGFloat {
                guard let frame else { return 16 / 9 }
                return CGFloat(CVPixelBufferGetWidth(frame)) / CGFloat(CVPixelBufferGetHeight(frame))
            }
            let layout = selected.frames(screenAspect: aspect(screen), cameraAspect: aspect(camera), customLayout: custom)
            let bounds = CGRect(origin: .zero, size: Self.size)
            var program = CIImage(color: .black).cropped(to: bounds)
            for (source, rect) in [(screen, layout.screen), (camera, layout.camera)] {
                guard let source, let rect else { continue }
                let src = CIImage(cvPixelBuffer: source)
                let size = CGSize(width: rect.width * bounds.width, height: rect.height * bounds.height)
                let scaled = src.transformed(by: .init(scaleX: size.width / src.extent.width, y: size.height / src.extent.height))
                let position = CGAffineTransform(translationX: rect.minX * bounds.width, y: (1 - rect.maxY) * bounds.height)
                program = scaled.transformed(by: position).composited(over: program)
            }
            if previewDue {
                let small = program.transformed(by: .init(scaleX: 0.4, y: 0.4))
                if let image = context.createCGImage(small, from: small.extent, format: .BGRA8, colorSpace: space) {
                    lastPreview = pts.seconds
                    lock.withLock { previewPending = true }
                    DispatchQueue.main.async {
                        self.onPreview(image)
                        self.lock.withLock { self.previewPending = false }
                    }
                }
            }
            guard let encoder else { return }
            encoder.appendVideo(at: pts) { pixel in
                context.render(program, to: pixel, bounds: bounds, colorSpace: space)
            }
            // Allow microphone and system callbacks to arrive before mixing the same host-clock interval.
            let available = Int64(max(0, pts.seconds - 0.12) * 48_000)
            if available - audioFrame > 48_000 { audioFrame = available - 1024 }
            while audioFrame + 1024 <= available, encoder.canAcceptAudio {
                if let sample = audio.read(from: audioFrame, count: 1024) { encoder.appendAudio(sample) }
                audioFrame += 1024
            }
        }
    }
}
