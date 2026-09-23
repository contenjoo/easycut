import AVFoundation
import Speech

enum STTEngine: String, CaseIterable, Identifiable, Codable {
    case apple = "Apple 내장 (설치 불필요)"
    case whisper = "Whisper (고정확도, 모델 필요)"
    var id: String { rawValue }
}

struct STTLanguage: Identifiable, Hashable {
    let id: String   // Apple 로케일
    let name: String
    var whisperCode: String { String(id.prefix(2)) }

    static let all: [STTLanguage] = [
        .init(id: "ko-KR", name: "한국어"),
        .init(id: "en-US", name: "영어"),
        .init(id: "ja-JP", name: "일본어"),
        .init(id: "zh-CN", name: "중국어"),
        .init(id: "es-ES", name: "스페인어"),
        .init(id: "fr-FR", name: "프랑스어"),
        .init(id: "de-DE", name: "독일어"),
    ]
}

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let title: String
    let sizeMB: Int
    var fileName: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var localURL: URL { AppPaths.models.appendingPathComponent(fileName) }
    var isInstalled: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0) > sizeMB * 1_000_000 / 2
    }

    static let all: [WhisperModel] = [
        .init(id: "large-v3-turbo-q5_0", title: "Large v3 Turbo (추천, 정확·빠름)", sizeMB: 574),
        .init(id: "small", title: "Small (가벼움)", sizeMB: 488),
        .init(id: "base", title: "Base (매우 가벼움, 정확도 낮음)", sizeMB: 148),
    ]
}

enum Transcriber {
    static let sampleRate = 16000

    // MARK: 오디오 추출

