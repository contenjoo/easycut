import AppKit
import AVFoundation

/// EASYCUT_SELFTEST_ONLY=audio-polish : 목소리 선명하게 · 음량 맞추기 · 배경음악 줄이기 · 단어 강조 자막
extension SelfTest {
    static func testAudioPolish(_ dir: URL) async throws {
        testCaptionWordTimings()
        testDuckEnvelope()
        testWordHighlightRender()
        guard let ffmpeg = Tools.find("ffmpeg") else { check(false, "ffmpeg 없음"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func make(_ name: String, _ args: [String]) async throws -> URL {
            let u = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: u)
            let (c, log) = await AudioPolish.run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + args + [u.path])
            guard c == 0 else { throw MediaError.failed("테스트 파일 생성 실패: \(log)") }
            return u
        }
        func rms(_ url: URL, from a: Double, to b: Double) async -> Double {
            let (_, log) = await AudioPolish.run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", url.path, "-vn",
                                                          "-af", "atrim=\(a):\(b),astats=measure_perchannel=none", "-f", "null", "-"])
            for line in log.split(separator: "\n") where line.contains("RMS level dB") {
                if let v = line.split(separator: ":").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) { return v }
            }
            return .nan
        }

        // 1) 소음 줄이기: 앞 1초는 소음만, 뒤는 소리+소음
        let noisy = try await make("noisy.wav", ["-f", "lavfi", "-i", "anoisesrc=d=4:c=pink:a=0.08:r=48000",
                                                 "-f", "lavfi", "-i", "sine=f=330:d=4:r=48000",
                                                 "-filter_complex", "[1]volume=0.4,adelay=1000|1000[s];[0][s]amix=inputs=2:normalize=0",
                                                 "-ac", "1"])
        let noisyAsset = try await MediaProbe.probe(noisy)
        try? FileManager.default.removeItem(at: AudioPolish.denoisedURL(for: noisyAsset))
        let clean = try await AudioPolish.ensureDenoised(noisyAsset)
        let cleanDur = try await AVURLAsset(url: clean).load(.duration).seconds
        check(abs(cleanDur - noisyAsset.duration) < 0.1, "소음 줄이기: 길이 유지 (\(cleanDur))")
        let before = await rms(noisy, from: 0.2, to: 0.9), after = await rms(clean, from: 0.2, to: 0.9)
        check(after < before - 6, "소음 줄이기: 소음 구간 \(Int(before)) → \(Int(after)) dB")
        let toneBefore = await rms(noisy, from: 2, to: 3), toneAfter = await rms(clean, from: 2, to: 3)
        check(abs(toneBefore - toneAfter) < 4, "소음 줄이기: 말소리(톤) 크기 유지 \(Int(toneBefore)) → \(Int(toneAfter)) dB")
        var p = Project()
        p.assets = [noisyAsset]
        let cid = p.insert(asset: noisyAsset, track: 0, at: 0)
        if let loc = p.locate(clip: cid) { p.tracks[loc.track].clips[loc.index].denoise = true }
        let denoisedOut = dir.appendingPathComponent("denoised-export.m4a")
        try await Exporter.export(project: p, format: .m4a, size: .zero, burnCaptions: false, to: denoisedOut, cancel: Exporter.Box()) { _ in }
        let exported = await rms(denoisedOut, from: 0.2, to: 0.9)
        check(exported < before - 6, "소음 줄이기: 내보낸 파일에도 적용 (\(Int(exported)) dB)")

        // 2) 음량 맞추기: 작은 소리 → -14 LUFS
        let quiet = try await make("quiet.m4a", ["-f", "lavfi", "-i", "sine=f=440:d=5:r=48000", "-af", "volume=0.02", "-c:a", "aac"])
        let quietAsset = try await MediaProbe.probe(quiet)
        var q = Project()
        q.assets = [quietAsset]
        _ = q.insert(asset: quietAsset, track: 0, at: 0)
        q.loudnessTarget = -14
        let loudOut = dir.appendingPathComponent("loud.m4a")
        try await Exporter.export(project: q, format: .m4a, size: .zero, burnCaptions: false, to: loudOut, cancel: Exporter.Box()) { _ in }
        let lufs = await AudioPolish.measure(loudOut) ?? .nan
        check(abs(lufs + 14) < 1.5, "음량 맞추기: \(String(format: "%.1f", lufs)) LUFS ≈ -14")
        let loudDur = try await AVURLAsset(url: loudOut).load(.duration).seconds
        check(abs(loudDur - 5) < 0.15, "음량 맞추기: 길이 유지 (\(loudDur))")
        // 영상이 있는 MP4도 영상은 그대로 두고 소리만 맞춘다
        let video = try await make("clip.mp4", ["-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=3", "-f", "lavfi", "-i", "sine=f=500:d=3",
                                                "-af", "volume=0.03", "-c:v", "h264_videotoolbox", "-b:v", "800k", "-c:a", "aac", "-shortest"])
        let videoAsset = try await MediaProbe.probe(video)
        var v = Project()
        v.assets = [videoAsset]
        v.canvasWidth = 320; v.canvasHeight = 180
        _ = v.insert(asset: videoAsset, track: 0, at: 0)
        v.loudnessTarget = -16
        let videoOut = dir.appendingPathComponent("loud.mp4")
        try await Exporter.export(project: v, format: .mp4H264, size: CGSize(width: 320, height: 180), burnCaptions: false,
                                  to: videoOut, cancel: Exporter.Box()) { _ in }
        let vl = await AudioPolish.measure(videoOut) ?? .nan
        let vTracks = try await AVURLAsset(url: videoOut).loadTracks(withMediaType: .video)
        check(abs(vl + 16) < 1.5 && vTracks.count == 1, "음량 맞추기 MP4: \(String(format: "%.1f", vl)) LUFS, 영상 트랙 유지")

        // 3) 배경음악 자동 줄이기: 1~2초에 말소리(대본 단어)가 있으면 음악이 약 -12 dB
        let voice = try await make("voice.m4a", ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "5", "-c:a", "aac"])
        let music = try await make("music.m4a", ["-f", "lavfi", "-i", "sine=f=220:d=5:r=48000", "-af", "volume=0.3", "-c:a", "aac"])
        var voiceAsset = try await MediaProbe.probe(voice)
        voiceAsset.words = [Word(text: "안녕", start: 1.0, end: 1.4), Word(text: "하세요", start: 1.5, end: 2.0)]
        let musicAsset = try await MediaProbe.probe(music)
        var d = Project()
        d.assets = [voiceAsset, musicAsset]
        _ = d.insert(asset: voiceAsset, track: 0, at: 0)
        _ = d.insert(asset: musicAsset, track: 1, at: 0)
        let plain = dir.appendingPathComponent("duck-off.m4a"), ducked = dir.appendingPathComponent("duck-on.m4a")
        try await Exporter.export(project: d, format: .m4a, size: .zero, burnCaptions: false, to: plain, cancel: Exporter.Box()) { _ in }
        d.autoDuck = true
        try await Exporter.export(project: d, format: .m4a, size: .zero, burnCaptions: false, to: ducked, cancel: Exporter.Box()) { _ in }
        let offSpeech = await rms(plain, from: 1.3, to: 1.8), onSpeech = await rms(ducked, from: 1.3, to: 1.8)
        let onQuiet = await rms(ducked, from: 3.5, to: 4.5), offQuiet = await rms(plain, from: 3.5, to: 4.5)
        check(abs((offSpeech - onSpeech) - 12) < 2, "배경음악 줄이기: 말할 때 \(String(format: "%.1f", offSpeech - onSpeech)) dB 감소")
        check(abs(onQuiet - offQuiet) < 0.6, "배경음악 줄이기: 말 없는 구간은 원래 크기")

        // 4) 실제 합성 화면: 1.5초에 둘째 어절만 노랑
        var h = v
        h.captions = [Caption(start: 0, end: 3, text: "하나 둘 셋")]
        h.captionStyle.backgroundColor = .clear
        h.captionStyle.fontSize = 120
        h.canvasWidth = 1280; h.canvasHeight = 720
        h.tracks[0].hidden = true
        let png0 = dir.appendingPathComponent("hl-off.png"), png1 = dir.appendingPathComponent("hl-on.png")
        try await Exporter.snapshot(project: h, time: 1.5, to: png0)
        h.captionStyle.wordHighlight = true
        try await Exporter.snapshot(project: h, time: 1.5, to: png1)
        func yellowCount(_ u: URL) -> Int {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            var n = 0
            for i in stride(from: 0, to: img.width * img.height * 4, by: 4) where d[i] > 220 && d[i + 1] > 180 && d[i + 2] < 60 { n += 1 }
            return n
        }
        let y0 = yellowCount(png0), y1 = yellowCount(png1)
        check(y0 < 50 && y1 > 1500, "단어 강조: 실제 합성 화면에 강조 어절 (\(y0) → \(y1))")
        try? FileManager.default.removeItem(at: AudioPolish.denoisedURL(for: noisyAsset))
    }

    static func testCaptionWordTimings() {
        let toks = CaptionWords.tokens("  안녕 하세요  여러분 ")
        check(toks.map(\.location) == [0, 3, 8] && toks.map(\.length) == [2, 3, 3], "단어 강조: 어절 범위 \(toks)")
        let exact = CaptionWords.timings(text: "안녕 하세요 여러분", start: 1, end: 3, words: [1.0, 1.6, 2.3])
        check(exact.map(\.start) == [1.0, 1.6, 2.3], "단어 강조: 대본 단어 시각 사용")
        let even = CaptionWords.timings(text: "ab cd", start: 0, end: 2, words: [0.1])
        check(even.map(\.start) == [0, 1], "단어 강조: 대본이 안 맞으면 글자 수 비율")
        check(CaptionWords.activeIndex(exact, at: 0.5) == 0 && CaptionWords.activeIndex(exact, at: 1.7) == 1
              && CaptionWords.activeIndex(exact, at: 2.9) == 2, "단어 강조: 시각별 강조 어절")
        let emoji = CaptionWords.tokens("좋아요👍 끝")
        check(emoji.count == 2 && emoji[0].length == "좋아요👍".utf16.count, "단어 강조: 이모지 UTF-16 길이")
        var p = Project()
        var a = MediaAsset(path: "/tmp/w.mp4", name: "w", kind: .video, duration: 10, width: 1, height: 1, hasAudio: true)
        a.words = [Word(text: "하나", start: 1, end: 1.5), Word(text: "둘", start: 2, end: 2.4), Word(text: "셋", start: 5, end: 5.5)]
        p.assets = [a]
        _ = p.insert(asset: a, track: 0, at: 0)
        p.captions = [Caption(start: 0.9, end: 3, text: "하나 둘")]
        let t = p.captionWordTimings()[p.captions[0].id] ?? []
        check(t.map(\.start) == [1, 2], "단어 강조: 자막 구간 안 단어만 사용")
    }

    static func testDuckEnvelope() {
        let speech: [ClosedRange<Double>] = [2...3]
        check(abs(AudioPolish.duckFactor(at: 2.5, speech: speech) - AudioPolish.duckLevel) < 1e-9, "더킹: 말소리 구간 배율")
        check(AudioPolish.duckFactor(at: 1, speech: speech) == 1 && AudioPolish.duckFactor(at: 4, speech: speech) == 1, "더킹: 바깥은 1")
        let mid = AudioPolish.duckFactor(at: 2 - AudioPolish.duckRamp / 2, speech: speech)
        check(mid > AudioPolish.duckLevel && mid < 1, "더킹: 부드럽게 줄어듦")
        let clip = Clip(start: 0, sourceIn: 0, sourceOut: 6, fadeIn: 1, fadeOut: 1)
        let env = AudioPolish.envelope(clip, speech: speech)
        check(env.first?.v == 0 && env.last?.v == 0, "더킹: 페이드 시작·끝 0")
        check(env.contains { abs($0.t - 2.5) < 1e-9 } == false && env.contains { abs($0.t - 2) < 1e-9 && abs($0.v - AudioPolish.duckLevel) < 1e-9 },
              "더킹: 말소리 시작점 배율")
        // 대본 없는 오디오만 배경음악, 가까운 말은 한 구간
        var p = Project()
        var v = MediaAsset(path: "/tmp/v.mp4", name: "v", kind: .video, duration: 10, width: 1, height: 1, hasAudio: true)
        v.words = [Word(text: "a", start: 1, end: 1.2), Word(text: "b", start: 1.5, end: 2), Word(text: "c", start: 5, end: 6)]
        let m = MediaAsset(path: "/tmp/m.mp3", name: "m", kind: .audio, duration: 10, width: 0, height: 0, hasAudio: true)
        p.assets = [v, m]
        _ = p.insert(asset: v, track: 0, at: 0)
        _ = p.insert(asset: m, track: 1, at: 0)
        let r = AudioPolish.speechRanges(p)
        check(r == [1...2, 5...6], "더킹: 말소리 구간 \(r)")
        check(AudioPolish.isMusic(m) && !AudioPolish.isMusic(v), "더킹: 배경음악 판별")
        p.tracks[0].muted = true
        check(AudioPolish.speechRanges(p).isEmpty, "더킹: 음소거 트랙 말소리 제외")
    }

    static func testWordHighlightRender() {
        var style = TextStyle.caption
        style.backgroundColor = .clear
        func yellow(_ img: CGImage?) -> Int {
            guard let img, let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
            var n = 0
            for i in stride(from: 0, to: CFDataGetLength(data) - 3, by: 4) {
                let b = Int(ptr[i]), g = Int(ptr[i + 1]), r = Int(ptr[i + 2]), a = Int(ptr[i + 3])
                if a > 200, r > 200, g > 170, b < 90 { n += 1 }
            }
            return n
        }
        let none = yellow(TextRenderer.render(text: "안녕 하세요", style: style, unit: 1, maxWidth: 800))
        let first = yellow(TextRenderer.render(text: "안녕 하세요", style: style, unit: 1, maxWidth: 800,
                                               highlight: NSRange(location: 0, length: 2)))
        check(none == 0 && first > 50, "단어 강조: 강조 어절만 노랑 (\(none) → \(first))")
    }
}
