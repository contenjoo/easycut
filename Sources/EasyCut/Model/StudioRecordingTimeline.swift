import Foundation

struct StudioSceneChange {
    let time: Double
    let scene: StudioScene
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
        var cuts = [StudioSceneChange(time: 0, scene: changes.first?.scene ?? .screen)]
        for change in changes.dropFirst() where change.time.isFinite && change.time >= 0 {
            guard duration - change.time >= Self.minClipDuration, let last = cuts.last else { continue }
            if change.time - last.time < Self.minClipDuration {
                cuts[cuts.count - 1] = StudioSceneChange(time: last.time, scene: change.scene)
            } else if change.scene != last.scene {
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
            let scene = camera == nil ? StudioScene.screen : change.scene
            let frames = scene.frames(screenAspect: screen.width / max(1, screen.height), cameraAspect: cameraAspect)
            if var base = clip(screen, from: change.time, to: end, frame: frames.screen) {
                base.showClicks = showClicks
                tracks[0].clips.append(base)
            }
            if let camera, var face = clip(camera, from: change.time, to: end, frame: frames.camera) {
                face.volume = 0
                tracks[1].clips.append(face)
            }
        }
        if let audio { insert(asset: audio, track: 2, at: at) }
    }
}
