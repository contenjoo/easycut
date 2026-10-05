import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: PlayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct PreviewPane: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var player: PlayerController
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerLayerView(player: player.player)
                    .aspectRatio(store.project.canvasWidth / max(1, store.project.canvasHeight), contentMode: .fit)
                    .overlay { BlurOverlay(store: store, player: player) }
                if store.project.duration == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                        Text("영상, 오디오, 사진을 여기로 끌어다 놓으세요")
                            .font(.title3.weight(.semibold))
                        Text("또는 ⌘I 로 가져오기")
                            .foregroundStyle(.secondary)
                        Button("미디어 가져오기…") { store.importPanel() }
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                if dropping {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
                if player.speed != 1 && player.isPlaying {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(TimelineNSView.speedLabel(player.speed)) 재생")
                                .font(.headline.monospacedDigit())
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadURLs(providers) { urls in store.importFiles(urls, place: nil) }
                return true
            }
            TransportBar(store: store, player: player)
        }
    }
}

/// 선택한 클립의 가리기 영역을 미리보기 위에 보여 주고 끌어서 옮기거나 크기를 바꾼다
struct BlurOverlay: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var player: PlayerController
    @State private var origin: BlurRegion?
    @State private var drawStart: CGPoint?
    @State private var drawEnd: CGPoint?

    /// 선택된 클립과 그 원본 화면이 캔버스(보기 좌표)에서 차지하는 자리
    func target(_ size: CGSize) -> (clip: Clip, frame: CGRect)? {
        guard store.selection.count == 1, let id = store.selection.first, let clip = store.project.clip(id),
              clip.kind == .media, let a = store.project.asset(clip.assetID), a.kind != .audio,
              a.width > 0, a.height > 0 else { return nil }
        let t = player.time
        guard t >= clip.start - 0.001, t < clip.end + 0.001 else { return nil }
        let fit = min(size.width / a.width, size.height / a.height) * clip.scale
        let fw = a.width * fit, fh = a.height * fit
        let fx = (size.width - fw) / 2 + clip.offsetX * size.width
        let fy = (size.height - fh) / 2 + clip.offsetY * size.height
        return (clip, CGRect(x: fx, y: fy, width: fw, height: fh))
    }

    var body: some View {
        GeometryReader { geo in
            if !player.isPlaying, let (clip, f) = target(geo.size) {
                let s = clip.sourceTime(atTimeline: min(max(player.time, clip.start), clip.end - 0.001))
                ZStack(alignment: .topLeading) {
                    if store.drawingBlur {
                        Color.black.opacity(0.15)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { v in drawStart = v.startLocation; drawEnd = v.location }
                                .onEnded { v in
                                    let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                                   width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                                        .intersection(f)
                                    drawStart = nil; drawEnd = nil
                                    store.drawingBlur = false
                                    guard !r.isNull, r.width > 4, r.height > 4 else { return }
                                    store.addBlur(clip.id, rect: CGRect(x: (r.minX - f.minX) / f.width, y: (r.minY - f.minY) / f.height,
                                                                         width: r.width / f.width, height: r.height / f.height))
                                })
                        if let a = drawStart, let b = drawEnd {
                            Rectangle().stroke(Theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                                .offset(x: min(a.x, b.x), y: min(a.y, b.y))
                        }
                    }
                    ForEach((clip.blurs ?? []).filter { $0.isActive(atSource: s) }) { r in
                        region(r, clip: clip, frame: f)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
        }
    }

    func region(_ r: BlurRegion, clip: Clip, frame f: CGRect) -> some View {
        let rect = CGRect(x: f.minX + r.x * f.width, y: f.minY + r.y * f.height, width: r.w * f.width, height: r.h * f.height)
        let selected = store.selectedBlur == r.id
        return ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(selected ? Theme.accentColor : Color.white.opacity(0.85),
                                            style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 3])))
                .overlay(alignment: .topLeading) {
                    if selected || rect.width > 60 {
                        Text(L(r.label))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(selected ? Theme.accentColor : Color.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .offset(y: -15)
                    }
                }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if origin?.id != r.id { origin = r; store.selectedBlur = r.id }
                        guard let o = origin else { return }
                        store.updateBlur(clip.id, r.id, key: "blurmove") {
                            $0.x = o.x + v.translation.width / f.width
                            $0.y = o.y + v.translation.height / f.height
                        }
                    }
                    .onEnded { _ in origin = nil })
                .onTapGesture { store.selectedBlur = r.id }
            if selected {
                Rectangle()
                    .fill(Theme.accentColor)
                    .frame(width: 10, height: 10)
                    .offset(x: 5, y: 5)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if origin?.id != r.id { origin = r }
                            guard let o = origin else { return }
                            store.updateBlur(clip.id, r.id, key: "blursize") {
                                $0.w = max(0.01, o.w + v.translation.width / f.width)
                                $0.h = max(0.01, o.h + v.translation.height / f.height)
                            }
                        }
                        .onEnded { _ in origin = nil })
                    .help("끌어서 크기 조절")
            }
        }
        .frame(width: max(4, rect.width), height: max(4, rect.height))
        .offset(x: rect.minX, y: rect.minY)
        .help(r.text.map { "\(L(r.label)): \($0)" } ?? L(r.label))
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
}

