import AVFoundation
import CryptoKit

/// MKV·WebM·AVI 등 macOS가 직접 못 읽는 영상을 ffmpeg로 MP4로 바꿔 가져온다.
/// H.264/HEVC 영상은 재인코딩 없이 포장만 바꾸므로 빠르고 화질 손실이 없다.
enum MediaConverter {
    static let convertibleExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "mts", "m2ts", "ogv", "mpg", "mpeg", "vob", "3gp", "divx", "f4v", "rmvb"]

    static var ffmpeg: String? { tool("ffmpeg") }
    static var ffprobe: String? { tool("ffprobe") }

    private static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var cacheDir: URL {
        let d = AppPaths.support.appendingPathComponent("converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func needsConversion(_ url: URL) -> Bool {
        convertibleExtensions.contains(url.pathExtension.lowercased())
    }

    /// 받은 MP4가 VP9/AV1처럼 macOS 편집에 맞지 않는 코덱인지
    static func needsTranscode(_ url: URL) -> Bool {
        guard let ffprobe, let info = try? probe(ffprobe, url) else { return false }
        guard let v = info.videoCodec else { return false }
        return !["h264", "hevc", "prores"].contains(v)
    }

    struct Result {
        let video: URL
        let subtitles: [Caption]
    }

    /// 변환 결과 파일 (원본 경로·크기·수정 시각이 같으면 다시 쓰기)
    static func cachedURL(for url: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attrs?[.size] as? Int) ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = url.deletingPathExtension().lastPathComponent
        return cacheDir.appendingPathComponent("\(base)-\(hash).mp4")
    }

    static func convert(_ url: URL, progress: @escaping (Double, String) -> Void) async throws -> Result {
        guard let ffmpeg, let ffprobe else {
            throw MediaError.failed("\(url.pathExtension.uppercased()) 파일을 열려면 ffmpeg가 필요합니다.\n터미널에서 'brew install ffmpeg'를 실행한 뒤 다시 가져오세요.")
        }
        let info = try probe(ffprobe, url)
        let out = cachedURL(for: url)
        let srt = out.deletingPathExtension().appendingPathExtension("srt")
        if !FileManager.default.fileExists(atPath: out.path) {
            let tmp = out.deletingPathExtension().appendingPathExtension("part.mp4")
            try? FileManager.default.removeItem(at: tmp)
            var video: [String]
            switch info.videoCodec {
            case "h264": video = ["-c:v", "copy"]
            case "hevc": video = ["-c:v", "copy", "-tag:v", "hvc1"]
            case nil: video = []
            default: video = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
            }
            let audio = info.hasAudio ? ["-c:a", "aac", "-b:a", "192k", "-ac", "2"] : []
            let maps = ["-map", "0:v:0?", "-map", "0:a:0?"]
            progress(0, video.contains("copy") ? "포장 변환 중…" : "영상 변환 중…")
            do {
                try await run(ffmpeg, ["-y", "-i", url.path] + maps + video + audio + ["-sn", "-dn", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", tmp.path],
                              duration: info.duration, progress: progress)
            } catch where video.contains("h264_videotoolbox") {
                // 하드웨어 인코더가 안 되면 소프트웨어 인코더로 다시
                progress(0, "영상 변환 중 (소프트웨어)…")
                try await run(ffmpeg, ["-y", "-i", url.path] + maps + ["-c:v", "libx264", "-crf", "18", "-preset", "veryfast", "-pix_fmt", "yuv420p"] + audio
                              + ["-sn", "-dn", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", tmp.path],
                              duration: info.duration, progress: progress)
            }
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
            // 안에 든 첫 텍스트 자막도 꺼내 둔다
            if info.hasTextSubtitle {
                try? await run(ffmpeg, ["-y", "-i", url.path, "-map", "0:s:0", "-c:s", "srt", srt.path], duration: 0, progress: { _, _ in })
            }
        }
        var caps: [Caption] = []
        if let text = try? String(contentsOf: srt, encoding: .utf8) {
            caps = SRT.parse(text).map { var c = $0; c.text = stripTags(c.text); return c }
        }
        progress(1, "완료")
        return Result(video: out, subtitles: caps)
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }

    struct Info {
        var videoCodec: String?
        var hasAudio = false
        var hasTextSubtitle = false
        var duration: Double = 0
    }

    static func probe(_ ffprobe: String, _ url: URL) throws -> Info {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries", "stream=codec_type,codec_name:format=duration", "-of", "json", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaError.failed("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        var info = Info()
        let textSubs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]
        for s in obj["streams"] as? [[String: Any]] ?? [] {
            let type = s["codec_type"] as? String, name = s["codec_name"] as? String
            switch type {
            case "video" where info.videoCodec == nil && name != "mjpeg" && name != "png": info.videoCodec = name
            case "audio": info.hasAudio = true
            case "subtitle" where textSubs.contains(name ?? ""): info.hasTextSubtitle = true
            default: break
            }
        }
        info.duration = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        if info.videoCodec == nil && !info.hasAudio { throw MediaError.noTracks(url.lastPathComponent) }
        return info
    }

    /// ffmpeg 실행, -progress 출력으로 진행률 보고
    static func run(_ bin: String, _ args: [String], duration: Double, progress: @escaping (Double, String) -> Void) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        final class Box: @unchecked Sendable { var tail = Data() }
        let box = Box()
        out.fileHandleForReading.readabilityHandler = { h in
            guard duration > 0, let s = String(data: h.availableData, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                if let us = Double(line.split(separator: "=").last ?? "") {
                    progress(min(0.99, us / 1_000_000 / duration), "변환 중… \(Int(min(99, us / 10_000 / duration)))%")
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            box.tail.append(h.availableData)
            if box.tail.count > 4000 { box.tail = box.tail.suffix(2000) }
        }
        try p.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in c.resume() }
            }
        } onCancel: { p.terminate() }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else {
            throw MediaError.failed("변환 실패: \(String(decoding: box.tail, as: UTF8.self).suffix(300))")
        }
    }
}
