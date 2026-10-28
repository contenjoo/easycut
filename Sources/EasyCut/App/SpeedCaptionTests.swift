import AppKit
import AVFoundation

extension SelfTest {
    static func speedCaptionProject(asset: MediaAsset) -> Project {
        var p = Project()
        p.assets = [asset]
        let first = p.insert(asset: asset, track: 0, at: 0)
        let middle = p.split(clip: first, at: 4)!
        _ = p.split(clip: middle, at: 8)
        p.captions = [Caption(start: 1, end: 1.4, text: "첫 번째 소리"),
                      Caption(start: 4.5, end: 4.9, text: "두 번째 소리"),
                      Caption(start: 8.5, end: 8.9, text: "세 번째 소리")]
        return p
    }

    @MainActor
    static func testSpeedCaptionTiming() {
        let asset = MediaAsset(path: "/tmp/speed.mp4", name: "배속 검증", kind: .video,
                               duration: 12, width: 1280, height: 720, hasAudio: true)
        let base = speedCaptionProject(asset: asset)
        let middle = base.tracks[0].clips[1].id
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
        var p = base
        p.setSpeed(clip: middle, 2)
        check(close(p.duration, 10), "부분 배속: 중간 4초만 2배속 → 전체 10초")
        check(p.captions[0] == base.captions[0], "부분 배속: 앞쪽 자막 유지")
        check(close(p.captions[1].start, 4.25) && close(p.captions[1].end, 4.45), "부분 배속: 구간 안 자막 시작·끝 압축")
        check(close(p.captions[2].start, 6.5) && close(p.captions[2].end, 6.9), "부분 배속: 뒤쪽 자막도 2초 당김")
        check(p.captions.map(\.id) == base.captions.map(\.id) && p.captions.map(\.text) == base.captions.map(\.text), "부분 배속: 자막 ID·교정 내용 유지")
        p.setSpeed(clip: middle, 1)
        check(zip(p.captions, base.captions).allSatisfy { close($0.start, $1.start) && close($0.end, $1.end) }, "부분 배속: 원래 배속 복원 시 시간도 복원")
        p.setSpeed(clip: middle, 0.5)
        check(close(p.captions[1].start, 5) && close(p.captions[2].start, 12.5), "부분 배속: 0.5배속 확장·뒤쪽 자막 이동")
        p = base
        p.captions = [Caption(start: 3, end: 5, text: "앞 경계"), Caption(start: 7, end: 9, text: "뒤 경계")]
        p.setSpeed(clip: middle, 2)
        check(close(p.captions[0].start, 3) && close(p.captions[0].end, 4.5)
              && close(p.captions[1].start, 5.5) && close(p.captions[1].end, 7), "부분 배속: 경계를 가로지르는 자막도 연속 변환")
        p = base
        p.setSpeeds(clips: Set(p.tracks[0].clips.map(\.id)), 2)
        check(zip(p.captions, base.captions).allSatisfy { close($0.start, $1.start / 2) && close($0.end, $1.end / 2) }, "복수 배속: 선택 순서와 무관하게 원래 시간축으로 변환")
        p = base
        var overlay = base.tracks[0].clips[1]
        overlay.id = UUID()
        p.tracks[1].clips = [overlay]
        p.setSpeeds(clips: [middle, overlay.id], 2)
        check(close(p.captions[1].start, 4.25) && close(p.captions[2].start, 6.5), "복수 트랙: 겹친 소리·영상 동시 변경도 자막은 한 번만 변환")
        p = base
        var silent = asset
        silent.id = UUID(); silent.hasAudio = false
        p.assets.append(silent)
        overlay.assetID = silent.id
        p.tracks[1].clips = [overlay]
        p.setSpeed(clip: overlay.id, 2)
        check(p.captions == base.captions, "무음 오버레이 배속: 원래 말소리 자막은 유지")
        p = base
        p.setSpeed(clip: middle, 1)
        p.setSpeed(clip: middle, .nan)
        check(p == base, "동일·유효하지 않은 배속: 시간축 유지")
        let store = EditorStore()
        store.apply { $0 = base }
        store.setSpeed(2, for: [middle])
        store.undo()
        check(store.project.captions == base.captions, "배속 실행 취소: 자막 시간 복원")
        store.redo()
        check(close(store.project.captions[2].start, 6.5), "배속 다시 실행: 자막 시간 재적용")
        check(TimelineNSView.waveformHeight(clipHeight: 52, audioOnly: false) >= 28,
              "영상 파형: 기본 높이 16 → 28 이상")
        check(TimelineNSView.waveformHeight(clipHeight: 154, audioOnly: false) > 100,
              "영상 파형: 트랙을 높이면 함께 확대")
        check(TimelineNSView.waveformHeight(clipHeight: 34, audioOnly: false) <= 14,
              "파형: 작은 트랙에서도 제목 띠 침범 방지")
    }

    static func testSpeedCaptionRender(_ dir: URL) async throws {
        await MainActor.run { testSpeedCaptionTiming() }
        let audio = dir.appendingPathComponent("speed-cues.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 576000)!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / 48000
            let inside = [1.0, 4.5, 8.5].contains { t >= $0 && t < $0 + 0.4 }
            samples[i] = inside ? Float(0.7 * sin(2 * .pi * 440 * t)) : 0
        }
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
        let video = dir.appendingPathComponent("speed-cues.mp4")
        if !FileManager.default.fileExists(atPath: video.path) { try await makeTestVideo(audio: audio, to: video) }
        let asset = try await MediaProbe.probe(video)
        let base = speedCaptionProject(asset: asset)
        try JSONEncoder().encode(base).write(to: dir.appendingPathComponent("before.easycut"))
        var edited = base
        edited.setSpeed(clip: edited.tracks[0].clips[1].id, 2)
        try JSONEncoder().encode(edited).write(to: dir.appendingPathComponent("after.easycut"))
        let output = dir.appendingPathComponent("speed-caption-render.mp4")
        try? FileManager.default.removeItem(at: output)
        try await Exporter.export(project: edited, format: .mp4H264, size: CGSize(width: 640, height: 360),
                                  burnCaptions: true, to: output, cancel: Exporter.Box()) { _ in }
        let loudness = try await SilenceDetector.loudness(url: output)
        for caption in edited.captions {
            let lo = max(0, Int((caption.start - 0.15) / SilenceDetector.hop))
            let hi = min(loudness.count, Int((caption.start + 0.15) / SilenceDetector.hop))
            let onset = (lo..<hi).first { loudness[$0] > -30 }.map { Double($0) * SilenceDetector.hop }
            check(onset.map { abs($0 - caption.start) <= 0.05 } ?? false,
                  "실제 내보내기: \(caption.text) 시작과 소리 오차 50ms 이내")
        }
        let length = try await AVURLAsset(url: output).load(.duration).seconds
        check(abs(length - 10) < 0.06, "실제 내보내기: 부분 배속 후 10초 길이")
        print("검증 프로젝트: \(dir.path)")
    }
}