struct TransportBar: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var player: PlayerController
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(TimeFormat.clock(player.time))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Slider(value: Binding(get: { player.time }, set: { store.seek($0) }),
                       in: 0...max(0.01, player.duration)) { editing in
                    if editing { player.pause() }
                }
                .controlSize(.small)
                Text(TimeFormat.clock(player.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                SpeedControl(player: player)
                Spacer(minLength: 2)
                iconButton("backward.end.fill", "처음으로 (Home)") { store.seek(0) }
                iconButton("gobackward.5", "5초 뒤로 (⇧←)") { store.seek(player.time - 5) }
                iconButton("chevron.left", "이전 프레임 (,)") { player.step(frames: -1, fps: store.project.fps) }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 34, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .help("재생/일시정지 (Space)")
                iconButton("chevron.right", "다음 프레임 (.)") { player.step(frames: 1, fps: store.project.fps) }
                iconButton("goforward.5", "5초 앞으로 (⇧→)") { store.seek(player.time + 5) }
                iconButton("forward.end.fill", "끝으로 (End)") { store.seek(player.duration) }
                Spacer(minLength: 2)
                Toggle(isOn: Binding(get: { store.project.showCaptions }, set: { v in store.updateProject(key: "cc") { $0.showCaptions = v } })) {
                    Image(systemName: "captions.bubble")
                }
                .toggleStyle(.button)
                .help("미리보기 자막 표시")
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .help("미리보기 볼륨")
                LevelMeter(level: player.level)
                    .help("재생 중인 소리 크기 — 막대가 움직이는데 안 들리면 Mac 출력 장치/음량을 확인하세요")
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                    .frame(width: 60)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .fixedSize(horizontal: false, vertical: true)
    }

    func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 20, height: 20) }
            .buttonStyle(.borderless)
            .help(L(help))
    }
}

/// 재생 소리 크기 막대
struct LevelMeter: View {
    let level: Float

    var body: some View {
        let db = 20 * log10(max(Double(level), 0.0001))
        let fill = max(0, min(1, (db + 50) / 50))
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.25))
            RoundedRectangle(cornerRadius: 2)
                .fill(fill > 0.9 ? Color.red : (fill > 0.7 ? Color.yellow : Color.green))
                .frame(height: 18 * fill)
        }
        .frame(width: 6, height: 18)
        .animation(.linear(duration: 0.05), value: fill)
    }
}

struct SpeedControl: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hare.fill").foregroundStyle(player.speed > 1 ? Theme.accentColor : .secondary)
            Menu {
                ForEach(PlayerController.speeds, id: \.self) { s in
                    Button {
                        player.setSpeed(s)
                    } label: {
                        if abs(player.speed - s) < 0.001 { Label(TimelineNSView.speedLabel(s), systemImage: "checkmark") } else { Text(TimelineNSView.speedLabel(s)) }
                    }
                }
            } label: {
                Text(TimelineNSView.speedLabel(player.speed))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("재생 속도 (최대 20배속) — [ 느리게, ] 빠르게, \\ 1배속")
            Slider(value: Binding(get: { log(player.speed) }, set: { v in
                let s = exp(v)
                // 보기 좋은 값에 맞춘다
                let snapped = PlayerController.speeds.min { abs($0 - s) < abs($1 - s) } ?? s
                player.setSpeed(abs(snapped - s) / s < 0.08 ? snapped : (s * 10).rounded() / 10)
            }), in: log(0.25)...log(20))
            .frame(width: 80)
            .controlSize(.small)
        }
    }
}
