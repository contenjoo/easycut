import AVFoundation
import AppKit

/// `EasyCut --selftest [작업폴더]` : 화면 없이 편집 엔진 전체를 검사한다.
enum SelfTest {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        print(cond ? "  ✅ \(msg)" : "  ❌ \(msg)")
        if !cond { failures += 1 }
    }

    static func run() {
        let args = CommandLine.arguments
        let dir: URL
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            dir = URL(fileURLWithPath: args[i + 1])
        } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("easycut-selftest")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await runAsync(dir) } catch {
                print("❌ 오류: \(error)")
                failures += 1
            }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print(failures == 0 ? "\n모든 검사 통과" : "\n실패 \(failures)건")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--audio-probe 파일 시간` : 앱과 같은 재생 경로로 해당 파일 소리 측정
    static func audioProbe(_ url: URL, at t: Double) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let a = try await MediaProbe.probe(url)
                var p = Project()
                p.assets = [a]
                p.insert(asset: a, track: 0, at: 0)
                let built = try await CompositionBuilder.build(project: p, renderSize: CompositionBuilder.previewSize(for: p))
                print("오디오 트랙 수(합성):", built.composition.tracks(withMediaType: .audio).count, "믹스 입력:", built.audioMix.inputParameters.count)
                for sp: Float in [1, 2] {
                    let peak = try await AudioProbe.measure(built: built, rate: sp, seconds: 1.5, at: t)
                    print(String(format: "%gx @%.0f초: 최대 음량 %.3f", sp, t, peak))
                }
            } catch { print("오류:", error) }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func runAsync(_ dir: URL) async throws {
        print("1) 모델 연산")
        testTimelineOps()
        check(Updater.isNewer("1.3.0", than: "1.2.0") && Updater.isNewer("v1.10.0", than: "1.9.9")
              && !Updater.isNewer("1.2.0", than: "1.2.0") && !Updater.isNewer("1.2", than: "1.2.0") && Updater.isNewer("2.0", than: "1.99.1"),
              "업데이트 버전 비교")

        print("2) 테스트 미디어 생성 (\(dir.path))")
        let speech = dir.appendingPathComponent("speech.aiff")
        if !FileManager.default.fileExists(atPath: speech.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Yuna", "-o", speech.path,
                           "안녕하세요. 오늘은 영상 편집 프로그램을 소개하겠습니다. [[slnc 1500]] 음성을 텍스트로 바꾸고, 텍스트를 지우면 영상도 같이 잘립니다. [[slnc 2500]] 정말 편리하죠?"]
            try p.run(); p.waitUntilExit()
        }
        let video = dir.appendingPathComponent("test_video.mp4")
        if !FileManager.default.fileExists(atPath: video.path) {
            try await makeTestVideo(audio: speech, to: video)
        }
        let image = dir.appendingPathComponent("logo.png")
        try makeTestImage(to: image)

        let v = try await MediaProbe.probe(video)
        let a = try await MediaProbe.probe(speech)
        let im = try await MediaProbe.probe(image)
        check(v.kind == .video && v.hasAudio && v.width == 1280, "영상 분석: \(v.kind) \(Int(v.width))x\(Int(v.height)) \(String(format: "%.2f", v.duration))초 오디오:\(v.hasAudio)")
        check(a.kind == .audio, "오디오 분석: \(String(format: "%.2f", a.duration))초")
        check(im.kind == .image, "이미지 분석: \(Int(im.width))x\(Int(im.height))")

        print("3) 음성 인식")
        var words: [Word] = []
        if Transcriber.whisperBinary != nil, let m = WhisperModel.all.first(where: \.isInstalled) {
            let t0 = Date()
            words = try await Transcriber.transcribe(url: video, engine: .whisper, language: STTLanguage.all[0], whisperModel: m) { _, _ in }
            print("  Whisper(\(m.id)) \(String(format: "%.1f", Date().timeIntervalSince(t0)))초: " + words.map { "\($0.text)[\(String(format: "%.1f", $0.start))]" }.joined(separator: " "))
            check(words.count >= 10, "Whisper 단어 \(words.count)개 인식")
        } else {
            print("  (Whisper 미설치 — 합성 대본으로 대체. Apple 인식은 앱에서 권한 허용 후 사용)")
        }
        // Apple 인식 배치 합치기 (실측 콜백 순서 재현)
        let bc = Transcriber.BatchCollector()
        bc.add([("안녕하세요", 0, 0.9)])
        bc.add([("안녕하세요.", 0, 0.9), ("오늘은", 1.0, 0.5)])
        bc.add([("음성을", 0, 0.4)])                       // 시간 미확정 중간 결과 → 버림
        bc.add([("음성을", 6.0, 0.39), ("텍스트로", 6.39, 0.6)])
        bc.add([("음성을", 6.0, 0.39), ("텍스트로", 6.39, 0.6), ("바꾸고", 6.99, 0.6)])
        bc.add([("정말", 13.47, 0.45), ("편리하죠", 13.92, 0.81)])
        check(bc.all.map(\.text) == ["안녕하세요.", "오늘은", "음성을", "텍스트로", "바꾸고", "정말", "편리하죠"], "Apple 인식 배치 합치기: \(bc.all.map(\.text).joined(separator: " "))")

        // 소리 크기 기준 무음 검출 
        let db = try await SilenceDetector.loudness(url: video)
        let th = SilenceDetector.autoThreshold(db)
        let sil = SilenceDetector.silences(db, threshold: th, minSilence: 0.8, padding: 0.1)
        print("  자동 기준 \(Int(th))dB, 무음: " + sil.map { String(format: "%.2f~%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "))
        check(sil.count >= 2 && sil.contains { $0.upperBound - $0.lowerBound > 1.0 }, "파형 기준 무음 \(sil.count)곳 검출 (문장 사이 1.5초·2.5초 쉼)")

        let samples = try await Transcriber.pcm16k(url: video)
        check(abs(Double(samples.count) / 16000 - v.duration) < 0.3, "오디오 16kHz 추출: \(samples.count) 샘플")
        let ch = Transcriber.chunks(samples, minLen: 3, maxLen: 6)
        check(ch.first?.lowerBound == 0 && ch.last?.upperBound == samples.count, "무음 기준 청크 분할: \(ch.count)개")
        if words.isEmpty {
            // 합성 대본: 1초 간격 단어
            words = (0..<12).map { i in Word(text: "단어\(i)", start: Double(i) * 0.7 + 0.2, end: Double(i) * 0.7 + 0.7) }
        }

        print("4) 대본 편집 → 컷")
        var p = Project()
        var va = v; va.words = words
        p.assets = [va, a, im]
        p.canvasWidth = 1280; p.canvasHeight = 720
        p.insert(asset: va, track: 0, at: 0)
        let before = p.duration
        let tw = p.timelineWords()
        let del = Set(tw[2...4].map(\.id))
        let ranges = Project.deletionRanges(selected: del, in: tw)
        p.rippleDelete(ranges: ranges)
        let removed = ranges.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        check(abs((before - p.duration) - removed) < 0.01, String(format: "단어 3개 삭제 → %.2f초 잘림 (클립 %d개)", removed, p.tracks[0].clips.count))
        let tw2 = p.timelineWords()
        check(tw2.count == tw.count - 3 && !tw2.contains { del.contains($0.id) }, "삭제된 단어가 대본에서 사라짐 (\(tw.count)→\(tw2.count))")
        let silence = p.silenceRanges(minGap: 0.8, keep: 0.15)
        print("  무음 구간: " + silence.map { String(format: "%.2f~%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "))
        p.captions = p.generatedCaptions()
        check(!p.captions.isEmpty, "자막 자동 생성 \(p.captions.count)개: \(p.captions.first?.text ?? "")")
        let srt = SRT.make(p.captions)
        check(SRT.parse(srt).count == p.captions.count, "SRT 저장/읽기 왕복")

        print("5) 합성 + 내보내기 (20배속 구간, 이미지, 텍스트, 자막 포함)")
        // 두 번째 클립에 이어 원본을 한 번 더 붙이고 20배속
        let id2 = p.insert(asset: va, track: 0, at: p.trackEnd(0))
        p.setSpeed(clip: id2, 20)
        let imgID = p.insert(asset: im, track: 1, at: 0.5, imageDuration: 3)
        if let loc = p.locate(clip: imgID) {
            p.tracks[loc.track].clips[loc.index].scale = 0.25
            p.tracks[loc.track].clips[loc.index].offsetX = 0.35
            p.tracks[loc.track].clips[loc.index].offsetY = -0.33
            p.tracks[loc.track].clips[loc.index].fadeIn = 0.5
        }
        p.insertText("EasyCut 테스트", track: 2, at: 0, duration: 2.5)
        p.insert(asset: a, track: 2, at: p.trackEnd(2) + 0.5)
        p.normalize()
        let expected = p.duration
        let out = dir.appendingPathComponent("export_test.mp4")
        let t0 = Date()
        try await Exporter.export(project: p, format: .mp4H264, size: CGSize(width: 1280, height: 720), burnCaptions: true, to: out, cancel: Exporter.Box()) { _ in }
        let outAsset = AVURLAsset(url: out)
        let outDur = try await outAsset.load(.duration).seconds
        let outV = try await outAsset.loadTracks(withMediaType: .video)
        let outA = try await outAsset.loadTracks(withMediaType: .audio)
        check(abs(outDur - expected) < 0.15, String(format: "내보내기 길이 %.2f초 (예상 %.2f초), %.1f초 소요", outDur, expected, Date().timeIntervalSince(t0)))
        check(!outV.isEmpty && !outA.isEmpty, "내보낸 파일에 영상·오디오 트랙 존재")
        if let vt = outV.first {
            let size = try await vt.load(.naturalSize)
            check(size == CGSize(width: 1280, height: 720), "출력 해상도 \(Int(size.width))x\(Int(size.height))")
        }
        // 확인용 프레임 추출
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for t in [1.5, max(0.1, p.captions.first.map { ($0.start + $0.end) / 2 } ?? 1)] {
            let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let png = dir.appendingPathComponent(String(format: "frame_%.1f.png", t))
            if let d = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
            }
            print("  프레임 저장: \(png.lastPathComponent)")
        }
        let m4a = dir.appendingPathComponent("export_test.m4a")
        try await Exporter.export(project: p, format: .m4a, size: .zero, burnCaptions: false, to: m4a, cancel: Exporter.Box()) { _ in }
        let m4aDur = try await AVURLAsset(url: m4a).load(.duration).seconds
        check(abs(m4aDur - expected) < 0.3, String(format: "오디오만 내보내기 %.2f초", m4aDur))

        print("5-2) MKV·WebM 가져오기 (ffmpeg 변환)")
        if let ff = MediaConverter.ffmpeg {
            let srt = dir.appendingPathComponent("embed.srt")
            try "1\n00:00:00,500 --> 00:00:02,000\n<i>내장 자막</i> 테스트\n\n2\n00:00:06,000 --> 00:00:08,000\n두 번째 자막\n".write(to: srt, atomically: true, encoding: .utf8)
            let mkv = dir.appendingPathComponent("sample.mkv")
            let webm = dir.appendingPathComponent("sample.avi")
            func ffrun(_ a: [String]) throws {
                let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = ["-y", "-loglevel", "error"] + a
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 { throw MediaError.failed("테스트 파일 생성 실패") }
            }
            try ffrun(["-i", video.path, "-i", srt.path, "-map", "0:v", "-map", "0:a", "-map", "1:s", "-c:v", "copy", "-c:a", "flac", "-c:s", "srt", mkv.path])
            // 재인코딩 경로 검사용: MPEG-4 Part 2 + AC-3 (H.264가 아니므로 변환 필요)
            try ffrun(["-i", video.path, "-t", "4", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "ac3", webm.path])
            for f in [mkv, webm] {
                try? FileManager.default.removeItem(at: MediaConverter.cachedURL(for: f))
                let t0 = Date()
                let r = try await MediaConverter.convert(f) { _, _ in }
                let a = try await MediaProbe.probe(r.video)
                let expectDur = f == mkv ? v.duration : 4.0
                check(a.kind == .video && a.hasAudio && abs(a.duration - expectDur) < 0.2,
                      String(format: "%@ → MP4 %.1f초 (%d×%d, 오디오 %@), %.1f초 걸림", f.lastPathComponent, a.duration, Int(a.width), Int(a.height), a.hasAudio ? "있음" : "없음", Date().timeIntervalSince(t0)))
                if f == mkv {
                    check(r.subtitles.count == 2 && r.subtitles[0].text == "내장 자막 테스트", "MKV 내장 자막 \(r.subtitles.count)개 추출: \(r.subtitles.first?.text ?? "")")
                    let again = Date()
                    _ = try await MediaConverter.convert(f) { _, _ in }
                    check(Date().timeIntervalSince(again) < 1.0, "같은 파일 다시 가져오면 변환 결과 재사용")
                }
            }
        } else {
            print("  (ffmpeg 미설치 — 건너뜀)")
        }

        print("6) 프로젝트 저장/열기")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        check(back == p, "프로젝트 JSON 왕복 (\(data.count / 1024)KB)")

        print("7) 20배속 재생")
        let built = try await CompositionBuilder.build(project: p, renderSize: CGSize(width: 640, height: 360))
        let player = await AVPlayer()
        let item = await AVPlayerItem(asset: built.composition)
        await MainActor.run {
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
        }
        for _ in 0..<50 where await item.status != .readyToPlay { try await Task.sleep(nanoseconds: 100_000_000) }
        let ff = await item.canPlayFastForward
        await MainActor.run { player.rate = 20 }
        let r0 = await player.currentTime().seconds
        try await Task.sleep(nanoseconds: 400_000_000)
        let rate = await player.rate
        let r1 = await player.currentTime().seconds
        await MainActor.run { player.pause() }
        print(String(format: "  canPlayFastForward=%@ rate=%.1f, 0.4초 동안 %.2f초 진행", ff ? "예" : "아니오", rate, r1 - r0))
        check((r1 - r0) > 3.0 || !ff, "20배속 재생 진행 (터보 모드 대체 가능)")

        print("8) 재생 소리 (실제 재생 중 오디오 신호 측정)")
        for sp: Float in [1, 2, 4, 8, 20] {
            let peak = try await AudioProbe.measure(built: built, rate: sp, seconds: sp >= 4 ? 0.5 : 1.0)
            print(String(format: "  %gx: 최대 음량 %.3f", sp, peak))
            if sp <= 2 { check(peak > 0.01, "\(Int(sp))배속 재생 시 소리 나옴") }
        }
    }

    static func testTimelineOps() {
        var p = Project()
        let a = MediaAsset(path: "/tmp/x.mp4", name: "x", kind: .video, duration: 10, width: 1920, height: 1080, hasAudio: true)
        p.assets = [a]
        let id = p.insert(asset: a, track: 0, at: 0)
        check(p.duration == 10, "클립 추가: 10초")
        let right = p.split(clip: id, at: 4)
        check(p.tracks[0].clips.count == 2 && p.clip(right!)!.sourceIn == 4, "분할: 4초에서 둘로")
        p.delete(clips: [id], ripple: true)
        check(abs(p.duration - 6) < 1e-9 && p.tracks[0].clips[0].start == 0, "리플 삭제: 뒤 클립이 당겨짐")
        p.setSpeed(clip: right!, 2)
        check(abs(p.duration - 3) < 1e-9, "2배속: 6초 → 3초")
        p.setSpeed(clip: right!, 20)
        check(abs(p.duration - 0.3) < 1e-9, "20배속: 6초 → 0.3초")
        p.setSpeed(clip: right!, 1)
        p.rippleDelete(from: 1, to: 2)
        check(abs(p.duration - 5) < 1e-9 && p.tracks[0].clips.count == 2, "구간 리플 삭제 1~2초")
        let second = p.tracks[0].clips[1]
        check(abs(second.start - 1) < 1e-9 && abs(second.sourceIn - 6) < 1e-9, "구간 삭제 후 원본 위치 유지")
        p.trimEnd(clip: second.id, to: 3, maxSource: 10)
        check(abs(p.duration - 3) < 1e-9, "끝 트림")
        let b = p.insert(asset: a, track: 0, at: 1.5)
        check(p.clip(b)!.start >= 1.5 && p.tracks[0].clips.count == 3, "겹침 해결: 겹친 클립 밀어내기")
        // 영어 번역
        check(Loc.translate("3개 파일을 가져왔습니다", force: true) == "Imported 3 file(s)", "영어: 값이 든 문장")
        check(Loc.translate("음성 인식 중… (2/5) · 남은 시간 약 1:20", force: true) == "Recognizing speech… (2/5) · about 1:20 left", "영어: 겹친 문장")
        check(Loc.translateKey("%lld개 클립 선택됨") == "%lld clips selected", "영어: SwiftUI 키")
        check(Loc.translate("트랙 2", force: true) == "Track 2" && Loc.translate("무음 제거", force: true) == "Remove silences", "영어: 트랙 이름·도구")
        check(Loc.translate("영상이름.mp4", force: true) == "영상이름.mp4", "영어: 모르는 문장은 그대로")
        // 화면 효과
        let base = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let circ = Effects.shape(base, .circle)
        check(circ.extent.size == CGSize(width: 720, height: 720), "모양: 원은 가운데 정사각형")
        check(Effects.shape(base, .rounded).extent == base.extent, "모양: 둥근 사각형은 크기 유지")
        let clicked = Effects.clicks(base, marks: [ClickMark(t: 1, x: 0.5, y: 0.5)], sourceTime: 1.2)
        check(clicked.extent == base.extent, "클릭 강조: 크기 유지")
        check(Effects.personBackground(base, effect: .blur).extent == base.extent, "인물 배경 흐림: 사람 없어도 안전")
        // 그룹 · 합치기
        var g = Project()
        g.assets = [a]
        let g1 = g.insert(asset: a, track: 0, at: 0)
        let g2 = g.split(clip: g1, at: 3)!
        let g3 = g.split(clip: g2, at: 6)!
        g.move(clip: g3, toTrack: 0, start: 8)            // 6~10초 조각을 8초로 (2초 빈틈)
        g.join([g1, g2, g3])
        check(g.tracks[0].clips.count == 1 && abs(g.duration - 10) < 1e-9 && g.tracks[0].clips[0].sourceOut == 10,
              "합치기: 잘린 조각 3개 → 원래 한 클립 (빈틈 제거)")
        let b1 = g.insert(asset: a, track: 1, at: 0)
        let b2 = g.insert(asset: a, track: 1, at: 12)
        g.setSpeed(clip: b2, 2)
        g.join([b1, b2])
        let t1 = g.tracks[1].clips
        check(t1.count == 2 && abs(t1[1].start - 10) < 1e-9 && t1[0].groupID != nil && t1[0].groupID == t1[1].groupID,
              "합치기: 다른 클립은 빈틈 없이 붙이고 그룹으로")
        check(g.groupMembers(of: [b1]) == [b1, b2], "그룹: 하나를 고르면 함께 선택")
        g.ungroup([b1])
        check(g.groupMembers(of: [b1]) == [b1], "그룹 해제")
        var q = Project()
        q.captions = [Caption(start: 0, end: 2, text: "a"), Caption(start: 3, end: 5, text: "b"), Caption(start: 6, end: 8, text: "c")]
        q.rippleDelete(from: 4, to: 7)
        check(q.captions.count == 3 && abs(q.captions[1].end - 4) < 1e-9 && abs(q.captions[2].start - 4) < 1e-9 && abs(q.captions[2].end - 5) < 1e-9, "자막도 함께 잘림")

        // 자막 구간째 순서 바꾸기 / 삭제
        var v = Project()
        v.assets = [a]
        v.insert(asset: a, track: 0, at: 0)
        v.captions = [Caption(start: 0, end: 2, text: "A"), Caption(start: 2.2, end: 5, text: "B"), Caption(start: 5.5, end: 9, text: "C")]
        let cID = v.captions[2].id
        if let sp = v.span(ofCaption: cID) { v.moveRange(from: sp.lowerBound, to: sp.upperBound, insertAt: 0) }
        check(v.captions.map(\.text) == ["C", "A", "B"] && abs(v.duration - 10) < 1e-6 && abs(v.tracks[0].clips[0].sourceIn - 5.5) < 1e-6,
              "자막 C를 맨 앞으로 → 영상도 C 구간(5.5초~)부터 시작, 길이 그대로")
        var w = Project()
        w.assets = [a]
        w.insert(asset: a, track: 0, at: 0)
        w.captions = [Caption(start: 0, end: 2, text: "A"), Caption(start: 2.2, end: 5, text: "B"), Caption(start: 5.5, end: 9, text: "C")]
        let bSpan = w.span(ofCaption: w.captions[1].id)!
        w.captions.removeAll { $0.text == "B" }
        w.rippleDelete(ranges: [bSpan])
        check(abs(w.duration - (10 - 3.3)) < 1e-6 && w.captions.map(\.text) == ["A", "C"] && abs(w.captions[1].start - 2.2) < 1e-6,
              "자막 B 삭제 → 영상 3.3초 함께 삭제, 뒤 자막 당겨짐")
        var r = Project()
        r.assets = [a]
        let r1 = r.insert(asset: a, track: 0, at: 0)
        _ = r.split(clip: r1, at: 4)
        let first = r.tracks[0].clips[0].id
        r.reorder(clip: first, pointer: 9)
        check(abs(r.tracks[0].clips[0].sourceIn - 4) < 1e-6 && abs(r.tracks[0].clips[1].start - 6) < 1e-6 && abs(r.duration - 10) < 1e-6,
              "트랙 1 클립 끌어서 순서 바꾸기 (앞 조각을 뒤로)")
    }

    static func makeTestImage(to url: URL) throws {
        let w = 400, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 360))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 120, y: 220, width: 50, height: 70))
        ctx.fillEllipse(in: CGRect(x: 230, y: 220, width: 50, height: 70))
        ctx.fill(CGRect(x: 120, y: 110, width: 160, height: 30))
        let img = ctx.makeImage()!
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    /// 프레임 번호가 찍힌 테스트 영상 + 음성
    static func makeTestVideo(audio: URL, to url: URL) async throws {
        let audioAsset = AVURLAsset(url: audio)
        let dur = try await audioAsset.load(.duration).seconds
        let silent = AppPaths.temp.appendingPathComponent("silent_\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let w = 1280, h = 720
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(dur * 30) + 1
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let hue = CGFloat(i % 300) / 300
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.45, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: CGFloat(i * 8 % w), y: 0, width: 40, height: CGFloat(h)))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let s = String(format: "%.2f초", Double(i) / 30) as NSString
            s.draw(at: NSPoint(x: 60, y: 300), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 110, weight: .bold), .foregroundColor: NSColor.white])
            NSGraphicsContext.current = nil
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()

        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: silent)
        let vSrc = try await vAsset.loadTracks(withMediaType: .video)[0]
        let aSrc = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: dur, preferredTimescale: 600))
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vSrc, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: aSrc, at: .zero)
        let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        ex.outputURL = url
        ex.outputFileType = .mp4
        await withCheckedContinuation { c in ex.exportAsynchronously { c.resume() } }
        try? FileManager.default.removeItem(at: silent)
        if ex.status != .completed { throw MediaError.failed("테스트 영상 생성 실패: \(ex.error?.localizedDescription ?? "")") }
    }
}

import MediaToolbox

/// 재생 중인 오디오를 탭으로 잡아 최대 음량 측정 (진단용)
enum AudioProbe {
    final class Box: @unchecked Sendable { var peak: Float = 0 }

    static func measure(built: BuiltComposition, rate: Float, seconds: Double, at start: Double = 0.3) async throws -> Float {
        let box = Box()
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        for p in built.audioMix.inputParameters {
            guard let mp = p.mutableCopy() as? AVMutableAudioMixInputParameters else { continue }
            var cb = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque()),
                init: { _, info, storage in storage.pointee = info },
                finalize: nil, prepare: nil, unprepare: nil,
                process: { tap, frames, _, abl, framesOut, flagsOut in
                    guard MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, nil, framesOut) == noErr else { return }
                    let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    for buf in UnsafeMutableAudioBufferListPointer(abl) {
                        guard let d = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let n = Int(buf.mDataByteSize) / 4
                        for i in 0..<n { b.peak = max(b.peak, abs(d[i])) }
                    }
                })
            var tap: Unmanaged<MTAudioProcessingTap>?
            if MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr {
                mp.audioTapProcessor = tap?.takeRetainedValue()
            }
            params.append(mp)
        }
        mix.inputParameters = params
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.volume = 0 // 스피커로는 내보내지 않음
        player.automaticallyWaitsToMinimizeStalling = false
        for _ in 0..<50 where item.status != .readyToPlay { try await Task.sleep(nanoseconds: 100_000_000) }
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = rate
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        player.pause()
        return box.peak
    }
}
