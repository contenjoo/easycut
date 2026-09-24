import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// 화면·카메라 녹화 흐름: 설정 → 3초 카운트다운 → 녹화(EasyCut 창 숨김, 작은 정지 창) → 타임라인에 배치 + 음성 인식
@MainActor
final class RecordController: ObservableObject {
    enum Phase: Equatable { case idle, countdown(Int), recording, paused, saving }
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
    @AppStorage("recTarget") var targetRaw = TargetKind.display.rawValue
    @AppStorage("recArea") private var areaRaw = ""
    @Published var windows: [SCWindow] = []
    @Published var windowID: CGWindowID = 0

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
    private var hiddenWindow: NSWindow?
    private var excludeApp: SCRunningApplication?
    weak var store: EditorStore?

    init(store: EditorStore) { self.store = store }

    static var folder: URL {
        let d = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("EasyCut 녹화", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    var isBusy: Bool { phase != .idle }

    /// 녹화 설정 창을 열기 전에 장치 목록과 화면 녹화 권한을 확인한다
    func open() {
        guard !isBusy else { return }
        cameras = CaptureDevices.cameras
        microphones = CaptureDevices.microphones
        if !cameras.contains(where: { $0.uniqueID == cameraID }) { cameraID = cameras.first?.uniqueID ?? "" }
        if !microphones.contains(where: { $0.uniqueID == micID }) { micID = (AVCaptureDevice.default(for: .audio) ?? microphones.first)?.uniqueID ?? "" }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let a = NSAlert()
            a.messageText = "화면 녹화 권한이 필요합니다"
            a.informativeText = "시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 EasyCut을 켠 뒤, EasyCut을 다시 시작해 주세요."
            a.addButton(withTitle: "시스템 설정 열기")
            a.addButton(withTitle: "닫기")
            if a.runModal() == .alertFirstButtonReturn { CaptureDevices.openPrivacySettings("Privacy_ScreenCapture") }
            return
        }
        Task {
            await refreshContent()
            store?.showRecordSheet = true
        }
    }

    func refreshContent() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        displays = content.displays
        excludeApp = content.applications.first { $0.processID == getpid() }
        if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? CGMainDisplayID() }
        windows = content.windows.filter { w in
            w.windowLayer == 0 && w.frame.width >= 160 && w.frame.height >= 120
                && w.owningApplication?.processID != getpid() && !(w.title ?? "").isEmpty
        }
        .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
        if !windows.contains(where: { $0.windowID == windowID }) { windowID = windows.first?.windowID ?? 0 }
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
        store.showRecordSheet = false
        if useCamera, !(await CaptureDevices.requestAccess(.video)) {
            permissionAlert("카메라", pane: "Privacy_Camera"); return
        }
        if useMic, !(await CaptureDevices.requestAccess(.audio)) {
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
        let stamp = Self.stampFormatter.string(from: Date())
        let opts = ScreenRecorder.Options(
            display: display, target: recTarget, excludeApp: excludeApp,
            camera: useCamera ? cameras.first { $0.uniqueID == cameraID } : nil,
            microphone: useMic ? microphones.first { $0.uniqueID == micID } : nil,
            systemAudio: systemAudio,
            screenURL: Self.folder.appendingPathComponent("녹화 \(stamp) 화면.mp4"),
            cameraURL: Self.folder.appendingPathComponent("녹화 \(stamp) 카메라.mp4"),
            audioURL: Self.folder.appendingPathComponent("녹화 \(stamp) 컴퓨터 소리.m4a"))
        let rec = ScreenRecorder(options: opts)
        rec.onError = { [weak self] (msg: String) in
            Task { @MainActor in
                guard let self, self.phase == .recording || self.phase == .paused else { return }
                self.store?.alert = "녹화 중 문제가 생겼습니다: \(msg)"
                await self.stop()
            }
        }
        recorder = rec

        do { try rec.startDevices() } catch {
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
        do {
            try await rec.start()
            phase = .recording
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
            hotKeys.register { [weak self] action in
                guard let self else { return }
                switch action {
                case .stop: Task { await self.stop() }
                case .pause: self.togglePause()
                }
            }
        } catch {
            finishUI()
            store.alert = "녹화를 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        if let r = recorder, r.session.isRunning { r.session.stopRunning() }
        recorder = nil
        finishUI()
    }

    func togglePause() {
        guard let rec = recorder else { return }
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
        guard phase == .recording || phase == .paused, let rec = recorder else { return }
        hotKeys.unregister()
        phase = .saving
        timer?.invalidate(); timer = nil
        do {
            let r = try await rec.stop()
            finishUI()
            await store?.importRecording(screen: r.screen, camera: r.camera, systemAudio: r.systemAudio)
        } catch {
            finishUI()
            store?.alert = error.localizedDescription
        }
        recorder = nil
    }

    private func finishUI() {
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
        if a.runModal() == .alertFirstButtonReturn { CaptureDevices.openPrivacySettings(pane) }
    }

    /// 녹화 중 화면 아래쪽에 떠 있는 작은 창 (녹화에는 찍히지 않음)
    private func showPanel(on display: SCDisplay) {
        let hasCam = useCamera
        let size = NSSize(width: 290, height: hasCam ? 250 : 84)
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
    func importRecording(screen: URL, camera: URL?, systemAudio: URL? = nil) async {
        do {
            let sa = try await MediaProbe.probe(screen)
            var ca: MediaAsset?
            if let camera { ca = try? await MediaProbe.probe(camera) }
            var aa: MediaAsset?
            if let systemAudio { aa = try? await MediaProbe.probe(systemAudio) }
            let wasEmpty = project.duration == 0
            apply { p in
                p.assets.append(sa)
                if let ca { p.assets.append(ca) }
                if let aa { p.assets.append(aa) }
                if wasEmpty, sa.width > 0 { p.canvasWidth = sa.width; p.canvasHeight = sa.height }
                let t = wasEmpty ? 0 : max(p.trackEnd(0), p.trackEnd(1), p.trackEnd(2))
                p.insert(asset: sa, track: 0, at: t)
                // 컴퓨터 소리는 트랙 3
                if let aa { p.insert(asset: aa, track: 2, at: t) }
                if let ca, ca.width > 0 {
                    let id = p.insert(asset: ca, track: 1, at: t)
                    if let loc = p.locate(clip: id) {
                        let W = p.canvasWidth, H = p.canvasHeight
                        let base = min(W / ca.width, H / ca.height)
                        let widthFrac = 0.24
                        let scale = widthFrac * W / (ca.width * base)
                        let heightFrac = ca.height * base * scale / H
                        p.tracks[loc.track].clips[loc.index].scale = scale
                        p.tracks[loc.track].clips[loc.index].offsetX = 0.5 - widthFrac / 2 - 0.02
                        p.tracks[loc.track].clips[loc.index].offsetY = 0.5 - heightFrac / 2 - 0.03
                        p.tracks[loc.track].clips[loc.index].volume = 0
                    }
                }
            }
            media.prepare(sa)
            if let ca { media.prepare(ca) }
            if let aa { media.prepare(aa) }
            showToast(ca == nil ? "녹화를 타임라인에 넣었습니다" : "녹화를 넣었습니다 (화면 → 트랙 1, 얼굴 → 트랙 2)")
            if sa.hasAudio { transcribe(sa.id) }
        } catch {
            alert = "녹화 파일을 가져오지 못했습니다: \(error.localizedDescription)\n파일 위치: \(screen.deletingLastPathComponent().path)"
        }
    }
}
