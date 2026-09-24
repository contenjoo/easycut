import AVFoundation

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix
    let duration: Double
    let scene: RenderScene
    let missing: [String]
}

/// 프로젝트(타임라인) → AVComposition 변환
enum CompositionBuilder {
    static func ct(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 60000) }

    static func build(project: Project, renderSize: CGSize, captions: Bool? = nil) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        let total = project.duration
        var layers: [RenderLayer] = []
        var trackIDs: [CMPersistentTrackID] = []
        var mixParams: [AVMutableAudioMixInputParameters] = []
        var missing: [String] = []
        var assetCache: [String: AVURLAsset] = [:]

        func avAsset(_ a: MediaAsset) -> AVURLAsset {
            if let c = assetCache[a.path] { return c }
            let c = AVURLAsset(url: a.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assetCache[a.path] = c
            return c
        }

        if total > 0 {
            let blankAsset = AVURLAsset(url: try await BlankVideo.url())
            if let bt = try await blankAsset.loadTracks(withMediaType: .video).first,
               let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let br = try await bt.load(.timeRange)
                try base.insertTimeRange(br, of: bt, at: .zero)
                base.scaleTimeRange(CMTimeRange(start: .zero, duration: br.duration), toDuration: ct(total))
            }
        }

        func end(of track: AVMutableCompositionTrack) -> CMTime {
            track.segments.last.map { $0.timeMapping.target.end } ?? .zero
        }

        func place(_ src: AVAssetTrack, into dst: AVMutableCompositionTrack, clip: Clip) async throws -> Bool {
            let srcRange = try await src.load(.timeRange)
            var range = CMTimeRange(start: ct(clip.sourceIn), end: ct(clip.sourceOut)).intersection(srcRange)
            guard range.duration.seconds > 0.001 else { return false }
            let at = ct(clip.start)
            let cur = end(of: dst)
            if at > cur { dst.insertEmptyTimeRange(CMTimeRange(start: cur, end: at)) }
            let insertAt = max(at, end(of: dst))
            if range.duration.seconds <= 0 { range.duration = ct(Project.minClipDuration) }
            try dst.insertTimeRange(range, of: src, at: insertAt)
            let target = ct(range.duration.seconds / clip.speed)
            if abs(clip.speed - 1) > 0.0001 {
                dst.scaleTimeRange(CMTimeRange(start: insertAt, duration: range.duration), toDuration: target)
            }
            return true
        }

        for track in project.tracks {
            var vTrack: AVMutableCompositionTrack?
            var aTrack: AVMutableCompositionTrack?
            var aParams: AVMutableAudioMixInputParameters?
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                var common = RenderLayer(content: .image(path: ""), start: clip.start, end: clip.end, opacity: clip.opacity,
                                         scale: clip.scale, offsetX: clip.offsetX, offsetY: clip.offsetY,
                                         fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                common.sourceIn = clip.sourceIn
                common.speed = clip.speed
                common.shape = clip.shape ?? .none
                common.backgroundEffect = clip.backgroundEffect ?? .none
                if clip.showClicks == true, let marks = project.asset(clip.assetID)?.clicks {
                    common.clicks = marks.filter { $0.t >= clip.sourceIn - 1 && $0.t <= clip.sourceOut }
                }
                if clip.kind == .text {
                    if !track.hidden {
                        var l = common
                        l.content = .text(clip.text, clip.textStyle)
                        layers.append(l)
                    }
                    continue
                }
                guard let asset = project.asset(clip.assetID) else { continue }
                if asset.isMissing { missing.append(asset.name); continue }
                switch asset.kind {
                case .image:
                    if !track.hidden {
                        var l = common
                        l.content = .image(path: asset.path)
                        layers.append(l)
                    }
                case .video, .audio:
                    let av = avAsset(asset)
                    if asset.kind == .video, !track.hidden, let sv = try await av.loadTracks(withMediaType: .video).first {
                        if vTrack == nil {
                            vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if let id = vTrack?.trackID { trackIDs.append(id) }
                        }
                        if let vt = vTrack, try await place(sv, into: vt, clip: clip) {
                            let t = try await sv.load(.preferredTransform)
                            var l = common
                            l.content = .video(trackID: vt.trackID, orientation: MediaProbe.orientation(t))
                            layers.append(l)
                        }
                    }
                    if !track.muted, clip.volume > 0.001, let sa = try await av.loadTracks(withMediaType: .audio).first {
                        if aTrack == nil {
                            aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if let at = aTrack {
                                aParams = AVMutableAudioMixInputParameters(track: at)
                            }
                        }
                        if let at = aTrack, let p = aParams, try await place(sa, into: at, clip: clip) {
                            let v = Float(min(clip.volume, 4))
                            let fi = min(clip.fadeIn, clip.duration / 2), fo = min(clip.fadeOut, clip.duration / 2)
                            if fi > 0.01 {
                                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: ct(clip.start), duration: ct(fi)))
                            } else {
                                p.setVolume(v, at: ct(clip.start))
                            }
                            if fo > 0.01 {
                                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: ct(clip.end - fo), duration: ct(fo)))
                            }
                        }
                    }
                }
            }
            if let p = aParams { mixParams.append(p) }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams

        let scene = RenderScene(layers: layers,
                                captions: project.captions.sorted { $0.start < $1.start },
                                captionStyle: project.captionStyle,
                                showCaptions: captions ?? project.showCaptions,
                                background: project.background)
        var vc: AVMutableVideoComposition?
        if comp.duration.seconds > 0 {
            let v = AVMutableVideoComposition()
            v.customVideoCompositorClass = EasyCompositor.self
            v.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(120, project.fps.rounded()))))
            v.renderSize = CGSize(width: max(16, (renderSize.width / 2).rounded() * 2), height: max(16, (renderSize.height / 2).rounded() * 2))
            v.instructions = [SceneInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), trackIDs: trackIDs, scene: scene)]
            vc = v
        }
        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, duration: comp.duration.seconds, scene: scene, missing: missing)
    }

    /// 미리보기용 렌더 크기 (최대 1280px)
    static func previewSize(for project: Project, maxSide: Double = 1280) -> CGSize {
        let s = min(1, maxSide / max(project.canvasWidth, project.canvasHeight))
        return CGSize(width: project.canvasWidth * s, height: project.canvasHeight * s)
    }
}
