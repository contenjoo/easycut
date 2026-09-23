import AVFoundation
import Combine

/// 미리보기 재생 제어. 0.1배 ~ 20배속 지원.
@MainActor
final class PlayerController: ObservableObject {
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 10, 12, 16, 20]

    let player = AVPlayer()
    @Published var time: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var speed: Double = 1
    @Published private(set) var duration: Double = 0
    @Published var volume: Float = 1 { didSet { player.volume = volume } }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var turboTimer: Timer?
    private var seekInFlight = false
    private var pendingSeek: (Double, Bool)?
    private var lastTurboTick = Date()

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seekInFlight, self.turboTimer == nil else { return }
                if self.isPlaying { self.time = t.seconds }
            }
        }
    }

    func load(_ built: BuiltComposition) {
        let keep = time
        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopTurbo()
                self.isPlaying = false
                self.time = self.duration
                self.player.seek(to: CompositionBuilder.ct(self.displayTime(self.duration)), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.replaceCurrentItem(with: item)
        duration = built.duration
        let t = min(keep, max(0, duration))
        time = t
        player.seek(to: CompositionBuilder.ct(displayTime(t)), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { isPlaying = false; play() }
    }

    func clear() {
        pause()
        player.replaceCurrentItem(with: nil)
        duration = 0
        time = 0
    }

    // MARK: 재생

    func play() {
        guard duration > 0 else { return }
        if time >= duration - 0.05 { seek(0) }
        isPlaying = true
        applyRate()
    }

    func pause() {
        stopTurbo()
        player.pause()
        if isPlaying { time = player.currentTime().seconds.isFinite ? player.currentTime().seconds : time }
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func setSpeed(_ s: Double) {
        speed = min(max(s, 0.1), 20)
        if isPlaying { applyRate() }
    }

    /// J/K/L 셔틀: 빠르게
    func faster() {
        if !isPlaying { setSpeed(1); play(); return }
        let next = Self.shuttle.first { $0 > speed + 0.01 } ?? 20
        setSpeed(next)
    }

    /// 한 단계 올리기 ( ] 키 )
    func stepUp() {
        setSpeed(Self.speeds.first { $0 > speed + 0.01 } ?? 20)
    }

    static let shuttle: [Double] = [1, 2, 4, 8, 16, 20]

    func slower() {
        let prev = Self.shuttle.last { $0 < speed - 0.01 } ?? 0.5
        setSpeed(prev)
        if !isPlaying { play() }
    }

    private func applyRate() {
        guard isPlaying, let item = player.currentItem else { return }
        stopTurbo()
        // AVPlayer가 고배속을 지원하면 그대로, 아니면 탐색 방식(터보)으로 재생
        if speed <= 2 || item.canPlayFastForward {
            player.rate = Float(speed)
            // 적용 확인: 일부 환경에서 rate가 제한되면 터보로 전환
            if speed > 2, abs(Double(player.rate) - speed) > 0.01 {
                startTurbo()
            }
        } else {
            startTurbo()
        }
    }

    private func startTurbo() {
        player.pause()
        lastTurboTick = Date()
        turboTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.turboTick() }
        }
    }

    private func stopTurbo() {
        turboTimer?.invalidate()
        turboTimer = nil
    }

    private func turboTick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTurboTick)
        lastTurboTick = now
        let t = time + dt * speed
        if t >= duration {
            time = duration
            pause()
            return
        }
        time = t
        requestSeek(t, precise: false)
    }

    // MARK: 탐색

    /// 끝 지점에서는 마지막 프레임이 보이도록 살짝 앞을 탐색한다
    private func displayTime(_ t: Double) -> Double { min(t, max(0, duration - 0.04)) }

    func seek(_ t: Double, precise: Bool = true) {
        let target = min(max(0, t), max(0, duration))
        time = target
        let t = displayTime(target)
        if isPlaying && turboTimer == nil {
            player.seek(to: CompositionBuilder.ct(t), toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        requestSeek(t, precise: precise)
    }

    /// 연속 탐색 시 한 번에 하나만 요청하고 마지막 목표로 따라간다
    private func requestSeek(_ t: Double, precise: Bool) {
        if seekInFlight { pendingSeek = (t, precise); return }
        seekInFlight = true
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CompositionBuilder.ct(t), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seekInFlight = false
                if let (nt, np) = self.pendingSeek {
                    self.pendingSeek = nil
                    self.requestSeek(nt, precise: np)
                } else if !precise && !self.isPlaying {
                    // 스크럽이 끝나면 정확한 프레임으로 맞춘다
                    self.player.seek(to: CompositionBuilder.ct(self.displayTime(self.time)), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    func step(frames: Int, fps: Double) {
        pause()
        seek(time + Double(frames) / fps)
    }

    var isTurbo: Bool { turboTimer != nil }
}
