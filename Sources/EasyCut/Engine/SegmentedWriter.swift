import AVFoundation

/// 녹화 파일 하나를 일정 길이(기본 30초)마다 끊어, 구간마다 정상 마감된 파일로 쓴다.
///
/// 일반 mp4는 목차(moov)를 마지막에 한 번만 쓰므로 앱이 강제 종료되면 녹화 전체를 재생할 수 없다.
/// movieFragmentInterval(조각 쓰기)은 실시간 녹화에서 -11800(-16341)으로 중간에 끊겨 쓰지 않는다.
/// 대신 구간마다 AVAssetWriter를 새로 열고 닫아, 강제 종료돼도 마감된 구간은 그대로 남게 한다.
/// 정지하면 구간들을 재인코딩 없이 원래 파일 이름 하나로 잇고, 강제 종료로 남은 구간은 다음 실행 때 잇는다.
///
/// 구간 파일은 최종 파일 옆 숨김 폴더 `.<파일 이름>.parts`에 `part-00000.mp4` 식으로 쌓인다.
/// 녹화 중에는 폴더 안 `lock`을 flock으로 쥐고 있어서(강제 종료되면 OS가 풀어 줌) 다른 실행이 건드리지 않는다.
///
/// `append`·`tick`·`close`·`abandon`·`cancelOpen`은 녹화 큐에서만 부른다.
final class SegmentedWriter {
    struct Track {
        let mediaType: AVMediaType
        let settings: [String: Any]
    }

    enum AppendResult { case appended, dropped, failed }

    /// 재생할 수 있는 구간이 하나도 없음 (강제 종료 때 쓰던 첫 구간뿐인 경우 등)
    struct NoUsableParts: LocalizedError {
        var errorDescription: String? { L("이어 붙일 녹화 구간이 없습니다.") }
    }

    static let defaultPartLength = 30.0
    /// 구간이 끝난 뒤에도 늦게 도착하는 버퍼(마이크·카메라 지연)를 받으려고 열어 두는 시간
    static let grace = 2.0

    let finalURL: URL
    let fileType: AVFileType
    let partsDir: URL
    let length: Double
    private let tracks: [Track]
    private let origin: CMTime
    private var open: [Int: Part] = [:]
    private var closedThrough = -1
    /// 영상 트랙의 직전 프레임. 화면이 그대로면 새 프레임이 오지 않으므로 새 구간 첫머리에 다시 넣는다.
    private var lastFrame: [Int: CMSampleBuffer] = [:]
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var writeError: Error?
    private var lockFD: Int32 = -1

    private final class Part {
        let index: Int
        let writer: AVAssetWriter
        let inputs: [AVAssetWriterInput]
        var samples = 0
        init(index: Int, writer: AVAssetWriter, inputs: [AVAssetWriterInput]) {
            self.index = index; self.writer = writer; self.inputs = inputs
        }
    }

    private struct Manifest: Codable {
        var final: String
        var fileType: String
        var length: Double
    }

