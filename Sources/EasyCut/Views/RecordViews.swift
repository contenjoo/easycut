import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// 녹화 설정 (화면 · 카메라 · 마이크)
struct RecordSheet: View {
    @AppStorage("spokenEditEnabled") private var spokenEditEnabled = false
    @ObservedObject var rec: RecordController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBroadcast = false

    @ObservedObject private var youtube = YouTubeLiveService.shared
    @ObservedObject private var account = YouTubeAccount.shared
    @State private var destinationTab = false
    @State private var showSchedule = false
    @State private var editingOptions = false
    // A sheet is allowed to grow past its parent window, but must fit its display.
    @State private var studioSize = Self.availableStudioSize()

    private static func availableStudioSize() -> CGSize {
        let frame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1000, height: 750)
        return CGSize(width: min(890, max(320, frame.width - 48)),
                      height: min(470, max(220, frame.height - 242)))
    }

    var body: some View {
        Group {
            if rec.studioMode { studioSheet } else { standardSheet }
        }
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
            if rec.studioMode && !enabled && rec.studioScene != .custom { rec.selectScene(.screen) }
        }
    }

    private var standardSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("화면·얼굴 녹화", systemImage: "record.circle").font(.title2.bold())
            Text("화면과 얼굴(카메라)을 따로 녹화해 끝나면 타임라인에 나란히 넣습니다. 화면은 트랙 1, 얼굴은 트랙 2 오른쪽 아래 작은 화면으로 들어가고, 목소리는 바로 음성 인식됩니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            captureSettings
            Text("시작하면 3초 뒤 녹화됩니다. 녹화 중에는 EasyCut 창이 숨고, 화면 오른쪽 아래 작은 창이나 단축키로 멈춥니다 (작은 창은 녹화에 찍히지 않음).\n⌥⌘P 일시정지·계속 · ⌥⌘. 정지 (다른 앱을 쓰는 중에도 동작)\n녹화 파일: 동영상 › EasyCut 녹화")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); actionButtons }
        }
        .padding(22).frame(width: 460)
    }

    private var studioSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "EasyCut").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("1인 방송 스튜디오").font(.system(size: 22, weight: .semibold))
                }
                Spacer(minLength: 4)
                Button {
                    showSchedule = true
                } label: {
                    if studioSize.width >= 710 {
                        Label("방송 일정", systemImage: "calendar")
                    } else {
                        Image(systemName: "calendar")
                    }
                }
                .accessibilityLabel(Text("방송 일정"))
                .accessibilityIdentifier("studio-schedule")
                .help("방송 일정")
                Button {
                    destinationTab = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: rec.liveEnabled ? "dot.radiowaves.left.and.right" : "record.circle")
                        Text(verbatim: destinationLabel).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.caption2)
                    }.padding(.horizontal, 3)
                }
                .controlSize(.regular)
                .accessibilityLabel(Text("송출 설정"))
                .accessibilityValue(Text(verbatim: destinationLabel))
                .help("송출 설정")
            }
            .padding(.horizontal, 20).padding(.vertical, 13)
            Divider()
            if studioSize.width >= 710 {
                HStack(spacing: 0) {
                    StudioCompositionDesk(rec: rec)
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    studioInspector.frame(width: min(342, studioSize.width * 0.39))
                }
                .frame(height: studioSize.height)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        StudioCompositionDesk(rec: rec).padding(16)
                        Divider()
                        studioInspector.frame(height: 330)
                    }
                }.frame(height: studioSize.height)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { studioReadiness; Spacer(minLength: 8); actionButtons }
                VStack(alignment: .leading, spacing: 8) { studioReadiness; HStack { Spacer(); actionButtons } }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: studioSize.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSchedule) { YouTubeBroadcastManager(rec: rec) }
    }

    private var destinationLabel: String {
        if !rec.liveEnabled { return L("로컬 녹화") }
        if !rec.useYouTubeAccount { return L("스트림 키") }
        return (account.isConnected ? youtube.channelTitle : nil) ?? L("YouTube 계정")
    }

    private var studioInspector: some View {
        VStack(spacing: 0) {
            Picker("스튜디오 설정", selection: $destinationTab) {
                Label("입력 장치", systemImage: "slider.horizontal.3").tag(false)
                Label("송출 설정", systemImage: "antenna.radiowaves.left.and.right").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("studio-inspector-tabs")
            .padding(.horizontal, 14).padding(.vertical, 12)
            if destinationTab {
                ScrollView {
                    StudioDestinationSetup(rec: rec)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                }
            } else {
                captureSettings.scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var studioReadiness: some View {
        if rec.resolvingLive {
            ProgressView("YouTube 방송 준비 중…").controlSize(.small)
        } else {
            Label {
                Text(verbatim: readinessText)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: canStart ? "timer" : "info.circle")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("studio-start-hint")
        }
    }

    private var readinessText: String {
        if rec.target == .area && rec.area == nil { return L("입력 장치에서 녹화할 영역을 고르세요.") }
        if rec.target == .window && rec.windows.isEmpty { return L("녹화할 수 있는 창이 없습니다") }
        if rec.liveEnabled && !canStart {
            return L(rec.useYouTubeAccount ? "송출 설정에서 계정과 방송을 선택하세요." : "송출 설정에서 서버 주소와 스트림 키를 확인하세요.")
        }
        return L("3초 뒤 시작 · ⌥⌘. 녹화 종료")
    }

    @ViewBuilder private var actionButtons: some View {
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
        .buttonStyle(.borderedProminent).tint(Color(nsColor: Theme.playhead))
        .disabled(!canStart)
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
            if rec.studioMode {
                Section("영상 입력") {
                    sourceFields
                    cameraFields
                }
                Section("오디오 입력") {
                    systemAudioFields
                    microphoneFields
                }
                DisclosureGroup("녹화 후 편집 옵션", isExpanded: $editingOptions) {
                    clickFields
                    spokenFields
                    Button {
                        NSWorkspace.shared.open(RecordController.folder)
                    } label: {
                        Label("녹화 폴더 열기", systemImage: "folder")
                    }
                }
            } else {
                sourceFields
                cameraFields
                clickFields
                systemAudioFields
                spokenFields
                microphoneFields
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var sourceFields: some View {
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
    }

    @ViewBuilder private var cameraFields: some View {
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
    }

    @ViewBuilder private var clickFields: some View {
        if rec.studioMode {
            Toggle("편집본에 마우스 클릭 강조", isOn: $rec.highlightClicks)
        } else {
            Toggle("마우스 클릭 강조", isOn: $rec.highlightClicks)
        }
    }

    @ViewBuilder private var systemAudioFields: some View {
        Toggle("컴퓨터 소리 (별도 트랙)", isOn: $rec.systemAudio)
        if rec.systemAudio && rec.target == .window {
            Text("창 녹화에서는 그 창을 띄운 앱의 소리만 녹음됩니다").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var spokenFields: some View {
        Toggle("말하면서 편집 (녹화 후 지시 검토)", isOn: $spokenEditEnabled)
        if spokenEditEnabled { Text("‘편집아, 여기 확대해줘’처럼 한 문장으로 말하고 잠깐 쉬세요. 음성 인식 후 지시를 검토합니다.").font(.caption) }
    }

    @ViewBuilder private var microphoneFields: some View {
        Toggle("마이크(목소리)", isOn: $rec.useMic)
        if rec.useMic {
            Picker("마이크", selection: $rec.micID) {
                ForEach(rec.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
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
