import Foundation

struct StudioSceneChange: Codable {
    let time: Double
    let scene: StudioScene
    let customLayout: StudioCustomLayout

    init(time: Double, scene: StudioScene, customLayout: StudioCustomLayout = .standard) {
        self.time = time
        self.scene = scene
        self.customLayout = customLayout
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(time: try values.decode(Double.self, forKey: .time),
                  scene: try values.decode(StudioScene.self, forKey: .scene),
                  customLayout: try values.decodeIfPresent(StudioCustomLayout.self, forKey: .customLayout) ?? .standard)
    }

    func matches(_ scene: StudioScene, customLayout: StudioCustomLayout) -> Bool {
        self.scene == scene && (scene != .custom || self.customLayout == customLayout)
    }
}

extension Project {
    /// 프로그램 화면과 같은 배치로 원본 클립을 자른다. 숨긴 화면의 마이크는 계속 재생한다.
    mutating func insertStudioRecording(screen: MediaAsset, camera: MediaAsset?, audio: MediaAsset?,
                                        changes: [StudioSceneChange], showClicks: Bool) {
        let at = self.duration
        if at == 0 {
            canvasWidth = 1280
            canvasHeight = 720
        }
        while tracks.count < 3 { tracks.append(Track(name: "트랙 \(tracks.count + 1)")) }
        let canvas = canvasSize
        let programFit = min(canvas.width / 1280, canvas.height / 720)
        let program = CGSize(width: 1280 * programFit, height: 720 * programFit)
        let duration = screen.duration
        let cameraAspect = camera.map { $0.width / max(1, $0.height) } ?? 16.0 / 9.0
        // 편집기의 최소 클립 길이보다 짧은 연속 전환은 마지막 배치로 합친다.
        let first = changes.first
        var cuts = [StudioSceneChange(time: 0, scene: first?.scene ?? .screen,
                                      customLayout: first?.customLayout ?? .standard)]
        for change in changes.dropFirst() where change.time.isFinite && change.time >= 0 {
            guard duration - change.time >= Self.minClipDuration, let last = cuts.last else { continue }
            if change.time - last.time < Self.minClipDuration {
                cuts[cuts.count - 1] = StudioSceneChange(time: last.time, scene: change.scene,
                                                         customLayout: change.customLayout)
            } else if !last.matches(change.scene, customLayout: change.customLayout) {
                cuts.append(change)
            }
        }

        func clip(_ asset: MediaAsset, from start: Double, to end: Double, frame: CGRect?) -> Clip? {
            let end = min(end, asset.duration)
            guard end - start >= Self.minClipDuration else { return nil }
            var result = Clip(assetID: asset.id, start: at + start, sourceIn: start, sourceOut: end)
            if let frame, asset.width > 0, asset.height > 0 {
                let fit = min(canvas.width / asset.width, canvas.height / asset.height)
                result.scale = frame.width * program.width / (asset.width * fit)
                result.offsetX = (frame.midX - 0.5) * program.width / canvas.width
                result.offsetY = (frame.midY - 0.5) * program.height / canvas.height
            } else {
                result.opacity = 0
            }
            return result
        }

        for (index, change) in cuts.enumerated() {
            let end = index + 1 < cuts.count ? cuts[index + 1].time : duration
            let scene: StudioScene = camera == nil && change.scene != .custom ? .screen : change.scene
            let frames = scene.frames(screenAspect: screen.width / max(1, screen.height), cameraAspect: cameraAspect,
                                      customLayout: change.customLayout)
            let screenTrack = camera != nil && scene.frontSource(in: change.customLayout) == .screen ? 1 : 0
            if var base = clip(screen, from: change.time, to: end, frame: frames.screen) {
                base.showClicks = showClicks
                tracks[screenTrack].clips.append(base)
            }
            if let camera, var face = clip(camera, from: change.time, to: end, frame: frames.camera) {
                face.volume = 0
                tracks[1 - screenTrack].clips.append(face)
            }
        }
        if let audio { insert(asset: audio, track: 2, at: at) }
    }
}
