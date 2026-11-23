import AVFoundation
import ScreenCaptureKit
import AppKit

/// 화면(ScreenCaptureKit) + 카메라·마이크(AVCaptureSession)를 각각 파일로 녹화한다.
/// 화면 파일에는 마이크 소리가 함께 들어가고, 카메라 파일은 영상만 담는다.
/// 모든 파일은 같은 시작 시각(호스트 시계)에서 시작해 같은 시각에 끝나므로 타임라인 0초에 나란히 놓으면 맞는다.
/// 각 파일은 30초 구간으로 나눠 써서(SegmentedWriter) 앱이 강제 종료돼도 마감된 구간까지는 남는다.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

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
        var cameraBackdrop: CameraBackdrop = .off
        var showCameraPreview = false
        var microphone: AVCaptureDevice?
        /// 컴퓨터 소리 (별도 파일)
        var systemAudio = false
        var fps: Int = 30
        var preserveResolution = false
        var screenURL: URL
        var cameraURL: URL
        var audioURL: URL
        var studio: StudioProgram?
        var initialScene: StudioScene?
        var initialCustomLayout: StudioCustomLayout = .standard
    }

    struct Result {
        let screen: URL
        let camera: URL?
        let systemAudio: URL?
        let duration: Double
        let sceneChanges: [StudioSceneChange]
    }

    /// 카메라 미리보기용 (녹화 중 떠 있는 작은 창에 쓴다)
    let session = AVCaptureSession()
    let cameraFeed: CameraFeed
    var onError: ((String) -> Void)?
    /// 카메라·마이크가 끊기거나 다른 앱이 가져갔을 때 (녹화는 계속, 화면에 경고)
    var onDeviceWarning: ((String) -> Void)?
    private var deviceObservers: [NSObjectProtocol] = []

    private let queue = DispatchQueue(label: "easycut.recorder")
    private let options: Options
    private var stream: SCStream?
    private var screenWriter: SegmentedWriter?
    private var hasMicTrack = false
    private var camWriter: SegmentedWriter?
    private var startTime: CMTime?
    private var endTime: CMTime?
    private var sysWriter: SegmentedWriter?
    private var segmentTimer: DispatchSourceTimer?
    private var sysFrames = 0
    private var screenFrames = 0
    private var failed = false
    // 일시정지: 멈춘 동안의 버퍼는 버리고, 멈춘 시간만큼 뒤 버퍼를 앞으로 당긴다
    private var paused = false
    private var pauseStart: CMTime?
    private var pauseOffset = CMTime.zero
    private var sceneChanges: [StudioSceneChange]

    init(options: Options) {
        self.options = options
        cameraFeed = CameraFeed(backdrop: options.cameraBackdrop, preview: options.showCameraPreview)
        sceneChanges = options.initialScene.map {
            [StudioSceneChange(time: 0, scene: $0, customLayout: options.initialCustomLayout)]
        } ?? []
        super.init()
        cameraFeed.onFrame = { [weak self] sample in
            guard let self else { return }
            // Bound in-flight frames; camera inference never blocks screen or audio capture.
            self.queue.sync { self.recordCamera(sample) }
        }
        cameraFeed.onError = { [weak self] error in
            guard let self else { return }
            self.queue.async { self.fail(error) }
        }
    }

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
    }

    /// 레티나 화면은 실제 픽셀로, 너무 크면 긴 변 3840으로 줄인다 (H.264 한계 4096)
    static func captureSize(for display: SCDisplay, target: Target, preserveResolution: Bool = false) -> (Int, Int) {
        let scale = screen(for: display)?.backingScaleFactor ?? 2
        let pts: CGSize
        switch target {
        case .display: pts = preserveResolution ? CGDisplayBounds(display.displayID).size : CGSize(width: display.width, height: display.height)
        case .window(let w): pts = w.frame.size
        case .area(let r): pts = r.size
        }
        var w = Double(pts.width) * scale, h = Double(pts.height) * scale
        let longSide = max(w, h)
        if !preserveResolution, longSide > 3840 { w *= 3840 / longSide; h *= 3840 / longSide }
        // 인코더가 짝수 크기를 원한다
        return (max(2, Int(w / 2) * 2), max(2, Int(h / 2) * 2))
    }

    // MARK: 시작 / 정지

    func start() async throws {
        let (w, h) = Self.captureSize(for: options.display, target: options.target, preserveResolution: options.preserveResolution)

        // 화면 파일 (영상 + 마이크)
        try? FileManager.default.removeItem(at: options.screenURL)
        // movieFragmentInterval(조각 쓰기)은 쓰지 않는다. 실시간 녹화에서 버퍼가 늦거나 불규칙하게 오면
        // AVAssetWriter가 -11800(-16341)으로 실패해 녹화가 중간에 끊긴다 (2026-11-22 실측: 화면 10초, 카메라 5초에서 실패).
        // 대신 SegmentedWriter가 30초마다 파일을 정상 마감하고 정지할 때 잇는다.
        let bitrate = min(40_000_000, max(8_000_000, w * h * options.fps / 10))
        var screenTracks = [SegmentedWriter.Track(mediaType: .video, settings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // B프레임을 끈다: 구간마다 인코더가 다시 시작해도 프레임 순서가 어긋나지 않아 깨끗하게 이어진다
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])]
        if options.microphone != nil {
            screenTracks.append(.init(mediaType: .audio, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ]))
        }
        hasMicTrack = options.microphone != nil

        // 컴퓨터 소리 (별도 m4a)
        if options.systemAudio { try? FileManager.default.removeItem(at: options.audioURL) }
        let sysTracks = [SegmentedWriter.Track(mediaType: .audio, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])]

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
        try queue.sync {
            screenWriter = try SegmentedWriter(finalURL: options.screenURL, fileType: .mp4, tracks: screenTracks, origin: t0)
            if options.systemAudio {
                sysWriter = try SegmentedWriter(finalURL: options.audioURL, fileType: .m4a, tracks: sysTracks, origin: t0)
            }
            startTime = t0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.endTime == nil else { return }
                let now = self.mediaNow()
                for writer in [self.screenWriter, self.camWriter, self.sysWriter] { writer?.tick(now: now) }
            }
            timer.resume()
            segmentTimer = timer
        }
        try await st.startCapture()
        try options.studio?.start()
    }

    func selectScene(_ scene: StudioScene, customLayout: StudioCustomLayout = .standard) {
        queue.sync {
            guard let studio = options.studio, endTime == nil,
                  sceneChanges.last?.matches(scene, customLayout: customLayout) != true else { return }
            let now = pauseStart ?? Self.hostNow
            let time = startTime.map { max(0, (now - $0 - pauseOffset).seconds) } ?? 0
            if sceneChanges.last?.time == time { sceneChanges.removeLast() }
            sceneChanges.append(StudioSceneChange(time: time, scene: scene, customLayout: customLayout))
            studio.setScene(scene, customLayout: customLayout)
        }
    }

    /// 카메라·마이크를 먼저 켠다 (카운트다운 동안 얼굴 미리보기가 보이도록)
    func startDevices() throws {
        guard !session.isRunning, options.camera != nil || options.microphone != nil else { return }
        session.beginConfiguration()
        do {
            if let cam = options.camera { try cameraFeed.addCamera(cam, to: session) }
            try addMicrophone()
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        session.startRunning()
        observeDevices()
    }

    private func addMicrophone() throws {
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
    }

    private func observeDevices() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let warn: (String) -> Void = { [weak self] msg in DispatchQueue.main.async { self?.onDeviceWarning?(msg) } }
        deviceObservers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            if device == self.options.camera { warn("카메라 연결이 끊겼습니다. 다시 연결하거나 녹화를 정지하세요.") }
            if device == self.options.microphone { warn("마이크 연결이 끊겼습니다. 지금부터 목소리가 녹음되지 않습니다.") }
        })
        deviceObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
            warn("다른 앱이 카메라나 마이크를 쓰고 있어 입력이 멈췄습니다.")
        })
        deviceObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            warn("")
        })
        deviceObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            warn("카메라·마이크 오류: " + (err?.localizedDescription ?? ""))
            // 가능하면 장치를 다시 켠다
            self?.queue.async { if let s = self?.session, !s.isRunning { s.startRunning() } }
        })
    }

    private func stopObservingDevices() {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deviceObservers.removeAll()
    }

    /// 지금이 녹화 파일의 몇 초인지 (멈춤 중이거나 녹화 전후면 nil)
    /// 녹화 파일 기준 지금 시각 (일시정지 시간을 뺀 호스트 시각). 녹화 큐에서 부른다.
    private func mediaNow() -> CMTime {
        (paused ? (pauseStart ?? Self.hostNow) : Self.hostNow) - pauseOffset
    }

    func currentMediaTime() -> Double? {
        queue.sync {
            guard let t0 = startTime, !paused, endTime == nil else { return nil }
            return (Self.hostNow - t0 - pauseOffset).seconds
        }
    }

    /// 녹화되는 범위 (전역 좌표, 왼쪽 위 원점, 포인트)
    var captureRect: CGRect {
        let d = CGDisplayBounds(options.display.displayID)
        switch options.target {
        case .display: return d
        case .window(let w): return w.frame
        case .area(let r): return r.offsetBy(dx: d.minX, dy: d.minY)
        }
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
        options.studio?.stop()
        try? await stream?.stopCapture()
        stream = nil
        if session.isRunning { session.stopRunning() }
        stopObservingDevices()

        // 큐에 남은 버퍼를 마저 쓴 뒤 닫는다
        let (sw, cw) = queue.sync { () -> (SegmentedWriter?, SegmentedWriter?) in
            segmentTimer?.cancel()
            segmentTimer = nil
            return (screenWriter, camWriter)
        }
        guard let sw, let t0 = startTime else { throw MediaError.failed("녹화가 시작되지 않았습니다.") }
        guard screenFrames > 0, sw.error == nil else {
            let reason = sw.error.map { " (\($0.localizedDescription))" } ?? ""
            queue.sync { screenFrames > 0 ? sw.cancelOpen() : sw.abandon() }
            // 화면이 실패해도 카메라·컴퓨터 소리는 정상일 수 있으니 지우지 않고 마무리해 둔다
            let (camURL, sysURL) = await finishSideWriters(camera: cw, at: t1)
            throw MediaError.failed("화면이 녹화되지 않았습니다." + reason + Self.savedFilesNote([camURL, sysURL]))
        }
        queue.sync { sw.close(at: t1) }
        let (camURL, sysURL) = await finishSideWriters(camera: cw, at: t1)
        do {
            _ = try await sw.finish()
        } catch {
            throw MediaError.failed("녹화 파일을 저장하지 못했습니다: \(error.localizedDescription)\n"
                                    + L("구간 파일은 남겨 두었습니다. EasyCut을 다시 열면 이어 붙입니다.") + Self.savedFilesNote([camURL, sysURL]))
        }
        return Result(screen: options.screenURL, camera: camURL, systemAudio: sysURL,
                      duration: (t1 - t0).seconds, sceneChanges: sceneChanges)
    }

    /// 카메라·컴퓨터 소리 파일을 마무리한다. 화면 파일이 실패해도 따로 살린다.
    /// 잇지 못하면 구간 파일을 남겨 두고(다음 실행에서 복구) nil을 돌려준다.
    private func finishSideWriters(camera cw: SegmentedWriter?, at t1: CMTime) async -> (URL?, URL?) {
        let sys = queue.sync { () -> SegmentedWriter? in
            cw?.close(at: t1)
            guard let aw = sysWriter else { return nil }
            if sysFrames > 0 { aw.close(at: t1); return aw }
            aw.abandon()   // 소리가 한 번도 오지 않음
            return nil
        }
        let camURL = try? await cw?.finish()
        let sysURL = try? await sys?.finish()
        return (camURL, sysURL)
    }

    static func savedFilesNote(_ urls: [URL?]) -> String {
        let saved = urls.compactMap { $0?.lastPathComponent }
        return saved.isEmpty ? "" : "\n" + L("저장된 파일: \(saved.joined(separator: ", "))")
    }

    /// 시작·저장 실패 시 스트림, 장치와 미완료 writer를 해제한다. 마감된 구간 파일은 보존한다(다음 실행에서 복구).
    func cancel() async {
        queue.sync {
            endTime = Self.hostNow
            segmentTimer?.cancel()
            segmentTimer = nil
        }
        options.studio?.stop()
        try? await stream?.stopCapture()
        stream = nil
        if session.isRunning { session.stopRunning() }
        stopObservingDevices()
        queue.sync {
            for writer in [screenWriter, camWriter, sysWriter] { writer?.cancelOpen() }
        }
    }

    // MARK: 화면 프레임

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let t0 = startTime, endTime == nil, !paused, sb.isValid, sb.presentationTimeStamp >= t0 else { return }
        if type == .audio {
            options.studio?.systemAudio(sb)
            guard let aw = sysWriter, let buf = shifted(sb, clock: nil) else { return }
            if aw.append(buf, track: 0) == .appended { sysFrames += 1 }
            return
        }
        guard type == .screen else { return }
        // 화면이 바뀐 프레임만 (idle·blank 프레임은 건너뜀)
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buf = shifted(sb, clock: nil) else { return }
        options.studio?.screen(buf)
        guard let sw = screenWriter else { return }
        switch sw.append(buf, track: 0) {
        case .appended: screenFrames += 1
        case .dropped: break
        case .failed: fail(sw.error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail(error)
    }

    // MARK: 카메라·마이크

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let t0 = startTime, endTime == nil, !paused, let buf = shifted(sb, clock: session.synchronizationClock),
              buf.presentationTimeStamp >= t0 else { return }
        options.studio?.microphone(buf)
        guard hasMicTrack, let sw = screenWriter else { return }
        if sw.append(buf, track: 1) == .failed { fail(sw.error) }
    }

    private func recordCamera(_ sample: CMSampleBuffer) {
        guard let t0 = startTime, endTime == nil, !paused, let buf = shifted(sample, clock: session.synchronizationClock),
              buf.presentationTimeStamp >= t0 else { return }
        options.studio?.camera(buf)
        if camWriter == nil { makeCameraWriter(from: buf, start: t0) }
        guard let cw = camWriter else { return }
        if cw.append(buf, track: 0) == .failed { fail(cw.error) }
    }

    /// 카메라 해상도는 첫 프레임을 보고 정한다
    private func makeCameraWriter(from sb: CMSampleBuffer, start: CMTime) {
        guard let fd = sb.formatDescription else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        try? FileManager.default.removeItem(at: options.cameraURL)
        camWriter = try? SegmentedWriter(finalURL: options.cameraURL, fileType: .mp4, tracks: [.init(mediaType: .video, settings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width), AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 60,
                                              AVVideoAllowFrameReorderingKey: false],
        ])], origin: start)
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
