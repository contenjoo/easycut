import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct StudioCompositionDesk: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("배치 미리보기").font(.headline)
                Spacer()
                Text(verbatim: "1280 × 720").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                StudioLayoutEditButton(rec: rec)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Theme.ruler))
                StudioSchematic(scene: rec.studioScene, screenAspect: rec.studioScreenAspect, cameraAspect: rec.studioCameraAspect,
                                guides: true, customLayout: rec.studioCustomLayout, showsCamera: rec.studioCameraAvailable)
                    .equatable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .padding(12)
            }
            .frame(minHeight: 130, idealHeight: 218, maxHeight: .infinity)
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.inspectorBorder) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("배치 미리보기"))
            .accessibilityValue(Text(verbatim: L(rec.studioScene.title)))
            .accessibilityIdentifier("studio-composition-preview")

            HStack(spacing: 12) {
                Text("시작 장면").font(.headline)
                Spacer()
                sourceLabel("화면", color: Color(nsColor: Theme.videoClip))
                sourceLabel("카메라", color: Color(nsColor: Theme.imageClip))
            }
            StudioSceneStrip(rec: rec, screenAspect: rec.studioScreenAspect, cameraAspect: rec.studioCameraAspect)
            if rec.studioCameraAvailable {
                StudioCorners(rec: rec)
            } else {
                Label(L(rec.cameras.isEmpty ? "카메라를 연결하면 카메라 장면을 선택할 수 있습니다." :
                            "입력에서 카메라를 켜면 카메라 장면을 선택할 수 있습니다."), systemImage: "video.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: rec.studioCameraAvailable, initial: true) { _, available in
            if !available && rec.studioScene != .screen && rec.studioScene != .custom { rec.selectScene(.screen) }
        }
    }

    private func sourceLabel(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(verbatim: L(title)).font(.caption).foregroundStyle(.secondary)
        }
    }

}

private extension RecordController {
    var studioCameraAvailable: Bool { useCamera && cameras.contains { $0.uniqueID == cameraID } }

    var studioScreenAspect: CGFloat {
        let size: CGSize?
        switch target {
        case .window: size = windows.first { $0.windowID == windowID }?.frame.size
        case .area: size = area?.size
        case .display:
            size = displays.first { $0.displayID == displayID }.map { CGSize(width: $0.width, height: $0.height) }
        }
        guard let size, size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    var studioCameraAspect: CGFloat {
        guard let camera = cameras.first(where: { $0.uniqueID == cameraID }),
              !camera.supportsSessionPreset(.hd1280x720) else { return 16 / 9 }
        let size = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        guard size.width > 0, size.height > 0 else { return 16 / 9 }
        return CGFloat(size.width) / CGFloat(size.height)
    }
}

private struct StudioLayoutEditButton: View {
    @ObservedObject var rec: RecordController
    var compact = false
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            if compact {
                Image(systemName: "slider.horizontal.below.rectangle")
            } else {
                Label("내 배치 편집", systemImage: "slider.horizontal.below.rectangle")
            }
        }
        .controlSize(.small)
        .accessibilityLabel(Text("내 배치 편집"))
        .accessibilityIdentifier(compact ? "studio-live-layout-edit" : "studio-layout-edit")
        .help("내 배치 편집")
        .sheet(isPresented: $editing) {
            StudioCustomLayoutEditor(rec: rec, screenAspect: rec.studioScreenAspect, cameraAspect: rec.studioCameraAspect)
        }
        .onChange(of: rec.phase) { _, phase in
            if phase == .saving || phase == .idle { editing = false }
        }
    }
}

/// Uses the normalized rectangles of the live compositor for both the diagram and the scene thumbnails.
struct StudioSchematic: View, Equatable {
    let scene: StudioScene
    var screenAspect: CGFloat = 16 / 9
    var cameraAspect: CGFloat = 16 / 9
    var guides = false
    var customLayout: StudioCustomLayout = .standard
    var showsCamera = true

