import Foundation

/// 유튜브 등 영상 링크에서 내려받기 (yt-dlp 사용).
enum LinkImporter {
    enum Quality: String, CaseIterable, Identifiable {
        case p720 = "720p"
        case p1080 = "1080p"
        case best = "최고 화질"
        case audio = "소리만 (M4A)"
        var id: String { rawValue }
    }

    struct Options {
        var quality: Quality = .p1080
        /// 받을 구간 (초). nil이면 전체
        var start: Double?
        var end: Double?
        var subtitles = true
        var subLangs = "ko.*,en.*"
    }

    struct Result {
        let file: URL
        let title: String
        let subtitles: [Caption]
    }

    static var ytdlp: String? { Tools.find("yt-dlp") }

    static var downloadDir: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("EasyCut 다운로드", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func isLink(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && u.host != nil
    }

    /// "1:30", "90", "1:02:03" → 초
    static func parseTime(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var total = 0.0
        for part in t.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func download(_ link: String, options: Options, progress: @escaping (Double, String) -> Void) async throws -> Result {
        guard let bin = ytdlp else {
            throw MediaError.failed("링크로 가져오려면 유튜브 도구(yt-dlp)가 필요합니다.\n링크 가져오기 창에서 [유튜브 도구 설치]를 눌러 주세요.")
        }
        let work = AppPaths.temp.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var args = [link.trimmingCharacters(in: .whitespacesAndNewlines), "--no-playlist", "--newline", "--no-colors",
                    "--no-mtime", "--windows-filenames",
                    "-P", work.path, "-o", "%(title).80B [%(id)s].%(ext)s",
                    "--progress-template", "download:EC %(progress._percent_str)s %(progress._eta_str)s",
                    "--print", "after_move:EC_FILE %(filepath)s",
                    "--print", "before_dl:EC_TITLE %(title)s"]
        if let ff = MediaConverter.ffmpeg { args += ["--ffmpeg-location", ff] }
        switch options.quality {
        case .audio:
            args += ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"]
        default:
            // 편집하기 좋은 H.264 + AAC를 우선으로
            let res = options.quality == .p720 ? "res:720," : (options.quality == .p1080 ? "res:1080," : "")
            args += ["-S", "\(res)vcodec:h264,acodec:m4a", "-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        }
        if options.start != nil || options.end != nil {
            let a = options.start ?? 0
            let b = options.end.map { String(format: "%.2f", $0) } ?? "inf"
            // 재압축 없이 원본 그대로 자른다 (경계는 가장 가까운 키프레임으로 1~2초 앞당겨질 수 있음)
            args += ["--download-sections", String(format: "*%.2f-%@", a, b)]
        }
        if options.subtitles && options.quality != .audio {
            args += ["--write-subs", "--sub-langs", options.subLangs, "--convert-subs", "srt"]
        }

        progress(0, "링크 확인 중…")
        args += ["--retries", "5", "--fragment-retries", "5"]
        var outcome: (status: Int32, file: String?, title: String, tail: String) = (1, nil, "", "")
        for attempt in 1...3 {
            if attempt > 1 { progress(0, "다시 시도하는 중… (\(attempt)/3)") }
            outcome = try await runOnce(bin: bin, args: args, work: work, progress: progress)
            if outcome.status == 0, outcome.file != nil { break }
            // 일시적인 차단(403)·네트워크 오류만 다시 시도
            let t = outcome.tail.lowercased()
            guard t.contains("403") || t.contains("code 8") || t.contains("timed out") || t.contains("connection") else { break }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
        }
        guard outcome.status == 0, let path = outcome.file, FileManager.default.fileExists(atPath: path) else {
            throw MediaError.failed("영상을 받지 못했습니다.\n" + friendlyError(outcome.tail))
        }
        let st = (title: outcome.title, file: path)

        // 받은 파일을 다운로드 폴더로 옮긴다 (같은 이름이 있으면 번호 붙이기)
        let src = URL(fileURLWithPath: path)
        var dest = downloadDir.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloadDir.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) (\(n)).\(src.pathExtension)")
            n += 1
        }
        try FileManager.default.moveItem(at: src, to: dest)

        // 업로더 자막 (첫 번째 것)
        var caps: [Caption] = []
        if let srt = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .filter({ $0.pathExtension.lowercased() == "srt" }).sorted(by: { a, b in
                // 한국어 자막 우선
                a.lastPathComponent.contains(".ko") && !b.lastPathComponent.contains(".ko")
            }).first,
           let text = try? String(contentsOf: srt, encoding: .utf8) {
            caps = SRT.parse(text).map { var c = $0; c.text = MediaConverter.stripTags(c.text); return c }
            try? FileManager.default.moveItem(at: srt, to: dest.deletingPathExtension().appendingPathExtension("srt"))
        }
        progress(1, "완료")
        return Result(file: dest, title: st.title, subtitles: caps)
    }

    /// yt-dlp 한 번 실행
    private static func runOnce(bin: String, args: [String], work: URL, progress: @escaping (Double, String) -> Void) async throws
        -> (status: Int32, file: String?, title: String, tail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        final class State: @unchecked Sendable {
            var file: String?
            var title = ""
            var tail = ""
            var buf = Data()
            var part = 0
        }
        let st = State()
        out.fileHandleForReading.readabilityHandler = { h in
            st.buf.append(h.availableData)
            while let nl = st.buf.firstIndex(of: 0x0A) {
                let line = String(decoding: st.buf[..<nl], as: UTF8.self)
                st.buf.removeSubrange(...nl)
                if line.hasPrefix("EC_FILE ") {
                    st.file = String(line.dropFirst(8))
                } else if line.hasPrefix("EC_TITLE ") {
                    st.title = String(line.dropFirst(9))
                    progress(0, "받는 중: \(st.title)")
                } else if line.hasPrefix("EC ") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2, let pct = Double(parts[1].replacingOccurrences(of: "%", with: "")) {
                        if pct < 1 && st.part == 0 { st.part = 1 }
                        let eta = parts.count >= 3 ? " · 남은 시간 \(parts[2])" : ""
                        progress(min(0.98, pct / 100), "받는 중 \(Int(pct))%\(eta)")
                    }
                } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[FixupM3u8]") {
                    progress(0.99, "합치는 중…")
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            st.tail = String((st.tail + String(decoding: h.availableData, as: UTF8.self)).suffix(1500))
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
        return (p.terminationStatus, st.file, st.title, st.tail)

    }

    static func friendlyError(_ tail: String) -> String {
        let l = tail.lowercased()
        if l.contains("403") || l.contains("forbidden") || l.contains("sign in to confirm you") && l.contains("bot") {
            return "사이트가 다운로드를 막았습니다. 유튜브 도구가 오래됐을 수 있어요. 링크 가져오기 창에서 [유튜브 도구 업데이트]를 눌러 주세요."
        }
        if l.contains("private video") { return "비공개 영상입니다." }
        if l.contains("sign in to confirm your age") || l.contains("age-restricted") { return "연령 제한 영상이라 받을 수 없습니다." }
        if l.contains("members-only") || l.contains("join this channel") { return "채널 회원 전용 영상입니다." }
        if l.contains("drm") { return "DRM으로 보호된 영상은 받을 수 없습니다." }
        if l.contains("unsupported url") { return "지원하지 않는 링크입니다." }
        if l.contains("unable to download") || l.contains("http error") || l.contains("timed out") { return "네트워크 오류입니다. 연결을 확인하고 다시 시도하세요." }
        if l.contains("unavailable") || l.contains("not available") { return "볼 수 없는 영상입니다. 주소가 맞는지, 삭제·비공개된 영상은 아닌지 확인하세요." }
        return tail.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? String(tail.suffix(300))
    }
}
