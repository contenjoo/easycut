import AVFoundation
import ScreenCaptureKit
import AppKit

/// 화면(ScreenCaptureKit) + 카메라·마이크(AVCaptureSession)를 각각 파일로 녹화한다.
/// 화면 파일에는 마이크 소리가 함께 들어가고, 카메라 파일은 영상만 담는다.
/// 모든 파일은 같은 시작 시각(호스트 시계)에서 시작해 같은 시각에 끝나므로 타임라인 0초에 나란히 놓으면 맞는다.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// 녹화 범위
    enum Target {
        case display
        case window(SCWindow)
        /// 화면 안의 영역 (포인트, 화면 왼쪽 위 기준)
        case area(CGRect)
    }

    struct Options {
        var display: SCDisplay
        var target: Target = .display
        var excludeApp: SCRunningApplication?
        var camera: AVCaptureDevice?
        var microphone: AVCaptureDevice?
        /// 컴퓨터 소리 (별도 파일)
        var systemAudio = false
        var fps: Int = 30
        var screenURL: URL
        var cameraURL: URL
        var audioURL: URL
    }

    struct Result {
        let screen: URL
        let camera: URL?
        let systemAudio: URL?
        let duration: Double
    }

    /// 카메라 미리보기용 (녹화 중 떠 있는 작은 창에 쓴다)
    let session = AVCaptureSession()
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "easycut.recorder")
    private let options: Options
    private var stream: SCStream?
    private var screenWriter: AVAssetWriter?
    private var screenVideo: AVAssetWriterInput?
    private var screenAudio: AVAssetWriterInput?
    private var camWriter: AVAssetWriter?
    private var camVideo: AVAssetWriterInput?
    private var startTime: CMTime?
    private var endTime: CMTime?
    private var sysWriter: AVAssetWriter?
    private var sysAudio: AVAssetWriterInput?
    private var sysFrames = 0
    private var screenFrames = 0
    private var failed = false
    // 일시정지: 멈춘 동안의 버퍼는 버리고, 멈춘 시간만큼 뒤 버퍼를 앞으로 당긴다
    private var paused = false
    private var pauseStart: CMTime?
    private var pauseOffset = CMTime.zero

    init(options: Options) {
        self.options = options
        super.init()
    }

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
    }

    /// 레티나 화면은 실제 픽셀로, 너무 크면 긴 변 3840으로 줄인다 (H.264 한계 4096)
    static func captureSize(for display: SCDisplay, target: Target) -> (Int, Int) {
        let scale = screen(for: display)?.backingScaleFactor ?? 2
        let pts: CGSize
        switch target {
        case .display: pts = CGSize(width: display.width, height: display.height)
        case .window(let w): pts = w.frame.size
        case .area(let r): pts = r.size
        }
        var w = Double(pts.width) * scale, h = Double(pts.height) * scale
        let longSide = max(w, h)
        if longSide > 3840 { w *= 3840 / longSide; h *= 3840 / longSide }
        // 인코더가 짝수 크기를 원한다
        return (max(2, Int(w / 2) * 2), max(2, Int(h / 2) * 2))
    }

    // MARK: 시작 / 정지

    func start() async throws {
        let (w, h) = Self.captureSize(for: options.display, target: options.target)

        // 화면 파일 (영상 + 마이크)
        try? FileManager.default.removeItem(at: options.screenURL)
        let sw = try AVAssetWriter(outputURL: options.screenURL, fileType: .mp4)
        let bitrate = min(40_000_000, max(8_000_000, w * h * options.fps / 10))
        let sv = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        sv.expectsMediaDataInRealTime = true
        sw.add(sv)
        if options.microphone != nil {
            let sa = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ])
            sa.expectsMediaDataInRealTime = true
            sw.add(sa)
            screenAudio = sa
        }
        screenWriter = sw
        screenVideo = sv

        // 컴퓨터 소리 (별도 m4a)
        if options.systemAudio {
            try? FileManager.default.removeItem(at: options.audioURL)
            let aw = try AVAssetWriter(outputURL: options.audioURL, fileType: .m4a)
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            ai.expectsMediaDataInRealTime = true
            aw.add(ai)
            sysWriter = aw
            sysAudio = ai
        }

        if !session.isRunning { try startDevices() }

        // 화면: EasyCut 창(녹화 중 떠 있는 작은 창 포함)은 녹화에서 뺀다
        let filter: SCContentFilter
        let cfg = SCStreamConfiguration()
        switch options.target {
        case .window(let win):
            filter = SCContentFilter(desktopIndependentWindow: win)
        case .display, .area:
            filter = SCContentFilter(display: options.display,
                                     excludingApplications: options.excludeApp.map { [$0] } ?? [],
                                     exceptingWindows: [])
        }
        if case .area(let r) = options.target { cfg.sourceRect = r }
        cfg.width = w
        cfg.height = h
        if options.systemAudio {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
        }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.colorSpaceName = CGColorSpace.sRGB
        let st = SCStream(filter: filter, configuration: cfg, delegate: self)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try st.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        stream = st

        // 모든 파일의 0초 = 지금
        let t0 = Self.hostNow
        queue.sync {
            startTime = t0
            sw.startWriting()
            sw.startSession(atSourceTime: t0)
            sysWriter?.startWriting()
            sysWriter?.startSession(atSourceTime: t0)
        }
        try await st.startCapture()
    }


    /// 카메라·마이크를 먼저 켠다 (카운트다운 동안 얼굴 미리보기가 보이도록)
    func startDevices() throws {
        guard !session.isRunning, options.camera != nil || options.microphone != nil else { return }
        session.beginConfiguration()
        if let cam = options.camera {
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            let input = try AVCaptureDeviceInput(device: cam)
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
        }
        if let mic = options.microphone {
            let input = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func pause() {
        queue.async {
            guard !self.paused, self.startTime != nil else { return }
            self.paused = true
            self.pauseStart = Self.hostNow
        }
    }

    func resume() {
        queue.async {
            guard self.paused, let ps = self.pauseStart else { return }
            self.pauseOffset = self.pauseOffset + (Self.hostNow - ps)
            self.paused = false
            self.pauseStart = nil
        }
    }

    func stop() async throws -> Result {
        let now = Self.hostNow
        // 멈춘 상태에서 끝내면 멈춘 순간이 끝
        let t1 = queue.sync { () -> CMTime in
            let raw = paused ? (pauseStart ?? now) : now
            endTime = raw - pauseOffset
            return raw - pauseOffset
        }
        try? await stream?.stopCapture()
        stream = nil
        if session.isRunning { session.stopRunning() }

        // 큐에 남은 버퍼를 마저 쓴 뒤 닫는다
        let (sw, cw) = queue.sync { (screenWriter, camWriter) }
        guard let sw, let t0 = startTime else { throw MediaError.failed("녹화가 시작되지 않았습니다.") }
        guard screenFrames > 0, sw.status == .writing else {
            sw.cancelWriting()
            cw?.cancelWriting()
            throw MediaError.failed("화면이 녹화되지 않았습니다." + (sw.error.map { " (\($0.localizedDescription))" } ?? ""))
        }
        queue.sync {
            screenVideo?.markAsFinished()
            screenAudio?.markAsFinished()
            sw.endSession(atSourceTime: t1)
            if let cw, cw.status == .writing {
                camVideo?.markAsFinished()
                cw.endSession(atSourceTime: t1)
            }
            if let aw = sysWriter, aw.status == .writing, sysFrames > 0 {
                sysAudio?.markAsFinished()
                aw.endSession(atSourceTime: t1)
            }
        }
        await sw.finishWriting()
        var camURL: URL?
        if let cw, cw.status == .writing {
            await cw.finishWriting()
            if cw.status == .completed { camURL = options.cameraURL }
        }
        var sysURL: URL?
        if let aw = sysWriter {
            if aw.status == .writing, sysFrames > 0 {
                await aw.finishWriting()
                if aw.status == .completed { sysURL = options.audioURL }
            } else {
                aw.cancelWriting()
            }
        }
        guard sw.status == .completed else { throw MediaError.failed("녹화 파일을 저장하지 못했습니다: \(sw.error?.localizedDescription ?? "")") }
        return Result(screen: options.screenURL, camera: camURL, systemAudio: sysURL, duration: (t1 - t0).seconds)
    }

    // MARK: 화면 프레임

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let t0 = startTime, endTime == nil, !paused, sb.isValid, sb.presentationTimeStamp >= t0 else { return }
        if type == .audio {
            guard let a = sysAudio, a.isReadyForMoreMediaData, sysWriter?.status == .writing,
                  let buf = shifted(sb, clock: nil) else { return }
            if a.append(buf) { sysFrames += 1 }
            return
        }
        guard type == .screen, let input = screenVideo, input.isReadyForMoreMediaData else { return }
        // 화면이 바뀐 프레임만 (idle·blank 프레임은 건너뜀)
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buf = shifted(sb, clock: nil) else { return }
        if input.append(buf) { screenFrames += 1 } else { fail(screenWriter?.error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail(error)
    }

    // MARK: 카메라·마이크

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let t0 = startTime, endTime == nil, !paused, let buf = shifted(sb, clock: session.synchronizationClock),
              buf.presentationTimeStamp >= t0 else { return }
        if output is AVCaptureAudioDataOutput {
            guard let a = screenAudio, a.isReadyForMoreMediaData, screenWriter?.status == .writing else { return }
            if !a.append(buf) { fail(screenWriter?.error) }
        } else {
            if camWriter == nil { makeCameraWriter(from: buf, start: t0) }
            guard let v = camVideo, v.isReadyForMoreMediaData, camWriter?.status == .writing else { return }
            v.append(buf)
        }
    }

    /// 카메라 해상도는 첫 프레임을 보고 정한다
    private func makeCameraWriter(from sb: CMSampleBuffer, start: CMTime) {
        guard let fd = sb.formatDescription else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        try? FileManager.default.removeItem(at: options.cameraURL)
        guard let w = try? AVAssetWriter(outputURL: options.cameraURL, fileType: .mp4) else { return }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width), AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 60],
        ])
        v.expectsMediaDataInRealTime = true
        w.add(v)
        w.startWriting()
        w.startSession(atSourceTime: start)
        camWriter = w
        camVideo = v
    }

    /// 버퍼 시간을 호스트 시계로 맞추고(카메라·마이크), 일시정지한 시간만큼 앞으로 당긴다
    private func shifted(_ sb: CMSampleBuffer, clock: CMClock?) -> CMSampleBuffer? {
        var delta = CMTime.zero
        if let clock {
            let pts = sb.presentationTimeStamp
            let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
            if abs((host - pts).seconds) >= 0.0005 { delta = host - pts }
        }
        delta = delta - pauseOffset
        if delta == .zero { return sb }
        guard let timings = try? sb.sampleTimingInfos() else { return nil }
        var moved = timings.map { t -> CMSampleTimingInfo in
            var t = t
            if t.presentationTimeStamp.isValid { t.presentationTimeStamp = t.presentationTimeStamp + delta }
            if t.decodeTimeStamp.isValid { t.decodeTimeStamp = t.decodeTimeStamp + delta }
            return t
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: moved.count,
                                              sampleTimingArray: &moved, sampleBufferOut: &out)
        return out
    }

    private func fail(_ error: Error?) {
        guard !failed else { return }
        failed = true
        let msg = error?.localizedDescription ?? "알 수 없는 오류"
        DispatchQueue.main.async { self.onError?(msg) }
    }
}

// MARK: 장치·권한

enum CaptureDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    static func requestAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    static func openPrivacySettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
}