    var body: some View {
        Canvas { context, size in
            let canvas = CGRect(origin: .zero, size: size)
            guard size.width > 0, size.height > 0 else { return }
            context.fill(Path(canvas), with: .color(Color(nsColor: Theme.timelineBG)))
            let layout = scene.frames(screenAspect: screenAspect, cameraAspect: cameraAspect, customLayout: customLayout)
            let transform = CGAffineTransform(scaleX: size.width, y: size.height)
            if let rect = layout.screen { drawScreen(in: rect.applying(transform), context: context) }
            if showsCamera, let rect = layout.camera { drawCamera(in: rect.applying(transform), context: context) }
            if guides {
                let safe = canvas.insetBy(dx: size.width * 0.05, dy: size.height * 0.05)
                var corners = Path()
                let leg = min(safe.width, safe.height) * 0.08
                for x in [safe.minX, safe.maxX] {
                    for y in [safe.minY, safe.maxY] {
                        corners.move(to: CGPoint(x: x + (x == safe.minX ? leg : -leg), y: y))
                        corners.addLine(to: CGPoint(x: x, y: y))
                        corners.addLine(to: CGPoint(x: x, y: y + (y == safe.minY ? leg : -leg)))
                    }
                }
                context.stroke(corners, with: .color(.white.opacity(0.60)), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: guides ? 4 : 2))
        .accessibilityHidden(true)
    }

    private func drawScreen(in rect: CGRect, context: GraphicsContext) {
        let blue = Color(nsColor: Theme.videoClip)
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: [blue.opacity(0.70), blue]),
                     startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        // A single desktop window gives a wide screen and a narrow captured window the same visual identity.
        let unit = min(rect.width, rect.height * 1.6)
        let w = unit * 0.70, h = unit * 0.39
        let box = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let face = Path(roundedRect: box, cornerRadius: h * 0.07)
        context.fill(face, with: .color(.black.opacity(0.23)))
        context.stroke(face, with: .color(.white.opacity(0.62)), lineWidth: max(0.6, h * 0.018))
        let toolbarY = box.minY + h * 0.19
        var toolbar = Path()
        toolbar.move(to: CGPoint(x: box.minX, y: toolbarY))
        toolbar.addLine(to: CGPoint(x: box.maxX, y: toolbarY))
        context.stroke(toolbar, with: .color(.white.opacity(0.33)), lineWidth: max(0.4, h * 0.014))
        for i in 0..<3 {
            let dot = CGRect(x: box.minX + h * (0.07 + CGFloat(i) * 0.10), y: box.minY + h * 0.06,
                             width: h * 0.055, height: h * 0.055)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.74)))
        }
        let slide = CGRect(x: box.minX + w * 0.065, y: box.minY + h * 0.31, width: w * 0.48, height: h * 0.53)
        context.fill(Path(roundedRect: slide, cornerRadius: h * 0.04), with: .color(.white.opacity(0.28)))
        for (i, lineWidth) in [0.29, 0.22, 0.25].enumerated() {
            let bar = CGRect(x: box.minX + w * 0.61, y: box.minY + h * (0.36 + CGFloat(i) * 0.16),
                             width: w * lineWidth, height: h * 0.045)
            context.fill(Path(roundedRect: bar, cornerRadius: h * 0.02), with: .color(.white.opacity(0.56)))
        }
    }

    private func drawCamera(in rect: CGRect, context: GraphicsContext) {
        let purple = Color(nsColor: Theme.imageClip)
        var tile = context
        tile.clip(to: Path(rect))
        tile.fill(Path(rect), with: .color(Color(nsColor: Theme.rowB)))
        tile.fill(Path(rect), with: .linearGradient(Gradient(colors: [purple, purple.opacity(0.75)]),
                  startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        let scale = min(rect.width, rect.height)
        let head = CGRect(x: rect.midX - scale * 0.13, y: rect.midY - scale * 0.28,
                          width: scale * 0.26, height: scale * 0.29)
        tile.fill(Path(ellipseIn: head), with: .color(.white.opacity(0.88)))
        let shoulders = CGRect(x: rect.midX - scale * 0.28, y: rect.midY + scale * 0.05,
                               width: scale * 0.56, height: scale * 0.39)
        var silhouette = tile
        silhouette.clip(to: Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                    height: rect.height / 2 + scale * 0.23)))
        silhouette.fill(Path(ellipseIn: shoulders), with: .color(.white.opacity(0.72)))
        if scene.isPictureInPicture {
            let line = max(0.7, scale * 0.022)
            tile.stroke(Path(rect.insetBy(dx: line / 2, dy: line / 2)), with: .color(.white.opacity(0.72)), lineWidth: line)
        }
    }
}

