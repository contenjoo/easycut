import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// 화면·카메라 녹화 흐름: 설정 → 3초 카운트다운 → 녹화(EasyCut 창 숨김, 작은 정지 창) → 타임라인에 배치 + 음성 인식
@MainActor
final class RecordController: ObservableObject {
    enum Phase: Equatable { case idle, countdown(Int), starting, recording, paused, saving }
    enum TargetKind: String, CaseIterable, Identifiable {
        case display = "전체 화면", window = "창", area = "영역"
        var id: String { rawValue }
    }

    @Published var phase: Phase = .idle
    @Published var elapsed: Double = 0
    @Published var displays: [SCDisplay] = []
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    @AppStorage("recUseCamera") var useCamera = true
    @AppStorage("recUseMic") var useMic = true
    @AppStorage("recCameraID") var cameraID = ""
    @AppStorage("recMicID") var micID = ""
    @AppStorage("recSystemAudio") var systemAudio = false
    @AppStorage("recClicks") var highlightClicks = true
    @AppStorage("recCamCircle") var cameraCircle = true
    @AppStorage("recTarget") var targetRaw = TargetKind.display.rawValue
    @AppStorage("recArea") private var areaRaw = ""
    @Published var windows: [SCWindow] = []
    @Published var windowID: CGWindowID = 0 {
        didSet {
            // 다시 열어도 같은 창을 찾을 수 있게 앱과 창 제목을 기억한다
            guard windowID != oldValue, let w = windows.first(where: { $0.windowID == windowID }) else { return }
            windowApp = w.owningApplication?.bundleIdentifier ?? ""
            windowTitle = w.title ?? ""
        }
    }
    @AppStorage("recWindowApp") private var windowApp = ""
    @AppStorage("recWindowTitle") private var windowTitle = ""
    @Published private(set) var studioMode = false
    @Published private(set) var studioScene: StudioScene = .pictureInPicture
    @Published private(set) var studioCustomLayout = StudioCustomLayout.standard
    private static let customLayoutKey = "EasyCut.studio.customLayout"
    private static let prefersCustomKey = "EasyCut.studio.prefersCustomLayout"
    private(set) var studioInsetScene: StudioScene = .pictureInPicture
    @Published private(set) var studioPreview: CGImage?
    @Published var liveEnabled = false
    @Published var liveServer = ""
    @Published var liveKey = ""
    @Published private(set) var liveStatus = ""
    @Published var useYouTubeAccount = true
    @Published var youtubeEvent: YouTubeEvent?
    @Published private(set) var resolvingLive = false
    @Published private(set) var youtubeStatus = ""
    /// 녹화 중 카메라·마이크 문제 (비어 있으면 정상)
    @Published private(set) var deviceWarning = ""
    private var activeYouTubeEvent: YouTubeEvent?
    private var youtubeMonitor: Task<Void, Never>?
    private var studioSessionID: UUID?
    private var preparing = false
    private var startFailure: String?

    func selectScene(_ scene: StudioScene) {
        guard studioMode else { return }
        let hasCamera = useCamera && cameras.contains(where: { $0.uniqueID == cameraID })
        let resolved: StudioScene = scene == .custom || hasCamera ? scene : .screen
        if resolved.isPictureInPicture { studioInsetScene = resolved }
        studioScene = resolved
        let useCustom = resolved == .custom
        if UserDefaults.standard.bool(forKey: Self.prefersCustomKey) != useCustom {
            UserDefaults.standard.set(useCustom, forKey: Self.prefersCustomKey)
        }
        recorder?.selectScene(resolved, customLayout: studioCustomLayout)
    }

