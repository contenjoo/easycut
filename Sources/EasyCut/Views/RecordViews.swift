import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// 녹화 설정 (화면 · 카메라 · 마이크)
struct RecordSheet: View {
    @AppStorage("spokenEditEnabled") private var spokenEditEnabled = false
    @ObservedObject var rec: RecordController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBroadcast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rec.studioMode {
                Label("1인 방송 스튜디오", systemImage: "dot.radiowaves.left.and.right").font(.title2.bold())
                Text("녹화 중 장면을 누르면 화면이 전환됩니다. 종료하면 장면별로 편집할 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label("화면·얼굴 녹화", systemImage: "record.circle").font(.title2.bold())
                Text("화면과 얼굴(카메라)을 따로 녹화해 끝나면 타임라인에 나란히 넣습니다. 화면은 트랙 1, 얼굴은 트랙 2 오른쪽 아래 작은 화면으로 들어가고, 목소리는 바로 음성 인식됩니다.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if rec.studioMode {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("입력 장치").font(.headline)
                        captureSettings
                    }
                    Divider()
                    ScrollView {
                        StudioSetup(rec: rec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 288)
                }
                .frame(height: 374)
            } else {
                captureSettings
            }

            if rec.studioMode {
                Text("3초 뒤 녹화를 시작합니다. ⌥⌘. 단축키로 종료하고 편집기로 돌아갑니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("시작하면 3초 뒤 녹화됩니다. 녹화 중에는 EasyCut 창이 숨고, 화면 오른쪽 아래 작은 창이나 단축키로 멈춥니다 (작은 창은 녹화에 찍히지 않음).\n⌥⌘P 일시정지·계속 · ⌥⌘. 정지 (다른 앱을 쓰는 중에도 동작)\n녹화 파일: 동영상 › EasyCut 녹화")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    if rec.studioMode && rec.liveEnabled && rec.useYouTubeAccount,
                       let event = rec.youtubeEvent,
                       event.privacy != "private" || event.date.timeIntervalSinceNow > 60 {
                        confirmBroadcast = true
                    } else {
                        Task { await rec.begin() }
                    }
                } label: {
                    if rec.studioMode && rec.liveEnabled {
                        Label("녹화 및 라이브 시작", systemImage: "dot.radiowaves.left.and.right")
                    } else {
                        Label("녹화 시작", systemImage: "record.circle.fill")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(!canStart)
            }
            if rec.studioMode && rec.resolvingLive {
                ProgressView("YouTube 방송 준비 중…").controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: rec.studioMode ? 720 : 460)
        .disabled(rec.resolvingLive)
        .interactiveDismissDisabled(rec.resolvingLive)
        .alert("선택한 YouTube 방송을 지금 시작할까요?", isPresented: $confirmBroadcast) {
            Button("취소", role: .cancel) {}
            Button("녹화 및 라이브 시작") { if canStart { Task { await rec.begin() } } }
        } message: {
            if let event = rec.youtubeEvent {
                Text(verbatim: "\(event.title) · \(event.privacyLabel) · \(event.scheduleLabel)")
            }
        }
        .onChange(of: rec.useCamera) { _, enabled in
            if rec.studioMode && !enabled { rec.selectScene(.screen) }
        }
    }

    private var canStart: Bool {
        guard !rec.resolvingLive else { return false }
        if rec.target == .area && rec.area == nil { return false }
        if rec.target == .window && rec.windows.isEmpty { return false }
        guard rec.studioMode && rec.liveEnabled else { return true }
        if rec.useYouTubeAccount { return rec.youtubeEvent != nil && YouTubeAccount.shared.isConnected }
        return (try? StudioProgram.destination(server: rec.liveServer, key: rec.liveKey)) != nil
    }

    private var captureSettings: some View {
        Form {
            Picker("녹화 범위", selection: Binding(get: { rec.target }, set: { rec.target = $0 })) {
                ForEach(RecordController.TargetKind.allCases) { Text(L($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            if rec.target == .window {
                if rec.windows.isEmpty {
                    Text("녹화할 수 있는 창이 없습니다").foregroundStyle(.secondary)
                } else {
                    Picker("창", selection: $rec.windowID) {
                        ForEach(rec.windows, id: \.windowID) { Text(RecordController.windowLabel($0)).lineLimit(1).tag($0.windowID) }
                    }
                }
                Button("창 목록 새로고침") { Task { await rec.refreshContent() } }
            }
            if rec.target == .area {
                HStack {
                    if let a = rec.area {
                        Text("\(Int(a.width)) × \(Int(a.height)) 영역").monospacedDigit()
                    } else {
                        Text("아직 고르지 않음").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L(rec.area == nil ? "영역 고르기…" : "다시 고르기…")) { Task { await rec.pickArea() } }
                }
            }
            if rec.displays.count > 1 && rec.target != .window {
                Picker("화면", selection: $rec.displayID) {
                    ForEach(rec.displays, id: \.displayID) { d in
                        Text(Self.displayName(d)).tag(d.displayID)
                    }
                }
            }
            Toggle("카메라(얼굴)", isOn: $rec.useCamera)
            if rec.useCamera && !rec.studioMode {
                Toggle("얼굴을 동그랗게", isOn: $rec.cameraCircle)
            }
            if rec.useCamera {
                if rec.cameras.isEmpty {
                    Text("카메라를 찾지 못했습니다").foregroundStyle(.secondary)
                } else {
                    Picker("카메라", selection: $rec.cameraID) {
                        ForEach(rec.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
            }
            if rec.studioMode {
                Toggle("편집본에 마우스 클릭 강조", isOn: $rec.highlightClicks)
            } else {
                Toggle("마우스 클릭 강조", isOn: $rec.highlightClicks)
            }
            Toggle("컴퓨터 소리 (별도 트랙)", isOn: $rec.systemAudio)
            if rec.systemAudio && rec.target == .window {
                Text("창 녹화에서는 그 창을 띄운 앱의 소리만 녹음됩니다").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("말하면서 편집 (녹화 후 지시 검토)", isOn: $spokenEditEnabled)
            if spokenEditEnabled { Text("‘편집아, 여기 확대해줘’처럼 한 문장으로 말하고 잠깐 쉬세요. 음성 인식 후 지시를 검토합니다.").font(.caption) }
            Toggle("마이크(목소리)", isOn: $rec.useMic)
            if rec.useMic {
                Picker("마이크", selection: $rec.micID) {
                    ForEach(rec.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func displayName(_ d: SCDisplay) -> String {
        let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.localizedName
        return "\(name ?? "화면") (\(d.width)×\(d.height))"
    }
}

/// 녹화 중 떠 있는 작은 창: 얼굴 미리보기 + 시간 + 정지
struct RecordPanelView: View {
    @ObservedObject var controller: RecordController

    var body: some View {
        VStack(spacing: 8) {
            if controller.studioMode {
                StudioMonitor(rec: controller)
            } else if controller.useCamera, let rec = controller.recorder {
                CameraPreview(session: rec.session)
                    .frame(width: 150, height: 150)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            }
            HStack(spacing: 10) {
                switch controller.phase {
                case .countdown(let n):
                    Text("\(n)").font(.title.bold().monospacedDigit()).foregroundStyle(.white)
                    Text("곧 녹화 시작").foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button("취소") { controller.cancelCountdown() }
                case .recording, .paused:
                    let paused = controller.phase == .paused
                    Circle().fill(paused ? .orange : .red).frame(width: 10, height: 10)
                    Text(L(paused ? "일시정지" : String(TimeFormat.clock(controller.elapsed).prefix(8))))
                        .font(.body.monospacedDigit()).foregroundStyle(.white)
                    Spacer()
                    if !(controller.studioMode && controller.liveEnabled) {
                        Button { controller.togglePause() } label: {
                            Image(systemName: paused ? "record.circle" : "pause.fill")
                        }
                        .help(L(paused ? "계속 녹화 (⌥⌘P)" : "일시정지 (⌥⌘P)"))
                    }
                    Button {
                        Task { await controller.stop() }
                    } label: { Label("정지", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .help("정지 (⌥⌘.)")
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("시작 중…").foregroundStyle(.white)
                    Spacer()
                case .saving:
                    ProgressView().controlSize(.small)
                    Text("저장 중…").foregroundStyle(.white)
                    Spacer()
                case .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.black.opacity(0.78), in: Capsule())
        }
        .padding(8)
    }
}

/// 카메라 미리보기 (AVCaptureVideoPreviewLayer)
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer()
        v.layer?.addSublayer(layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