private struct StudioSceneStrip: View {
    @ObservedObject var rec: RecordController
    var screenAspect: CGFloat = 16 / 9
    var cameraAspect: CGFloat = 16 / 9
    var compact = false
    @FocusState private var focused: StudioScene?
    private let scenes: [StudioScene] = [.screen, .camera, .pictureInPicture, .sideBySide, .custom]

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(scenes, id: \.self) { scene in
                let target = scene == .pictureInPicture ? rec.studioInsetScene : scene
                let selected = target == rec.studioScene
                let available = scene == .screen || scene == .custom || rec.studioCameraAvailable
                Button { rec.selectScene(target) } label: {
                    VStack(spacing: compact ? 2 : 4) {
                        StudioSchematic(scene: target, screenAspect: screenAspect, cameraAspect: cameraAspect,
                                        customLayout: rec.studioCustomLayout, showsCamera: scene != .custom || rec.studioCameraAvailable)
                            .equatable()
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(height: compact ? 18 : 27)
                        Text(verbatim: L(scene.title)).font(.caption)
                            .lineLimit(1).minimumScaleFactor(0.78)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.vertical, compact ? 3 : 5)
                    .background(selected ? Theme.inspectorSelection : Theme.inspectorInset,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(
                            focused == scene ? Color.primary : (selected ? Theme.accentColor : Theme.inspectorBorder),
                            lineWidth: focused == scene || selected ? 2 : 1)
                    }
                    .opacity(available ? 1 : 0.50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: scene)
                .disabled(!available)
                .accessibilityLabel(Text(verbatim: L(scene.title)))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("studio-scene-\(scene.rawValue)")
            }
        }
        .onMoveCommand { direction in
            let availableScenes = rec.studioCameraAvailable ? scenes : [.screen, .custom]
            guard let focused, let current = availableScenes.firstIndex(of: focused) else { return }
            let next: Int
            switch direction {
            case .left: next = current - 1
            case .right: next = current + 1
            default: return
            }
            guard availableScenes.indices.contains(next) else { return }
            let scene = availableScenes[next]
            self.focused = scene
            rec.selectScene(scene == .pictureInPicture ? rec.studioInsetScene : scene)
        }
    }
}

private struct StudioCorners: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        HStack {
            Label("작은 카메라 위치", systemImage: "pip").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("작은 카메라 위치", selection: Binding(get: { rec.studioInsetScene }, set: { rec.selectScene($0) })) {
                Text("왼쪽 위").tag(StudioScene.pictureInPictureTopLeft)
                Text("오른쪽 위").tag(StudioScene.pictureInPictureTopRight)
                Text("왼쪽 아래").tag(StudioScene.pictureInPictureBottomLeft)
                Text("오른쪽 아래").tag(StudioScene.pictureInPicture)
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .accessibilityIdentifier("studio-pip-corner")
        }
        .disabled(!rec.studioScene.isPictureInPicture || !rec.studioCameraAvailable)
    }
}

struct StudioDestinationSetup: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $rec.liveEnabled) {
                Label("실시간 송출", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("studio-live-enabled")
            if rec.liveEnabled {
                Picker("송출 방식", selection: $rec.useYouTubeAccount) {
                    Text("YouTube 계정").tag(true)
                    Text("스트림 키").tag(false)
                }.labelsHidden().pickerStyle(.segmented)
                if rec.useYouTubeAccount { YouTubeStudioSetup(rec: rec) } else { manualDestination }
            } else {
                Label("현재 설정으로는 이 Mac에만 녹화합니다.", systemImage: "internaldrive")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var manualDestination: some View {
        Text("방송 채널에서 받은 서버 주소와 스트림 키를 입력하세요.")
            .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
            Text("서버 주소").font(.caption)
            TextField("rtmps://…", text: $rec.liveServer)
                .accessibilityLabel(Text("서버 주소")).accessibilityIdentifier("studio-live-server")
        }
        VStack(alignment: .leading, spacing: 3) {
            Text("스트림 키").font(.caption)
            SecureField("스트림 키", text: $rec.liveKey).accessibilityIdentifier("studio-live-key")
        }
        if !rec.liveServer.isEmpty && !rec.liveKey.isEmpty,
           (try? StudioProgram.destination(server: rec.liveServer, key: rec.liveKey)) == nil {
            Text("RTMP 또는 RTMPS 서버 주소와 스트림 키를 확인하세요.")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

struct StudioMonitor: View {
    @ObservedObject var rec: RecordController

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Label("방송 스튜디오", systemImage: "rectangle.on.rectangle").fontWeight(.semibold)
                Spacer(minLength: 4)
                if rec.liveEnabled { Text(verbatim: L(rec.liveStatus)).lineLimit(2).multilineTextAlignment(.trailing) }
                StudioLayoutEditButton(rec: rec, compact: true)
                    .disabled(rec.phase != .recording && rec.phase != .paused)
            }
            .font(.caption)
            if !rec.deviceWarning.isEmpty {
                Label(L(rec.deviceWarning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if rec.liveEnabled && rec.useYouTubeAccount && !rec.youtubeStatus.isEmpty {
                Text(verbatim: L(rec.youtubeStatus)).font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                Color.black
                if let frame = rec.studioPreview {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("영상 입력 대기 중").font(.caption).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(height: rec.liveEnabled && rec.useYouTubeAccount ? 118 : 139)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("현재 장면 미리보기"))
            .accessibilityValue(Text(verbatim: L(rec.studioScene.title)))
            VStack(spacing: 4) {
                StudioSceneStrip(rec: rec, screenAspect: rec.studioScreenAspect, cameraAspect: rec.studioCameraAspect, compact: true)
                if rec.studioCameraAvailable { StudioCorners(rec: rec) }
            }
            .disabled(rec.phase != .recording && rec.phase != .paused)
        }
        .padding(8).background(Theme.panelBG, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}
