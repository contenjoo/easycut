import SwiftUI

struct StudioSetup: View {
    @ObservedObject var rec: RecordController
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시작 장면").font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                StudioSceneButtons(rec: rec)
            }
            StudioCornerPicker(rec: rec)
            Divider().padding(.vertical, 2)
            Toggle("실시간 송출", isOn: $rec.liveEnabled)
                .toggleStyle(.switch)
            if rec.liveEnabled {
                Picker("송출 방식", selection: $rec.useYouTubeAccount) {
                    Text("YouTube 계정").tag(true)
                    Text("스트림 키").tag(false)
                }.labelsHidden().pickerStyle(.segmented)
                if rec.useYouTubeAccount {
                    YouTubeStudioSetup(rec: rec)
                } else {
                    manualDestination
                }
            }
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            if !rec.useCamera || rec.cameras.isEmpty { rec.selectScene(.screen) }
        }
    }

    @ViewBuilder private var manualDestination: some View {
        Text("방송 채널에서 받은 서버 주소와 스트림 키를 입력하세요.")
            .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
            Text("서버 주소").font(.caption)
            TextField("rtmps://…", text: $rec.liveServer)
                .accessibilityLabel(Text("서버 주소"))
                .accessibilityIdentifier("studio-live-server")
        }
        VStack(alignment: .leading, spacing: 3) {
            Text("스트림 키").font(.caption)
            SecureField("스트림 키", text: $rec.liveKey)
                .accessibilityIdentifier("studio-live-key")
        }
        if !rec.liveServer.isEmpty && !rec.liveKey.isEmpty,
           (try? StudioProgram.destination(server: rec.liveServer, key: rec.liveKey)) == nil {
            Text("RTMP 또는 RTMPS 서버 주소와 스트림 키를 확인하세요.")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

private extension StudioScene {
    var symbol: String {
        switch self {
        case .screen: return "display"
        case .camera: return "person.crop.rectangle"
        case .pictureInPicture, .pictureInPictureTopLeft, .pictureInPictureTopRight, .pictureInPictureBottomLeft:
            return "pip"
        case .sideBySide: return "rectangle.split.2x1"
        }
    }
}

private struct StudioCornerPicker: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        HStack {
            Text("작은 카메라 위치").font(.caption)
            Spacer()
            Picker("작은 카메라 위치", selection: Binding(
                get: { rec.studioInsetScene },
                set: { rec.selectScene($0) }
            )) {
                Text("왼쪽 위").tag(StudioScene.pictureInPictureTopLeft)
                Text("오른쪽 위").tag(StudioScene.pictureInPictureTopRight)
                Text("왼쪽 아래").tag(StudioScene.pictureInPictureBottomLeft)
                Text("오른쪽 아래").tag(StudioScene.pictureInPicture)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("studio-pip-corner")
        }
        .disabled(!rec.studioScene.isPictureInPicture)
    }
}

private struct StudioSceneButtons: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        ForEach([StudioScene.screen, .camera, .pictureInPicture, .sideBySide], id: \.self) { scene in
            let target = scene == .pictureInPicture ? rec.studioInsetScene : scene
            let selected = target == rec.studioScene
            Button {
                rec.selectScene(target)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: scene.symbol)
                        .font(.system(size: 17, weight: .medium))
                    Text(L(scene.title)).font(.caption)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 43)
                .padding(.horizontal, 2)
                .background(selected ? Color.accentColor.opacity(0.18) : .secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(scene != .screen && (!rec.useCamera || rec.cameras.isEmpty))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("studio-scene-\(scene.rawValue)")
        }
    }
}

/// The panel uses the same composited frames as the stream, including scene changes.
struct StudioMonitor: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                Text("방송 스튜디오").fontWeight(.semibold)
                Spacer(minLength: 4)
                if rec.liveEnabled {
                    Text(L(rec.liveStatus))
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
            .font(.caption)
            if rec.liveEnabled && rec.useYouTubeAccount && !rec.youtubeStatus.isEmpty {
                Text(verbatim: L(rec.youtubeStatus)).font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                Color.black
                if let frame = rec.studioPreview {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("영상 입력 대기 중")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(height: rec.liveEnabled && rec.useYouTubeAccount ? 126 : 150)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(Text("현재 장면 미리보기"))
            VStack(spacing: 6) {
                HStack(spacing: 5) { StudioSceneButtons(rec: rec) }
                StudioCornerPicker(rec: rec)
            }
            .disabled(rec.phase != .recording && rec.phase != .paused)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