    static func partsDir(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.lastPathComponent).parts", isDirectory: true)
    }

    init(finalURL: URL, fileType: AVFileType, tracks: [Track], origin: CMTime, length: Double = defaultPartLength) throws {
        self.finalURL = finalURL
        self.fileType = fileType
        self.tracks = tracks
        self.origin = origin
        self.length = length
        partsDir = Self.partsDir(for: finalURL)
        let fm = FileManager.default
        try? fm.removeItem(at: partsDir)
        try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
        let manifest = Manifest(final: finalURL.lastPathComponent, fileType: fileType.rawValue, length: length)
        try JSONEncoder().encode(manifest).write(to: partsDir.appendingPathComponent("parts.json"), options: .atomic)
        let fd = Darwin.open(partsDir.appendingPathComponent("lock").path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 { lockFD = fd } else if fd >= 0 { Darwin.close(fd) }
    }

    deinit { releaseLock() }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        Darwin.close(lockFD)
        lockFD = -1
    }

    var error: Error? { lock.lock(); defer { lock.unlock() }; return writeError }

    private func record(_ e: Error?) {
        lock.lock(); defer { lock.unlock() }
        if writeError == nil { writeError = e ?? MediaError.failed("녹화 구간을 저장하지 못했습니다.") }
    }

    private func boundary(_ k: Int) -> CMTime {
        origin + CMTime(value: Int64(k) * Int64(length * 1000), timescale: 1000)
    }

    private func index(_ t: CMTime) -> Int {
        max(0, Int(floor((t - origin).seconds / length)))
    }

    private func partURL(_ k: Int) -> URL {
        partsDir.appendingPathComponent(String(format: "part-%05d.", k) + finalURL.pathExtension)
    }

    /// 구간 k의 writer. 이미 닫힌 구간이면 nil (너무 늦게 온 버퍼는 버린다)
    private func part(_ k: Int) -> Part? {
        if let p = open[k] { return p }
        guard k > closedThrough, error == nil else { return nil }
        let url = partURL(k)
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: fileType) else {
            record(MediaError.failed("녹화 구간 파일을 만들지 못했습니다."))
            return nil
        }
        let inputs = tracks.map { t -> AVAssetWriterInput in
            let i = AVAssetWriterInput(mediaType: t.mediaType, outputSettings: t.settings)
            i.expectsMediaDataInRealTime = true
            w.add(i)
            return i
        }
        guard w.startWriting() else { record(w.error); return nil }
        let start = boundary(k)
        w.startSession(atSourceTime: start)
        let p = Part(index: k, writer: w, inputs: inputs)
        open[k] = p
        // 화면이 멈춰 있어도 새 구간이 검은 화면으로 시작하지 않게 직전 프레임을 구간 첫머리에 다시 넣는다
        for (i, sb) in lastFrame where sb.presentationTimeStamp < start {
            if let seed = Self.retimed(sb, to: start), inputs[i].isReadyForMoreMediaData, inputs[i].append(seed) { p.samples += 1 }
        }
        return p
    }

    func append(_ sb: CMSampleBuffer, track i: Int) -> AppendResult {
        let pts = sb.presentationTimeStamp
        guard pts.isValid else { return .dropped }
        let k = index(pts)
        guard let p = part(k) else { return error == nil ? .dropped : .failed }
        let input = p.inputs[i]
        guard input.isReadyForMoreMediaData else { return .dropped }
        guard input.append(sb) else { record(p.writer.error); return .failed }
        p.samples += 1
        if tracks[i].mediaType == .video {
            lastFrame[i] = sb
        } else if sb.duration.isValid, pts + sb.duration > boundary(k + 1), let next = part(k + 1) {
            // 경계에 걸친 소리 버퍼는 다음 구간에도 넣는다 (구간 시작 전 부분은 잘려 이음매에 빈틈이 생기지 않음)
            let ni = next.inputs[i]
            if ni.isReadyForMoreMediaData, ni.append(sb) { next.samples += 1 }
        }
        return .appended
    }

    /// 1초마다 녹화 큐에서 부른다. `now`는 녹화 파일 기준 시각(일시정지 시간을 뺀 호스트 시각).
    func tick(now: CMTime) {
        for k in open.keys.sorted() where boundary(k + 1) + CMTime(seconds: Self.grace, preferredTimescale: 600) <= now {
            close(k, at: boundary(k + 1))
        }
        // 화면이 오래 그대로여도 지금 구간이 생겨 있도록 (직전 프레임으로 시작)
        if !lastFrame.isEmpty { _ = part(index(now)) }
    }

    private func close(_ k: Int, at end: CMTime) {
        guard let p = open.removeValue(forKey: k) else { return }
        closedThrough = max(closedThrough, k)
        guard p.samples > 0, p.writer.status == .writing else {
            if p.writer.status == .writing { p.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: p.writer.outputURL)
            return
        }
        p.inputs.forEach { $0.markAsFinished() }
        p.writer.endSession(atSourceTime: end)
        group.enter()
        p.writer.finishWriting { [self] in
            if p.writer.status != .completed { record(p.writer.error) }
            group.leave()
        }
    }

    /// 녹화를 `end`에서 끝낸다. 그 뒤에 시작한 구간은 버린다.
    func close(at end: CMTime) {
        for k in open.keys.sorted() {
            if boundary(k) >= end {
                guard let p = open.removeValue(forKey: k) else { continue }
                p.writer.cancelWriting()
                try? FileManager.default.removeItem(at: p.writer.outputURL)
            } else {
                close(k, at: min(boundary(k + 1), end))
            }
        }
        closedThrough = Int.max
    }

    /// 쓸모없는 녹화(프레임·소리가 하나도 없음): 구간 폴더째 지운다
    func abandon() {
        for p in open.values where p.writer.status == .writing { p.writer.cancelWriting() }
        open.removeAll()
        closedThrough = Int.max
        releaseLock()
        try? FileManager.default.removeItem(at: partsDir)
    }

    /// 실패·취소: 열린 구간만 버리고, 마감된 구간은 다음 실행에서 복구하도록 남긴다
    func cancelOpen() {
        for p in open.values where p.writer.status == .writing { p.writer.cancelWriting() }
        open.removeAll()
        closedThrough = Int.max
        releaseLock()
    }

    /// `close(at:)` 뒤에 부른다. 구간 마감을 기다려 최종 파일 하나로 잇는다.
    /// 실패하면 구간 폴더를 남겨 두므로 다음 실행에서 다시 잇는다.
    func finish() async throws -> URL {
        await withCheckedContinuation { c in group.notify(queue: .global()) { c.resume() } }
        do {
            _ = try await Self.merge(dir: partsDir, length: length, fileType: fileType, into: finalURL)
        } catch {
            releaseLock()
            throw error
        }
        releaseLock()
        try? FileManager.default.removeItem(at: partsDir)
        return finalURL
    }

    // MARK: 잇기·복구

    /// 구간 파일들을 시각 순서대로 이어 `url`에 쓴다. 재생할 수 없는 구간(강제 종료 때 쓰던 것)은 건너뛴다.
    /// 영상은 재인코딩 없이 옮기고, 소리는 구간마다 다시 시작한 AAC의 이음매가 남지 않도록 한 번 풀어 다시 압축한다.
    /// AVMutableComposition으로 내보내면 편집 목록(edit list)이 구간마다 생겨 FFmpeg가 프레임 시각을 잘못 읽으므로 쓰지 않는다.
    /// 쓴 길이(초)를 돌려준다.
    @discardableResult
    static func merge(dir: URL, length: Double, fileType: AVFileType, into url: URL) async throws -> Double {
        let fm = FileManager.default
        var parts: [(Int, URL)] = []
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = f.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("part-"), let k = Int(name.dropFirst(5)) else { continue }
            parts.append((k, f))
        }
        parts.sort { $0.0 < $1.0 }

        var usable: [Source] = []
        for (k, f) in parts {
            let asset = AVURLAsset(url: f)
            guard let ts = try? await asset.load(.tracks), !ts.isEmpty,
                  let d = try? await asset.load(.duration), d.seconds > 0 else { continue }
            usable.append(Source(index: k, asset: asset, tracks: ts, duration: d))
        }
        guard let first = usable.first else { throw NoUsableParts() }

        try? fm.removeItem(at: url)
        // 구간이 하나뿐이고 0초부터면 그대로 옮긴다
        if usable.count == 1, first.index == 0 {
            try fm.moveItem(at: first.asset.url, to: url)
            return first.duration.seconds
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        do {
            let seconds = try await remux(usable, length: length, fileType: fileType, into: tmp)
            try fm.moveItem(at: tmp, to: url)
            return seconds
        } catch {
            try? fm.removeItem(at: tmp)
            throw MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다: \(error.localizedDescription)"))
        }
    }

    private struct Source {
        let index: Int
        let asset: AVURLAsset
        let tracks: [AVAssetTrack]
        let duration: CMTime
    }

    private static func remux(_ sources: [Source], length: Double, fileType: AVFileType, into url: URL) async throws -> Double {
        let partLength = CMTime(value: Int64(length * 1000), timescale: 1000)
        // 트랙 종류·순번별로 구간들을 모은다 (화면 파일: 영상 1 + 마이크 1)
        var order: [String] = []
        var lanes: [String: [(CMTime, AVAsset, AVAssetTrack)]] = [:]
        var end = CMTime.zero
        for src in sources {
            let offset = CMTime(value: Int64(src.index) * Int64(length * 1000), timescale: 1000)
            end = max(end, offset + min(src.duration, partLength))
            var ordinal: [AVMediaType: Int] = [:]
            for t in src.tracks where t.mediaType == .video || t.mediaType == .audio {
                let n = ordinal[t.mediaType, default: 0]
                ordinal[t.mediaType] = n + 1
                let key = "\(t.mediaType.rawValue)-\(n)"
                if lanes[key] == nil { order.append(key) }
                lanes[key, default: []].append((offset, src.asset, t))
            }
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var feeders: [LaneFeeder] = []
        for key in order {
            guard let items = lanes[key], let firstTrack = items.first?.2 else { continue }
            let fd = (try await firstTrack.load(.formatDescriptions)).first
            let input: AVAssetWriterInput
            var pcm: [String: Any]?
            if firstTrack.mediaType == .video {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
                input.transform = try await firstTrack.load(.preferredTransform)
            } else {
                let asbd = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let rate = asbd.map { $0.mSampleRate } ?? 48000
                let ch = Int(asbd?.mChannelsPerFrame ?? 1)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch,
                    AVEncoderBitRateKey: ch >= 2 ? 192_000 : 128_000,
                ])
                pcm = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                ]
            }
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            feeders.append(LaneFeeder(input: input, items: items, partLength: partLength, pcmSettings: pcm, end: end))
        }
        guard !feeders.isEmpty, writer.startWriting() else {
            throw writer.error ?? MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다."))
        }
        writer.startSession(atSourceTime: .zero)
        do {
            try await withThrowingTaskGroup(of: Void.self) { g in
                for f in feeders { g.addTask { try await f.run() } }
                try await g.waitForAll()
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다."))
        }
        return end.seconds
    }

    /// 트랙 하나를 구간 순서대로 읽어 새 writer 입력에 넣는다
    private final class LaneFeeder: @unchecked Sendable {
        let input: AVAssetWriterInput
        let items: [(CMTime, AVAsset, AVAssetTrack)]
        let partLength: CMTime
        let pcmSettings: [String: Any]?
        /// 최종 파일의 끝 시각 (마지막 영상 프레임이 여기까지 이어진다)
        let end: CMTime
        private let queue = DispatchQueue(label: "easycut.segment-merge")
        private var next = 0
        private var reader: AVAssetReader?
        private var output: AVAssetReaderTrackOutput?
        private var offset = CMTime.zero
        /// 소리: 지금까지 쓴 끝 시각. 빠진 구간은 무음으로 채워 시각이 어긋나지 않게 한다.
        private var audioEnd = CMTime.zero
        private var pending: CMSampleBuffer?
        private var done = false

        init(input: AVAssetWriterInput, items: [(CMTime, AVAsset, AVAssetTrack)], partLength: CMTime, pcmSettings: [String: Any]?, end: CMTime) {
            self.input = input; self.items = items; self.partLength = partLength; self.pcmSettings = pcmSettings; self.end = end
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !done else { return }
                    do {
                        while input.isReadyForMoreMediaData {
                            guard let sb = try nextSample() else {
                                done = true
                                input.markAsFinished()
                                c.resume()
                                return
                            }
                            guard input.append(sb) else {
                                throw MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다."))
                            }
                        }
                    } catch {
                        done = true
                        reader?.cancelReading()
                        input.markAsFinished()
                        c.resume(throwing: error)
                    }
                }
            }
        }

        private func openNext() throws -> Bool {
            while next < items.count {
                let (off, asset, track) = items[next]
                next += 1
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
                o.alwaysCopiesSampleData = false
                guard r.canAdd(o) else { continue }
                r.add(o)
                r.timeRange = CMTimeRange(start: .zero, duration: partLength)
                guard r.startReading() else { throw r.error ?? MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다.")) }
                reader = r; output = o; offset = off
                return true
            }
            return false
        }

        private func nextSample() throws -> CMSampleBuffer? {
            pcmSettings == nil ? try nextVideo() : try nextAudio()
        }

        /// 구간을 차례로 읽은 다음 버퍼 (시각은 최종 파일 기준으로 옮김). 다 읽으면 nil.
        private func readShifted() throws -> CMSampleBuffer? {
            while true {
                if output == nil, try !openNext() { return nil }
                guard let o = output, let sb = o.copyNextSampleBuffer() else {
                    if let r = reader, r.status == .failed { throw r.error ?? MediaError.failed(L("녹화 구간을 이어 붙이지 못했습니다.")) }
                    reader = nil; output = nil
                    continue
                }
                // 읽기가 끼워 넣는 표시용 빈 버퍼(샘플 0개, 시각 없음)는 건너뛴다
                guard sb.numSamples > 0, sb.presentationTimeStamp.isValid else { continue }
                if let moved = SegmentedWriter.shift(sb, by: offset) { return moved }
            }
        }

        /// 영상: 한 프레임을 붙잡아 두었다가 다음 프레임 시각까지를 그 길이로 적는다.
        /// 길이를 적지 않거나 원래 길이(1/30초)를 쓰면 화면이 멈춘 동안이 빈 편집(empty edit)으로 기록돼
        /// FFmpeg가 뒤 프레임을 앞당겨 읽는다. 마지막 프레임은 녹화 끝까지 이어진다.
        private func nextVideo() throws -> CMSampleBuffer? {
            while true {
                guard let sb = try readShifted() else {
                    defer { pending = nil }
                    guard let last = pending else { return nil }
                    let d = end - last.presentationTimeStamp
                    return d.seconds > 0 ? SegmentedWriter.withDuration(last, d) ?? last : last
                }
                guard let held = pending else { pending = sb; continue }
                // 앞 구간의 늦은 프레임 등 시각이 거꾸로면 버린다
                guard sb.presentationTimeStamp > held.presentationTimeStamp else { continue }
                pending = sb
                return SegmentedWriter.withDuration(held, sb.presentationTimeStamp - held.presentationTimeStamp) ?? held
            }
        }

        private func nextAudio() throws -> CMSampleBuffer? {
            while true {
                if let p = pending {
                    // 소리가 빠진 시간은 무음으로 채운다 (1초씩)
                    if p.presentationTimeStamp - audioEnd > CMTime(value: 1, timescale: 1000) {
                        let gap = min(p.presentationTimeStamp - audioEnd, CMTime(value: 1, timescale: 1))
                        if let fd = p.formatDescription, let silence = SegmentedWriter.silence(fd, at: audioEnd, duration: gap) {
                            audioEnd = audioEnd + silence.duration
                            return silence
                        }
                    }
                    pending = nil
                    audioEnd = max(audioEnd, p.presentationTimeStamp + p.duration)
                    return p
                }
                guard let sb = try readShifted() else { return nil }
                // 앞 구간과 겹치는 소리는 버린다
                if sb.presentationTimeStamp + sb.duration <= audioEnd + CMTime(value: 1, timescale: 1000) { continue }
                pending = sb
            }
        }
    }

    /// 샘플 하나짜리 버퍼의 길이를 바꾼 복사본
    private static func withDuration(_ sb: CMSampleBuffer, _ d: CMTime) -> CMSampleBuffer? {
        guard sb.numSamples == 1, var timings = try? sb.sampleTimingInfos(), timings.count == 1 else { return nil }
        timings[0].duration = d
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }

    private static func shift(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        guard var timings = try? sb.sampleTimingInfos() else { return nil }
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + offset }
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: timings.count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }

    /// `fd` 형식(선형 PCM)의 무음 버퍼
    private static func silence(_ fd: CMFormatDescription, at t: CMTime, duration: CMTime) -> CMSampleBuffer? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mBytesPerFrame > 0 else { return nil }
        let frames = Int((duration.seconds * asbd.mSampleRate).rounded())
        guard frames > 0 else { return nil }
        let bytes = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr else { return nil }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: frames,
                                                             presentationTimeStamp: CMTimeConvertScale(t, timescale: Int32(asbd.mSampleRate), method: .roundHalfAwayFromZero),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// 지금 실행 중인 녹화가 쥐고 있는 구간 폴더인지
    static func isHeld(_ dir: URL) -> Bool {
        let fd = Darwin.open(dir.appendingPathComponent("lock").path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    /// `root`와 그 바로 아래 폴더에서, 끝난 실행(강제 종료 등)이 남긴 구간 폴더를 찾는다
    static func leftovers(in root: URL) -> [URL] {
        let fm = FileManager.default
        var dirs = [root]
        for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !d.lastPathComponent.hasSuffix(".parts") {
            dirs.append(d)
        }
        return dirs.flatMap { d in
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".parts")
                    && fm.fileExists(atPath: $0.appendingPathComponent("parts.json").path) && !isHeld($0) }
        }
    }

    /// 남은 구간 폴더 하나를 원래 이름(이미 있으면 "(복구)"를 붙인 이름)의 파일로 잇고 폴더를 지운다.
    /// 쓸 수 있는 구간이 없으면 폴더만 지우고 nil. 잇지 못하면 폴더를 남기고 오류를 던진다.
    static func recover(_ dir: URL) async throws -> URL? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("parts.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let base = dir.deletingLastPathComponent()
        var url = base.appendingPathComponent(m.final)
        var n = 1
        while fm.fileExists(atPath: url.path) {
            let stem = (m.final as NSString).deletingPathExtension
            let ext = (m.final as NSString).pathExtension
            url = base.appendingPathComponent(n == 1 ? "\(stem) (복구).\(ext)" : "\(stem) (복구 \(n)).\(ext)")
            n += 1
        }
        do {
            try await merge(dir: dir, length: m.length, fileType: AVFileType(rawValue: m.fileType), into: url)
        } catch is NoUsableParts {
            try? fm.removeItem(at: dir)
            return nil
        }
        try? fm.removeItem(at: dir)
        return url
    }

    private static func retimed(_ sb: CMSampleBuffer, to t: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