    func applyCustomLayout(_ layout: StudioCustomLayout) {
        guard studioMode else { return }
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.customLayoutKey)
        }
        studioCustomLayout = layout
        selectScene(.custom)
    }

    var target: TargetKind {
        get { TargetKind(rawValue: targetRaw) ?? .display }
        set { targetRaw = newValue.rawValue; objectWillChange.send() }
    }
    /// 마지막으로 고른 녹화 영역 (화면 기준 포인트)
    var area: CGRect? {
        get {
            let v = areaRaw.split(separator: ",").compactMap { Double($0) }
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }
        set {
            areaRaw = newValue.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? ""
            objectWillChange.send()
        }
    }

    private(set) var recorder: ScreenRecorder?
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()
    private var pausedTotal: TimeInterval = 0
    private var pauseBegan: Date?
    private var borderWindow: NSWindow?
    private let hotKeys = RecordHotKeys()
    private var clickMonitor: Any?
    private var clicks: [ClickMark] = []
    private var hiddenWindow: NSWindow?
    private var excludeApp: SCRunningApplication?
    weak var store: EditorStore?

    init(store: EditorStore) { self.store = store }

    static var folder: URL {
        let d = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("EasyCut 녹화", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    lazy var automation = AutomationRecording(owner: self)
    var isBusy: Bool { preparing || phase != .idle || automation.isBusy }

    /// 녹화 설정 창을 열기 전에 장치 목록과 화면 녹화 권한을 확인한다
    func open(studio: Bool = false) {
        guard !isBusy else { return }
        studioMode = studio
        studioInsetScene = .pictureInPicture
        liveEnabled = false
        youtubeStatus = ""
        liveKey = ""
        liveStatus = ""
        cameras = CaptureDevices.cameras
        microphones = CaptureDevices.microphones
        if !cameras.contains(where: { $0.uniqueID == cameraID }) { cameraID = cameras.first?.uniqueID ?? "" }
        if studio {
            let defaults = UserDefaults.standard
            studioCustomLayout = defaults.data(forKey: Self.customLayoutKey)
                .flatMap { try? JSONDecoder().decode(StudioCustomLayout.self, from: $0) } ?? .standard
            let initial: StudioScene = useCamera && !cameraID.isEmpty ? .pictureInPicture : .screen
            selectScene(defaults.bool(forKey: Self.prefersCustomKey) ? .custom : initial)
        }
        if !microphones.contains(where: { $0.uniqueID == micID }) { micID = (AVCaptureDevice.default(for: .audio) ?? microphones.first)?.uniqueID ?? "" }
        Task {
            // ScreenCaptureKit is authoritative; CoreGraphics preflight can stay false
            // after the user has granted a rebuilt app screen + system audio access.
            guard await refreshContent() else {
                let a = NSAlert()
                a.messageText = "화면 녹화 권한이 필요합니다"
                a.informativeText = "시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 EasyCut을 켠 뒤, EasyCut을 다시 시작해 주세요."
                a.addButton(withTitle: "시스템 설정 열기")
                a.addButton(withTitle: "닫기")
                if a.localized().runModal() == .alertFirstButtonReturn { CaptureDevices.openPrivacySettings("Privacy_ScreenCapture") }
                return
            }
            store?.showRecordSheet = true
        }
    }

    @discardableResult
    func refreshContent() async -> Bool {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch {
            if AppPaths.isNaturalEditTest {
                try? String(describing: error).write(to: AppPaths.support.appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8)
            }
            return false
        }
        displays = content.displays
        excludeApp = content.applications.first { $0.processID == getpid() }
        if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? CGMainDisplayID() }
        windows = content.windows.filter { w in
            w.windowLayer == 0 && w.frame.width >= 160 && w.frame.height >= 120
                && w.owningApplication?.processID != getpid() && !(w.title ?? "").isEmpty
        }
        .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
        if !windows.contains(where: { $0.windowID == windowID }) {
            // 기억한 앱·제목의 창을 찾고, 없으면 비워 둔다.
            // 목록 첫 창(메신저 등)을 대신 고르면 원치 않는 화면이 녹화·송출될 수 있다.
            let app = windowApp, title = windowTitle
            let sameApp = windows.filter { !app.isEmpty && $0.owningApplication?.bundleIdentifier == app }
            let match = sameApp.first { $0.title == title } ?? (sameApp.count == 1 ? sameApp.first : nil)
            let saved = (windowApp, windowTitle)
            windowID = match?.windowID ?? 0
            if match == nil { (windowApp, windowTitle) = saved }   // 창이 잠시 안 보여도 기억은 유지
        }
        return !displays.isEmpty
    }

    static func windowLabel(_ w: SCWindow) -> String {
        "\(w.owningApplication?.applicationName ?? "앱") — \(w.title ?? "")"
    }

    /// 녹화할 영역을 화면에서 끌어서 고른다 (설정 창은 잠시 숨김)
    func pickArea() async {
        guard let store, let display = displays.first(where: { $0.displayID == displayID }) ?? displays.first,
              let screen = ScreenRecorder.screen(for: display) else { return }
        store.showRecordSheet = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let r = await AreaPicker.pick(on: screen) {
            area = r
            target = .area
        }
        store.showRecordSheet = true
    }

    func begin() async {
        guard let store, !isBusy else { return }
        preparing = true
        defer { preparing = false }
        let accountLive = studioMode && liveEnabled && useYouTubeAccount
        let event = accountLive ? youtubeEvent : nil
        let liveURL: URL?
        if accountLive {
            guard let event, YouTubeAccount.shared.isConnected else {
                store.alert = "YouTube 계정을 연결하고 방송을 선택하세요."
                return
            }
            resolvingLive = true
            defer { resolvingLive = false }
            do {
                liveURL = try await YouTubeLiveService.shared.destination(for: event)
            } catch {
                store.alert = error.localizedDescription
                return
            }
            guard store.showRecordSheet, liveEnabled, useYouTubeAccount, youtubeEvent?.id == event.id else { return }
        } else if studioMode && liveEnabled {
            guard let destination = try? StudioProgram.destination(server: liveServer, key: liveKey) else {
                store.alert = "RTMP 또는 RTMPS 서버 주소와 스트림 키를 확인하세요."
                return
            }
            liveURL = destination
        } else {
            liveURL = nil
        }
        store.showRecordSheet = false
        let camera = useCamera ? cameras.first { $0.uniqueID == cameraID } : nil
        let mic = useMic ? microphones.first { $0.uniqueID == micID } : nil
        if camera != nil, !(await CaptureDevices.requestAccess(.video)) {
            permissionAlert("카메라", pane: "Privacy_Camera"); return
        }
        if mic != nil, !(await CaptureDevices.requestAccess(.audio)) {
            permissionAlert("마이크", pane: "Privacy_Microphone"); return
        }
        guard let display = displays.first(where: { $0.displayID == displayID }) ?? displays.first else {
            store.alert = "녹화할 화면을 찾지 못했습니다."; return
        }
        var recTarget = ScreenRecorder.Target.display
        switch target {
        case .display: break
        case .window:
            guard let w = windows.first(where: { $0.windowID == windowID }) else { store.alert = "녹화할 창을 고르세요."; return }
            recTarget = .window(w)
        case .area:
            guard let a = area else { store.alert = "녹화할 영역을 먼저 고르세요."; return }
            recTarget = .area(a)
        }
        store.player.pause()
        // 같은 초에 시작한 다른 녹화(두 번째 실행본 등)의 파일을 지우지 않도록 겹치면 번호를 붙인다
        var stamp = Self.stampFormatter.string(from: Date())
        let base = stamp
        var n = 2
        while ["화면.mp4", "카메라.mp4", "컴퓨터 소리.m4a"].contains(where: {
            FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent("녹화 \(stamp) \($0)").path)
        }) { stamp = "\(base) (\(n))"; n += 1 }
        let studio: StudioProgram?
        if studioMode {
            selectScene(studioScene)
            let id = UUID()
            studioSessionID = id
            do {
                studio = try StudioProgram(initialScene: studioScene, customLayout: studioCustomLayout, liveURL: liveURL, onPreview: { [weak self] frame in
                    Task { @MainActor in
                        guard self?.studioSessionID == id else { return }
                        self?.studioPreview = frame
                    }
                }, onLiveStatus: { [weak self] status in
                    Task { @MainActor in
                        guard self?.studioSessionID == id else { return }
                        self?.liveStatus = status
                    }
                })
            } catch {
                studioSessionID = nil
                store.alert = error.localizedDescription
                return
            }
        } else {
            studio = nil
        }
        let opts = ScreenRecorder.Options(
            display: display, target: recTarget, excludeApp: excludeApp,
            camera: camera, microphone: mic,
            systemAudio: systemAudio,
            screenURL: Self.folder.appendingPathComponent("녹화 \(stamp) 화면.mp4"),
            cameraURL: Self.folder.appendingPathComponent("녹화 \(stamp) 카메라.mp4"),
            audioURL: Self.folder.appendingPathComponent("녹화 \(stamp) 컴퓨터 소리.m4a"),
            studio: studio, initialScene: studioMode ? studioScene : nil, initialCustomLayout: studioCustomLayout)
        let rec = ScreenRecorder(options: opts)
        rec.onError = { [weak self, weak rec] (msg: String) in
            Task { @MainActor in
                guard let self, let rec, self.recorder === rec else { return }
                if self.phase == .starting { self.startFailure = msg; return }
                guard self.phase == .recording || self.phase == .paused else { return }
                self.store?.alert = "녹화 중 문제가 생겼습니다: \(msg)"
                await self.stop()
            }
        }
        rec.onDeviceWarning = { [weak self, weak rec] msg in
            Task { @MainActor in
                guard let self, let rec, self.recorder === rec else { return }
                self.deviceWarning = msg
            }
        }
        deviceWarning = ""
        recorder = rec
        startFailure = nil

        do { try rec.startDevices() } catch {
            await rec.cancel()
            studioSessionID = nil
            recorder = nil
            store.alert = "카메라·마이크를 켜지 못했습니다: \(error.localizedDescription)"
            return
        }
        // EasyCut 창을 숨기고 정지 창을 띄운 뒤 3초 세기
        // 창을 닫거나 내리면 '마지막 창이 닫힘'으로 앱이 끝나므로, 투명하게만 만들고 클릭은 통과시킨다
        hiddenWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.frame.width > 600 }
        hiddenWindow?.alphaValue = 0
        hiddenWindow?.ignoresMouseEvents = true
        showPanel(on: display)
        if case .area(let a) = recTarget, let screen = ScreenRecorder.screen(for: display) {
            borderWindow = AreaPicker.borderWindow(for: a, on: screen)
            borderWindow?.orderFrontRegardless()
        }
        for n in stride(from: 3, through: 1, by: -1) {
            phase = .countdown(n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if phase == .idle { return } // 카운트다운 중 취소
        }
        phase = .starting
        do {
            try await rec.start()
            if let startFailure { throw MediaError.failed(startFailure) }
            phase = .recording
            if let event {
                activeYouTubeEvent = event
                monitorYouTube(event)
            }
            startedAt = Date()
            pausedTotal = 0
            pauseBegan = nil
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.elapsed = Date().timeIntervalSince(self.startedAt) - self.pausedTotal
                }
            }
            startClickCapture(rec)
            hotKeys.register { [weak self] action in
                guard let self else { return }
                switch action {
                case .stop: Task { await self.stop() }
                case .pause: self.togglePause()
                }
            }
        } catch {
            await rec.cancel()
            recorder = nil
            finishUI()
            store.alert = "녹화를 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func monitorYouTube(_ event: YouTubeEvent) {
        youtubeStatus = "YouTube 방송 시작 대기 중"
        youtubeMonitor?.cancel()
        youtubeMonitor = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(attempts < 5 ? 5 : 20))
                    let status = try await YouTubeLiveService.shared.status(of: event)
                    guard !Task.isCancelled, self?.activeYouTubeEvent?.id == event.id else { return }
                    switch status {
                    case "live":
                        // 방송 중에도 계속 확인한다 (YouTube가 방송을 끝내면 바로 알린다)
                        self?.youtubeStatus = "YouTube 라이브 중"
                    case "complete", "revoked":
                        self?.youtubeStatus = "YouTube 방송 종료됨"
                        return
                    default:
                        self?.youtubeStatus = attempts >= 5 ? "YouTube에서 송출 수신을 기다리고 있습니다" : "YouTube 방송 시작 대기 중"
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.youtubeStatus = "YouTube 방송 상태 확인 지연"
                }
                attempts += 1
            }
        }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        if let r = recorder, r.session.isRunning { r.session.stopRunning() }
        recorder = nil
        finishUI()
    }

    func togglePause() {
        guard let rec = recorder, !(studioMode && liveEnabled) else { return }
        switch phase {
        case .recording:
            rec.pause()
            pauseBegan = Date()
            phase = .paused
        case .paused:
            rec.resume()
            if let b = pauseBegan { pausedTotal += Date().timeIntervalSince(b) }
            pauseBegan = nil
            phase = .recording
        default: break
        }
    }

    func stop() async {
        if automation.isBusy { await automation.stop(); return }
        guard phase == .recording || phase == .paused, let rec = recorder else { return }
        hotKeys.unregister()
        phase = .saving
        timer?.invalidate(); timer = nil
        youtubeMonitor?.cancel()
        youtubeMonitor = nil
        let event = activeYouTubeEvent
        activeYouTubeEvent = nil
        do {
            let r = try await rec.stop()
            await store?.importRecording(screen: r.screen, camera: r.camera, systemAudio: r.systemAudio,
                                         clicks: clicks, showClicks: highlightClicks, cameraCircle: cameraCircle,
                                         sceneChanges: r.sceneChanges)
            if studioMode && useCamera && !cameraID.isEmpty && r.camera == nil {
                store?.alert = "카메라 원본을 저장하지 못해 화면 녹화로 복구했습니다. 녹화 폴더를 확인하세요."
            }
        } catch {
            await rec.cancel()
            store?.alert = error.localizedDescription
        }
        recorder = nil
        if let event {
            // YouTube also ends this event on encoder disconnect if the app exits unexpectedly.
            do {
                try await YouTubeLiveService.shared.complete(event)
            } catch {
                let detail = "YouTube Studio에서 방송 종료 여부를 확인하세요. " + error.localizedDescription
                store?.alert = [store?.alert, detail].compactMap { $0 }.joined(separator: "\n")
            }
            youtubeEvent = nil
        }
        finishUI()
    }

    /// 녹화 범위 안의 마우스 클릭을 녹화 시간과 함께 기록 (나중에 클릭 강조로 표시)
    private func startClickCapture(_ rec: ScreenRecorder) {
        clicks = []
        let rect = rec.captureRect
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak rec] _ in
            let p = NSEvent.mouseLocation
            let g = CGPoint(x: p.x, y: primaryHeight - p.y)
            guard rect.contains(g), let t = rec?.currentMediaTime() else { return }
            let mark = ClickMark(t: t, x: (g.x - rect.minX) / rect.width, y: (g.y - rect.minY) / rect.height)
            Task { @MainActor in self?.clicks.append(mark) }
        }
    }

    private func finishUI() {
        studioSessionID = nil
        studioPreview = nil
        liveKey = ""
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        phase = .idle
        hotKeys.unregister()
        borderWindow?.orderOut(nil)
        borderWindow = nil
        panel?.orderOut(nil)
        panel = nil
        hiddenWindow?.alphaValue = 1
        hiddenWindow?.ignoresMouseEvents = false
        hiddenWindow?.makeKeyAndOrderFront(nil)
        hiddenWindow = nil
        NSApp.activate(ignoringOtherApps: true)
    }

    private func permissionAlert(_ what: String, pane: String) {
        let a = NSAlert()
        a.messageText = "\(what) 권한이 필요합니다"
        a.informativeText = "시스템 설정 › 개인정보 보호 및 보안 › \(what)에서 EasyCut을 켜 주세요. \(what) 없이 녹화하려면 녹화 설정에서 \(what)를 끄세요."
        a.addButton(withTitle: "시스템 설정 열기")
        a.addButton(withTitle: "닫기")
        if a.localized().runModal() == .alertFirstButtonReturn { CaptureDevices.openPrivacySettings(pane) }
    }

    /// 녹화 중 화면 아래쪽에 떠 있는 작은 창 (녹화에는 찍히지 않음)
    private func showPanel(on display: SCDisplay) {
        let hasCam = useCamera
        let size = studioMode ? NSSize(width: 388, height: 350) : NSSize(width: 290, height: hasCam ? 250 : 84)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: RecordPanelView(controller: self))
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

