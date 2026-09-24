import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// 녹화 설정 (화면 · 카메라 · 마이크)
struct RecordSheet: View {
    @ObservedObject var rec: RecordController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("화면·얼굴 녹화", systemImage: "record.circle").font(.title2.bold())
            Text("화면과 얼굴(카메라)을 따로 녹화해 끝나면 타임라인에 나란히 넣습니다. 화면은 트랙 1, 얼굴은 트랙 2 오른쪽 아래 작은 화면으로 들어가고, 목소리는 바로 음성 인식됩니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form {
                if rec.displays.count > 1 {
                    Picker("화면", selection: $rec.displayID) {
                        ForEach(rec.displays, id: \.displayID) { d in
                            Text(Self.displayName(d)).tag(d.displayID)
                        }
                    }
                }
                Toggle("카메라(얼굴)", isOn: $rec.useCamera)
                if rec.useCamera {
                    if rec.cameras.isEmpty {
                        Text("카메라를 찾지 못했습니다").foregroundStyle(.secondary)
                    } else {
                        Picker("카메라", selection: $rec.cameraID) {
                            ForEach(rec.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                    }
                }
                Toggle("마이크(목소리)", isOn: $rec.useMic)
                if rec.useMic {
                    Picker("마이크", selection: $rec.micID) {
                        ForEach(rec.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
            }
            .formStyle(.grouped)

            Text("시작하면 3초 뒤 녹화됩니다. 녹화 중에는 EasyCut 창이 숨고, 화면 오른쪽 아래 작은 창의 [정지]로 끝냅니다. 작은 창은 녹화에 찍히지 않습니다.\n녹화 파일: 동영상 › EasyCut 녹화")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await rec.begin() }
                } label: { Label("녹화 시작", systemImage: "record.circle.fill") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(22)
        .frame(width: 460)
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
            if controller.useCamera, let rec = controller.recorder {
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
                case .recording:
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(TimeFormat.clock(controller.elapsed).prefix(8)).font(.body.monospacedDigit()).foregroundStyle(.white)
                    Spacer()
                    Button {
                        Task { await controller.stop() }
                    } label: { Label("정지", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
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
