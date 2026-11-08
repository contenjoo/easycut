import AVFoundation
import CryptoKit

/// 목소리 선명하게(소음 줄이기) · 배경음악 자동 줄이기 · 음량 자동 맞추기
/// Windows `easycut_core::audio_polish`와 같은 규칙을 쓴다.
enum AudioPolish {
    /// 소음 줄이기 필터 (낮은 웅웅거림 제거 + 소음 추적 FFT 잡음 제거)
    static let denoiseFilter = "highpass=f=70,afftdn=nr=20:nf=-30:tn=1"
    /// 말소리가 나올 때 배경음악 배율 (약 -12 dB)
    static let duckLevel: Double = 0.25
    /// 배경음악이 줄고 다시 커지는 시간 (초)
    static let duckRamp: Double = 0.25
    /// 이보다 짧은 말 사이 공백은 하나로 이어 줄인 상태를 유지한다
    static let speechGap: Double = 0.8
    static let defaultLoudness: Double = -14

    /// ffmpeg 실행 (출력은 임시 파일로 받아 파이프가 차서 멈추는 일이 없다)
    static func run(_ bin: String, _ args: [String]) async -> (Int32, String) {
        await Task.detached {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("easycut-ff-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: log) }
            guard let h = try? FileHandle(forWritingTo: log) else { return (-1, "") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.standardOutput = h
            p.standardError = h
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            p.waitUntilExit()
            try? h.close()
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return (p.terminationStatus, text)
        }.value
    }

    // MARK: 소음 줄이기

    static var cacheDir: URL {
        let d = AppPaths.support.appendingPathComponent("denoised", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 원본 경로·크기·수정 시각·필터가 같으면 같은 캐시 파일
    static func denoisedURL(for asset: MediaAsset) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: asset.path)
        let key = "\(asset.path)|\((attrs?[.size] as? Int) ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(denoiseFilter)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(asset.url.deletingPathExtension().lastPathComponent)-\(hash).m4a")
    }

    static func cachedDenoised(_ asset: MediaAsset) -> URL? {
        let u = denoisedURL(for: asset)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 원본 소리 전체를 소음 줄인 파일로 만든다 (이미 있으면 그대로)
    @discardableResult
    static func ensureDenoised(_ asset: MediaAsset) async throws -> URL {
        if let u = cachedDenoised(asset) { return u }
        guard asset.hasAudio, !asset.isMissing else { throw MediaError.failed("소리가 있는 원본 파일이 필요합니다.") }
        guard let ffmpeg = Tools.find("ffmpeg") else { throw MediaError.failed("소음 줄이기에는 FFmpeg가 필요합니다.") }
        let out = denoisedURL(for: asset)
        let tmp = out.deletingPathExtension().appendingPathExtension("part.m4a")
        try? FileManager.default.removeItem(at: tmp)
        let (code, log) = await run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", asset.path,
                                                   "-vn", "-map", "0:a:0", "-af", denoiseFilter,
                                                   "-c:a", "aac", "-b:a", "192k", "-f", "mp4", tmp.path])
        guard code == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw MediaError.failed("소음 줄이기 실패: \(log.suffix(300))")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// 소음 줄이기를 켰지만 아직 파일이 없는 원본
    static func pendingDenoise(_ project: Project) -> [MediaAsset] {
        var seen = Set<UUID>()
        var out: [MediaAsset] = []
        for clip in project.tracks.flatMap(\.clips) where clip.denoise == true {
            guard let a = project.asset(clip.assetID), a.hasAudio, !a.isMissing, cachedDenoised(a) == nil,
                  seen.insert(a.id).inserted else { continue }
            out.append(a)
        }
        return out
    }

    // MARK: 배경음악 자동 줄이기

    /// 대본이 없는 오디오 파일 = 배경음악
    static func isMusic(_ asset: MediaAsset) -> Bool {
        asset.kind == .audio && (asset.words?.isEmpty ?? true)
    }

    /// 말소리 구간 (타임라인 초). 음소거 트랙과 배경음악의 단어는 빼고, 가까운 구간은 잇는다.
    static func speechRanges(_ project: Project) -> [ClosedRange<Double>] {
        var raw: [(Double, Double)] = []
        for w in project.timelineWords() {
            guard project.tracks.indices.contains(w.track), !project.tracks[w.track].muted,
                  let a = project.asset(w.assetID), !isMusic(a) else { continue }
            if let clip = project.tracks[w.track].clips.first(where: { $0.id == w.clipID }), clip.volume <= 0.001 { continue }
            raw.append((w.start, max(w.start, w.end)))
        }
        raw.sort { $0.0 < $1.0 }
        var out: [ClosedRange<Double>] = []
        for (s, e) in raw {
            if let last = out.last, s - last.upperBound <= speechGap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, e)
            } else {
                out.append(s...e)
            }
        }
        return out
    }

    /// 배경음악 배율 (말소리 구간에서 duckLevel, 앞뒤 duckRamp초 동안 부드럽게)
    static func duckFactor(at t: Double, speech: [ClosedRange<Double>]) -> Double {
        var f = 1.0
        for r in speech {
            if t < r.lowerBound - duckRamp { break }
            let g: Double
            if t < r.lowerBound { g = (r.lowerBound - t) / duckRamp }
            else if t <= r.upperBound { g = 0 }
            else if t < r.upperBound + duckRamp { g = (t - r.upperBound) / duckRamp }
            else { continue }
            f = min(f, duckLevel + (1 - duckLevel) * g)
        }
        return f
    }

    /// 클립 소리 크기 변화 지점 (페이드 × 자동 줄이기). 점 사이는 직선으로 이어진다.
    static func envelope(_ clip: Clip, speech: [ClosedRange<Double>]) -> [(t: Double, v: Double)] {
        let vol = min(clip.volume, 4)
        let fi = min(clip.fadeIn, clip.duration / 2), fo = min(clip.fadeOut, clip.duration / 2)
        var times: [Double] = [clip.start, clip.end]
        if fi > 0.01 { times.append(clip.start + fi) }
        if fo > 0.01 { times.append(clip.end - fo) }
        for r in speech where r.upperBound + duckRamp > clip.start && r.lowerBound - duckRamp < clip.end {
            times += [r.lowerBound - duckRamp, r.lowerBound, r.upperBound, r.upperBound + duckRamp]
        }
        let sorted = Array(Set(times.filter { $0 >= clip.start && $0 <= clip.end }.map { ($0 * 1000).rounded() / 1000 })).sorted()
        return sorted.map { t in
            var fade = 1.0
            if fi > 0.01, t < clip.start + fi { fade = (t - clip.start) / fi }
            if fo > 0.01, t > clip.end - fo { fade = min(fade, (clip.end - t) / fo) }
            return (t, vol * max(0, fade) * duckFactor(at: t, speech: speech))
        }
    }

    // MARK: 음량 자동 맞추기

    struct Measured { let i, tp, lra, thresh, offset: Double }

    static func parseLoudnorm(_ log: String) -> Measured? {
        guard let a = log.lastIndex(of: "{"), let b = log.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(log[a...b].utf8)) as? [String: Any] else { return nil }
        func v(_ k: String) -> Double? { (obj[k] as? String).flatMap(Double.init) }
        guard let i = v("input_i"), let tp = v("input_tp"), let lra = v("input_lra"), let th = v("input_thresh"),
              let off = v("target_offset"), i.isFinite else { return nil }
        return Measured(i: i, tp: tp, lra: lra, thresh: th, offset: off)
    }

    /// 내보낸 파일의 소리를 목표 LUFS로 맞춘다 (2단계 loudnorm, 영상은 그대로 복사)
    static func normalize(_ url: URL, target: Double) async throws {
        guard let ffmpeg = Tools.find("ffmpeg") else { throw MediaError.failed("음량 맞추기에는 FFmpeg가 필요합니다.") }
        let base = "I=\(target):TP=-1.5:LRA=11"
        let (c1, log1) = await run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", url.path, "-vn",
                                                  "-af", "loudnorm=\(base):print_format=json", "-f", "null", "-"])
        guard c1 == 0, let m = parseLoudnorm(log1) else { throw MediaError.failed("음량을 재지 못했습니다.") }
        // 소리가 거의 없으면 키우지 않는다
        guard m.i > -70 else { return }
        let ext = url.pathExtension.lowercased()
        let codec: [String] = ext == "mov" ? ["-c:a", "pcm_s16le"] : ["-c:a", "aac", "-b:a", "192k"]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-loud.\(ext)")
        try? FileManager.default.removeItem(at: tmp)
        let filter = "loudnorm=\(base):measured_I=\(m.i):measured_TP=\(m.tp):measured_LRA=\(m.lra):measured_thresh=\(m.thresh):offset=\(m.offset):linear=true,aresample=48000"
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-map", "0", "-c", "copy"]
        args += ["-af", filter] + codec
        if ext == "mp4" || ext == "m4a" || ext == "mov" { args += ["-movflags", "+faststart"] }
        args.append(tmp.path)
        let (c2, log2) = await run(ffmpeg, args)
        guard c2 == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw MediaError.failed("음량 맞추기 실패: \(log2.suffix(300))")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// 파일의 통합 음량 (LUFS)
    static func measure(_ url: URL) async -> Double? {
        guard let ffmpeg = Tools.find("ffmpeg") else { return nil }
        let (c, log) = await run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", url.path, "-vn",
                                                "-af", "loudnorm=print_format=json", "-f", "null", "-"])
        return c == 0 ? parseLoudnorm(log)?.i : nil
    }
}
