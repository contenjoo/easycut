import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// MCP 원본 캡처. 편집 프로젝트·UI 녹화 설정을 변경하지 않는다.
@MainActor
final class AutomationRecording {
    unowned let owner: RecordController
    private(set) var state = "idle"
    private var sessionID: String?
    private var recorder: ScreenRecorder?
    private var result: [String: Any]?
    private var failure: String?
    private var monitor: Any?
    private var marks: [ClickMark] = []
    private var clicksURL: URL?
    private var expectsCamera = false
    private var expectsAudio = false
    private var indicator: NSPanel?
    private var finalElapsed = 0.0
    private var requestedFPS = 30
    private var startedAt: Date?
    var isBusy: Bool { ["starting", "recording", "saving"].contains(state) }
    init(owner: RecordController) { self.owner = owner }

    private func reject(_ text: String) -> MediaError { .failed(text) }
    private func number(_ input: [String: Any], _ key: String) throws -> Double {
        guard let n = input[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
            throw reject("invalid_argument: \(key)는 유한한 숫자여야 합니다.")
        }
        return n.doubleValue
    }
    private func id(_ input: [String: Any], _ key: String) throws -> UInt32 {
        let n = try number(input, key)
        guard n > 0, n <= Double(UInt32.max), n.rounded() == n else { throw reject("invalid_argument: \(key)") }
        return UInt32(n)
    }
    private func flag(_ input: [String: Any], _ key: String) throws -> Bool {
        guard let value = input[key] else { return false }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw reject("invalid_argument: \(key)는 boolean이어야 합니다.") }
        return n.boolValue
    }
    private func content() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch { throw reject("screen_capture_unavailable: 화면 녹화 권한·로그인 세션을 확인하세요. \(error.localizedDescription)") }
    }
    private func windows(_ c: SCShareableContent) -> [SCWindow] {
        c.windows.filter { $0.windowLayer == 0 && $0.owningApplication?.processID != getpid() && $0.frame.width >= 160 && $0.frame.height >= 120 && !($0.title ?? "").isEmpty }
    }
    private func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
    private func snapshot() -> [String: Any] {
        var out: [String: Any] = ["state": state, "elapsed_seconds": recorder?.currentMediaTime() ?? finalElapsed]
        if let sessionID { out["session_id"] = sessionID }
        if let startedAt { out["started_at"] = ISO8601DateFormatter().string(from: startedAt) }
        if let result { out["result"] = result }
        if let failure { out["error"] = failure }
        return out
    }

    func call(_ name: String, _ input: [String: Any]) async throws -> [String: Any] {
        if name == "list_recording_targets" {
            let c = try await content()
            return ["displays": c.displays.map { ["id": $0.displayID, "bounds": rect(CGDisplayBounds($0.displayID)), "scale": ScreenRecorder.screen(for: $0)?.backingScaleFactor ?? 1] as [String: Any] },
                    "windows": windows(c).map { ["id": $0.windowID, "title": $0.title ?? "", "app": $0.owningApplication?.applicationName ?? "", "bounds": rect($0.frame)] as [String: Any] },
                    "cameras": CaptureDevices.cameras.map { ["id": $0.uniqueID, "name": $0.localizedName] },
                    "microphones": CaptureDevices.microphones.map { ["id": $0.uniqueID, "name": $0.localizedName] }]
        }
        if name == "get_recording_status" || name == "stop_recording" {
            if name == "stop_recording", input["session_id"] as? String == nil { throw reject("invalid_argument: session_id 필수") }
            if let supplied = input["session_id"] as? String, supplied != sessionID { throw reject("unknown_session: 세션 ID가 일치하지 않습니다.") }
            if name == "stop_recording" {
                guard state != "starting", state != "saving" else { throw reject("busy: \(state). 상태 조회 후 다시 호출하세요.") }
                if state == "recording" { await stop() }
            }
            return snapshot()
        }
        guard name == "start_recording" else { throw reject("unknown_tool") }
        guard !isBusy, owner.phase == .idle else { throw reject("already_recording: 녹화 또는 저장이 진행 중입니다.") }
        // 첫 await 전에 잠가 중복 시작과 UI 녹화를 차단한다.
        let previousState = state
        state = "starting"
        defer { if state == "starting" { state = previousState } }
        let camera = try flag(input, "camera"), mic = try flag(input, "microphone")
        let audio = try flag(input, "system_audio"), clicks = try flag(input, "highlight_clicks")
        let fps = input["fps"] == nil ? 30 : try number(input, "fps")
        guard [24.0, 30.0, 60.0].contains(fps) else { throw reject("invalid_argument: fps는 24, 30, 60") }
        let c = try await content()
        let display: SCDisplay
        let target: ScreenRecorder.Target
        switch input["target"] as? String {
        case "window":
            let wid = try id(input, "window_id")
            guard let w = windows(c).first(where: { $0.windowID == wid }),
                  let d = c.displays.max(by: { CGDisplayBounds($0.displayID).intersection(w.frame).area < CGDisplayBounds($1.displayID).intersection(w.frame).area }),
                  CGDisplayBounds(d.displayID).intersects(w.frame) else { throw reject("invalid_target: 창이 사라졌거나 화면 밖입니다. 목록을 다시 조회하세요.") }
            display = d; target = .window(w)
        case "display", "area":
            let did = try id(input, "display_id")
            guard let d = c.displays.first(where: { $0.displayID == did }) else { throw reject("invalid_target: 화면 ID를 찾을 수 없습니다.") }
            display = d
            if input["target"] as? String == "area" {
                let r = try CGRect(x: number(input, "x"), y: number(input, "y"), width: number(input, "width"), height: number(input, "height"))
                guard r.width >= 2, r.height >= 2, r.minX >= 0, r.minY >= 0,
                      r.maxX <= CGDisplayBounds(d.displayID).width, r.maxY <= CGDisplayBounds(d.displayID).height else { throw reject("invalid_target: 영역이 화면 범위를 벗어납니다.") }
                target = .area(r)
            } else { target = .display }
        default: throw reject("invalid_argument: target은 window, display, area")
        }
        func device(_ enabled: Bool, _ key: String, _ devices: [AVCaptureDevice], _ type: AVMediaType) async throws -> AVCaptureDevice? {
            guard enabled else { return nil }
            if let value = input[key], !(value is String) { throw reject("invalid_device: \(key)는 문자열이어야 합니다.") }
            guard let selected = input[key] as? String == nil ? devices.first : devices.first(where: { $0.uniqueID == input[key] as? String }) else { throw reject("invalid_device: \(key)") }
            guard await CaptureDevices.requestAccess(type) else { throw reject("permission_denied: \(key)") }
            return selected
        }
        let cam = try await device(camera, "camera_id", CaptureDevices.cameras, .video)
        let microphone = try await device(mic, "microphone_id", CaptureDevices.microphones, .audio)
        let size = ScreenRecorder.captureSize(for: display, target: target, preserveResolution: true)
        guard max(size.0, size.1) <= 4096 else { throw reject("unsupported_resolution: 원본 해상도가 H.264 한계를 넘습니다. 작은 영역을 선택하세요.") }
        let sid = UUID().uuidString
        let folder = RecordController.folder.appendingPathComponent(sid, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        sessionID = sid; result = nil; failure = nil; startedAt = nil; marks = []; clicksURL = nil; finalElapsed = 0; requestedFPS = Int(fps)
        let rec = ScreenRecorder(options: .init(display: display, target: target,
            excludeApp: c.applications.first { $0.processID == getpid() }, camera: cam, microphone: microphone,
            systemAudio: audio, fps: Int(fps), preserveResolution: true,
            screenURL: folder.appendingPathComponent("screen.mp4"), cameraURL: folder.appendingPathComponent("camera.mp4"), audioURL: folder.appendingPathComponent("system-audio.m4a")))
        recorder = rec
        expectsCamera = camera; expectsAudio = audio
        rec.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.sessionID == sid, self.state == "starting" || self.state == "recording" else { return }
                self.failure = message
                if self.state == "recording" { await self.stop() }
            }
        }
        do {
            try await rec.start()
            if let failure { throw reject(failure) }
            startedAt = Date(); state = "recording"
            showIndicator()
            if clicks {
                clicksURL = folder.appendingPathComponent("clicks.json")
                let bounds = rec.captureRect
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak rec] _ in
                    let p = NSEvent.mouseLocation
                    let point = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
                    guard bounds.contains(point), let time = rec?.currentMediaTime() else { return }
                    let mark = ClickMark(t: time, x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
                    Task { @MainActor in self?.marks.append(mark) }
                }
            }
            return snapshot().merging(["requested_fps": fps, "width": size.0, "height": size.1, "speed": 1.0]) { _, new in new }
        } catch {
            failure = error.localizedDescription
            await rec.cancel()
            recorder = nil; state = "failed"
            throw reject("capture_start_failed: \(error.localizedDescription)")
        }
    }

    private func showIndicator() {
        let panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 240, height: 90), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "EasyCut MCP 녹화"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VStack {
            Text("원본 영상 녹화 중").font(.headline)
            Button("정지하고 저장") { [weak self] in Task { await self?.stop() } }
        }.padding())
        panel.orderFrontRegardless()
        indicator = panel
    }

    func stop() async {
        guard state == "recording", let rec = recorder else { return }
        state = "saving"
        indicator?.orderOut(nil); indicator = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        do {
            let r = try await rec.stop()
            finalElapsed = r.duration
            guard !expectsCamera || r.camera != nil else { throw reject("camera_output_missing: 카메라 파일을 저장하지 못했습니다.") }
            guard !expectsAudio || r.systemAudio != nil else { throw reject("system_audio_output_missing: 컴퓨터 소리 프레임이 없습니다.") }
            var files: [[String: Any]] = []
            for (kind, url) in [("screen", Optional(r.screen)), ("camera", r.camera), ("system_audio", r.systemAudio)] {
                guard let url else { continue }
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw reject("invalid_output: \(kind)") }
                var file: [String: Any] = ["kind": kind, "path": url.path, "duration_seconds": duration]
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
                    file["width"] = size.width; file["height"] = size.height; file["fps"] = fps
                }
                files.append(file)
            }
            if let clicksURL { try JSONEncoder().encode(marks).write(to: clicksURL, options: .withoutOverwriting) }
            var output: [String: Any] = ["files": files, "speed": 1.0, "requested_fps": requestedFPS]
            if let clicksURL { output["clicks_path"] = clicksURL.path }
            result = output
            // 앱 종료 후에도 파일 옆에서 결과 조회 가능. 비밀값은 기록하지 않는다.
            try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: r.screen.deletingLastPathComponent().appendingPathComponent("result.json"), options: .withoutOverwriting)
            state = failure == nil ? "completed" : "failed"
        } catch { await rec.cancel(); failure = "save_failed: \(error.localizedDescription)"; state = "failed" }
        recorder = nil
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