    /// 파일의 오디오를 16kHz 모노 16비트 PCM으로 읽는다
    static func pcm16k(url: URL) async throws -> [Int16] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MediaError.failed("오디오 트랙이 없습니다.") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw MediaError.failed("오디오 읽기 실패: \(reader.error?.localizedDescription ?? "")") }
        var samples: [Int16] = []
        let dur = try await asset.load(.duration).seconds
        if dur.isFinite { samples.reserveCapacity(Int(dur * Double(sampleRate)) + sampleRate) }
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let count = len / 2
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!.advanced(by: start * 2))
            }
        }
        if reader.status == .failed { throw MediaError.failed("오디오 읽기 실패: \(reader.error?.localizedDescription ?? "")") }
        return samples
    }

    static func writeWAV(_ s: ArraySlice<Int16>, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        s.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }

    /// 조용한 지점을 찾아 25~45초 단위로 자른다
    static func chunks(_ s: [Int16], minLen: Double = 25, maxLen: Double = 45) -> [Range<Int>] {
        let win = sampleRate / 10 // 0.1초
        let nWin = s.count / win
        guard nWin > 0 else { return s.isEmpty ? [] : [0..<s.count] }
        var energy = [Float](repeating: 0, count: nWin)
        s.withUnsafeBufferPointer { p in
            for w in 0..<nWin {
                var acc: Float = 0
                let base = w * win
                var i = 0
                while i < win { let v = Float(p[base + i]); acc += v * v; i += 4 }
                energy[w] = acc / Float(win / 4)
            }
        }
        var out: [Range<Int>] = []
        var startWin = 0
        let minW = Int(minLen * 10), maxW = Int(maxLen * 10)
        while startWin < nWin {
            if nWin - startWin <= maxW { out.append(startWin * win..<s.count); break }
            var best = startWin + minW, bestE = Float.greatestFiniteMagnitude
            for w in (startWin + minW)..<min(nWin, startWin + maxW) {
                // 3개 창(0.3초) 평균 에너지가 가장 낮은 곳
                let e = energy[w] + (w + 1 < nWin ? energy[w + 1] : 0) + (w > 0 ? energy[w - 1] : 0)
                if e < bestE { bestE = e; best = w }
            }
            out.append(startWin * win..<best * win)
            startWin = best
        }
        return out
    }

    static func rms(_ s: ArraySlice<Int16>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Double = 0
        var i = s.startIndex
        while i < s.endIndex { let v = Double(s[i]); acc += v * v; i += 8 }
        return Float((acc / Double(max(1, s.count / 8))).squareRoot())
    }

    // MARK: 인식

    static func transcribe(url: URL, engine: STTEngine, language: STTLanguage, whisperModel: WhisperModel?,
                           progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        progress(0, "오디오 추출 중…")
        let samples = try await pcm16k(url: url)
        guard !samples.isEmpty else { return [] }
        switch engine {
        case .apple:
            return try await transcribeApple(samples: samples, language: language, progress: progress)
        case .whisper:
            guard let model = whisperModel ?? WhisperModel.all.first(where: \.isInstalled) else {
                throw MediaError.failed("Whisper 모델이 없습니다. 설정에서 모델을 내려받아 주세요.")
            }
            return try await transcribeWhisper(samples: samples, language: language, model: model, progress: progress)
        }
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let s = SFSpeechRecognizer.authorizationStatus()
        if s != .notDetermined { return s }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }

    static func transcribeApple(samples: [Int16], language: STTLanguage, progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            throw MediaError.failed("음성 인식 권한이 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 음성 인식에서 EasyCut을 허용해 주세요.")
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: language.id)) else {
            throw MediaError.failed("\(language.name) 인식을 지원하지 않습니다.")
        }
        rec.defaultTaskHint = .dictation
        let parts = chunks(samples)
        let dir = AppPaths.temp.appendingPathComponent("stt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var words: [Word] = []
        for (i, r) in parts.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(parts.count), "음성 인식 중… (\(i + 1)/\(parts.count))")
            let slice = samples[r]
            if rms(slice) < 60 { continue } // 거의 무음
            let url = dir.appendingPathComponent("c\(i).wav")
            try writeWAV(slice, to: url)
            let offset = Double(r.lowerBound) / Double(sampleRate)
            let segs = try await recognizeApple(rec: rec, url: url)
            for s in segs {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // 문장 끝 단어는 뒤 무음까지 길게 잡히는 경우가 있어 글자 수에 맞게 길이를 제한
                let cap = 0.35 + Double(text.count) * 0.22
                words.append(Word(text: text, start: offset + s.start, end: offset + s.start + min(max(0.05, s.duration), cap)))
            }
        }
        progress(1, "완료")
        return fixOverlaps(words)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    typealias Seg = (text: String, start: Double, duration: Double)

    /// SFSpeech는 쉼이 있으면 결과를 여러 배치로 나눠 보내고, 마지막 결과에는 마지막 배치만 담긴다.
    /// 시간값이 채워진(확정된) 배치 결과를 모두 모아 합친다.
    final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[Seg]] = []

        func add(_ segs: [Seg]) {
            guard let first = segs.first, segs.contains(where: { $0.duration > 0 }) else { return }
            lock.lock(); defer { lock.unlock() }
            // 같은 배치의 새 버전: 시작 시간이 같고, 첫 글자가 같거나 단어가 늘어난 경우
            if let last = batches.last, let lf = last.first, abs(lf.start - first.start) < 0.02,
               lf.text.first == first.text.first || segs.count >= last.count {
                batches[batches.count - 1] = segs
                return
            }
            // 앞 배치보다 앞선 시간으로 온 결과는 아직 시간이 확정되지 않은 중간 결과이므로 버린다
            if let prevEnd = batches.last?.last.map({ $0.start + $0.duration }), first.start + 0.3 < prevEnd { return }
            batches.append(segs)
        }

        var all: [Seg] { lock.lock(); defer { lock.unlock() }; return batches.flatMap { $0 } }
    }

    static func recognizeApple(rec: SFSpeechRecognizer, url: URL) async throws -> [Seg] {
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        let once = Once()
        let collector = BatchCollector()
        final class TaskBox: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.task = rec.recognitionTask(with: req) { result, error in
                    if let result {
                        let segs = result.bestTranscription.segments.map { (text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                        collector.add(segs)
                        if result.isFinal {
                            guard once.claim() else { return }
                            cont.resume(returning: collector.all)
                        }
                    } else if let error {
                        guard once.claim() else { return }
                        let ns = error as NSError
                        // 말소리가 없는 구간 등은 지금까지 모은 결과로 처리
                        if ns.code == 1110 || ns.code == 203 || ns.code == 301 || ns.code == 216 {
                            cont.resume(returning: collector.all)
                        } else {
                            cont.resume(throwing: MediaError.failed("음성 인식 오류: \(ns.localizedDescription)"))
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    // MARK: Whisper

    static var whisperBinary: String? {
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func transcribeWhisper(samples: [Int16], language: STTLanguage, model: WhisperModel,
                                  progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        guard let bin = whisperBinary else {
            throw MediaError.failed("whisper-cli가 설치되어 있지 않습니다. 터미널에서 'brew install whisper-cpp'를 실행해 주세요.")
        }
        let dir = AppPaths.temp.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("audio.wav")
        try writeWAV(samples[...], to: wav)
        let outBase = dir.appendingPathComponent("out").path
        progress(0.02, "Whisper 인식 중…")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", model.localURL.path, "-f", wav.path, "-l", language.whisperCode,
                       "-ml", "1", "-sow", "-oj", "-of", outBase, "-pp",
                       "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        final class Tail: @unchecked Sendable { var text = "" }
        let tailBox = Tail()
        err.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            tailBox.text = String((tailBox.text + s).suffix(2000))
            if let r = s.range(of: #"progress =\s*(\d+)%"#, options: .regularExpression) {
                let num = s[r].filter(\.isNumber)
                if let v = Double(num) { progress(min(0.99, v / 100), "Whisper 인식 중… \(Int(v))%") }
            }
        }
        try p.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in c.resume() }
            }
        } onCancel: {
            p.terminate()
        }
        err.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else {
            throw MediaError.failed("Whisper 실행 실패 (코드 \(p.terminationStatus))\n\(tailBox.text.suffix(400))")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: outBase + ".json"))
        progress(1, "완료")
        return fixOverlaps(parseWhisperJSON(data))
    }

    static func parseWhisperJSON(_ data: Data) -> [Word] {
        // whisper.cpp 출력에 잘못된 UTF-8이 섞일 수 있어 느슨하게 디코딩
        let text = String(decoding: data, as: UTF8.self)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let segs = obj["transcription"] as? [[String: Any]] else { return [] }
        var words: [Word] = []
        for s in segs {
            guard let off = s["offsets"] as? [String: Any],
                  let from = (off["from"] as? NSNumber)?.doubleValue,
                  let to = (off["to"] as? NSNumber)?.doubleValue else { continue }
            let t = ((s["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("[") else { continue }
            // 공백 없이 붙어 나온 조각은 이전 단어에 이어 붙인다
            let raw = (s["text"] as? String) ?? ""
            if let last = words.last, !raw.hasPrefix(" "), from / 1000 - last.end < 0.3, !words.isEmpty {
                words[words.count - 1].text += t
                words[words.count - 1].end = to / 1000
            } else {
                words.append(Word(text: t, start: from / 1000, end: max(from, to) / 1000))
            }
        }
        return words
    }

    static func fixOverlaps(_ w: [Word]) -> [Word] {
        var out = w.sorted { $0.start < $1.start }
        for i in out.indices {
            if out[i].end <= out[i].start { out[i].end = out[i].start + 0.05 }
            if i + 1 < out.count, out[i].end > out[i + 1].start { out[i].end = max(out[i].start + 0.02, out[i + 1].start) }
        }
        return out
    }
}

/// Whisper 모델 내려받기
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var downloading: WhisperModel?
    @Published var error: String?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?

    @MainActor
    func download(_ model: WhisperModel) async {
        guard downloading == nil else { return }
        downloading = model
        progress = 0
        error = nil
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                s.downloadTask(with: model.url).resume()
            }
        } catch {
            self.error = "모델 다운로드 실패: \(error.localizedDescription)"
        }
        s.finishTasksAndInvalidate()
        downloading = nil
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = DispatchQueue.main.sync { downloading?.localURL }
        guard let dest else { return }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw MediaError.failed("HTTP \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