extension EditorStore {
    /// 녹화 파일을 타임라인에: 화면은 트랙 1, 카메라는 트랙 2 오른쪽 아래 작은 화면. 그리고 음성 인식 시작.
    func importRecording(screen: URL, camera: URL?, systemAudio: URL? = nil,
                         clicks: [ClickMark] = [], showClicks: Bool = true, cameraCircle: Bool = true,
                         sceneChanges: [StudioSceneChange] = []) async {
        // 열린 프로젝트가 있으면 새 프로젝트로 열지, 끝에 붙일지 묻는다 (기본: 새 프로젝트)
        if project.duration > 0 || !project.assets.isEmpty {
            let a = NSAlert()
            a.messageText = "녹화를 어디에 넣을까요?"
            a.informativeText = "새 프로젝트로 열면 지금 프로젝트는 그대로 둡니다."
            a.addButton(withTitle: "새 프로젝트로 열기")
            a.addButton(withTitle: "지금 프로젝트 끝에 추가")
            if a.localized().runModal() == .alertFirstButtonReturn {
                newProject()   // 저장하지 않은 변경이 있으면 여기서 묻는다. 취소하면 끝에 추가한다.
            }
        }
        do {
            var sa = try await MediaProbe.probe(screen)
            if !clicks.isEmpty { sa.clicks = clicks }
            var ca: MediaAsset?
            if let camera { ca = try? await MediaProbe.probe(camera) }
            var aa: MediaAsset?
            if let systemAudio { aa = try? await MediaProbe.probe(systemAudio) }
            let wasEmpty = project.duration == 0
            let previousEnd = project.duration
            apply { p in
                p.assets.append(sa)
                if let ca { p.assets.append(ca) }
                if let aa { p.assets.append(aa) }
                if !sceneChanges.isEmpty {
                    p.insertStudioRecording(screen: sa, camera: ca, audio: aa, changes: sceneChanges,
                                            showClicks: !clicks.isEmpty && showClicks)
                    return
                }
                if wasEmpty, sa.width > 0 { p.canvasWidth = sa.width; p.canvasHeight = sa.height }
                let t = wasEmpty ? 0 : max(p.trackEnd(0), p.trackEnd(1), p.trackEnd(2))
                let sid = p.insert(asset: sa, track: 0, at: t)
                if !clicks.isEmpty, showClicks, let loc = p.locate(clip: sid) { p.tracks[loc.track].clips[loc.index].showClicks = true }
                // 컴퓨터 소리는 트랙 3
                if let aa { p.insert(asset: aa, track: 2, at: t) }
                if let ca, ca.width > 0 {
                    let id = p.insert(asset: ca, track: 1, at: t)
                    if let loc = p.locate(clip: id) {
                        let W = p.canvasWidth, H = p.canvasHeight
                        // 원 모양이면 가운데 정사각형으로 잘리므로 그 크기로 배치
                        let cw = cameraCircle ? min(ca.width, ca.height) : ca.width
                        let ch = cameraCircle ? min(ca.width, ca.height) : ca.height
                        let base = min(W / cw, H / ch)
                        let widthFrac = cameraCircle ? 0.17 : 0.24
                        let scale = widthFrac * W / (cw * base)
                        let heightFrac = ch * base * scale / H
                        if cameraCircle { p.tracks[loc.track].clips[loc.index].shape = .circle }
                        p.tracks[loc.track].clips[loc.index].scale = scale
                        p.tracks[loc.track].clips[loc.index].offsetX = 0.5 - widthFrac / 2 - 0.02
                        p.tracks[loc.track].clips[loc.index].offsetY = 0.5 - heightFrac / 2 - 0.03
                        p.tracks[loc.track].clips[loc.index].volume = 0
                    }
                }
            }
            media.prepare(sa)
            if !sceneChanges.isEmpty {
                player.seek(previousEnd)
                if let first = project.tracks.first?.clips.first(where: { $0.assetID == sa.id }) {
                    selection = [first.id]
                }
            }
            if let ca { media.prepare(ca) }
            if let aa { media.prepare(aa) }
            showToast(ca == nil ? "녹화를 타임라인에 넣었습니다" : "녹화를 넣었습니다 (화면 → 트랙 1, 얼굴 → 트랙 2)")
            // 말소리가 없는 녹화(무음·시험음)는 자동 음성 인식을 건너뛴다. 대본 탭에서 직접 실행할 수 있다.
            let target = sa.hasAudio ? sa : (aa?.hasAudio == true ? aa : nil)
            if let target {
                if let check = await SpeechCheck.analyze(target.url), !check.likelySpeech {
                    showToast("말소리가 거의 없어 자동 음성 인식을 건너뛰었습니다")
                } else {
                    transcribe(target.id)
                }
            }
        } catch {
            alert = "녹화 파일을 가져오지 못했습니다: \(error.localizedDescription)\n파일 위치: \(screen.deletingLastPathComponent().path)"
        }
    }
}
