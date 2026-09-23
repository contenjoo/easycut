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
            .help(help)
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
