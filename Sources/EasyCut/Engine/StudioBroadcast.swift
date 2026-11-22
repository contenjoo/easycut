import AVFoundation
import UniformTypeIdentifiers
import Darwin

/// The stream key only goes to FFmpeg over stdin. The private FIFO carries encoded media.
struct StudioEndpoint {
    let server: URL
    let key: String
    static let invalid = MediaError.failed("RTMP 또는 RTMPS 서버 주소와 스트림 키를 확인하세요.")

    static func destination(server: String, key: String) throws -> URL {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: server), parts.query == nil, parts.fragment == nil,
              !key.isEmpty, let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw invalid }
        var path = parts.percentEncodedPath
        if !path.hasSuffix("/") { path += "/" }
        parts.percentEncodedPath = path + encoded
        guard let url = parts.url else { throw invalid }
        _ = try StudioEndpoint(url)
        return url
    }

    init(_ url: URL) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["rtmp", "rtmps"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, let slash = parts.percentEncodedPath.lastIndex(of: "/"),
              let name = String(parts.percentEncodedPath.suffix(from: parts.percentEncodedPath.index(after: slash))).removingPercentEncoding,
              !name.isEmpty else { throw Self.invalid }
        let secret = name + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard secret.utf8.count < 2048, secret.rangeOfCharacter(from: .controlCharacters) == nil else { throw Self.invalid }
        parts.percentEncodedQuery = nil
        parts.percentEncodedPath = String(parts.percentEncodedPath[..<slash])
        guard let server = parts.url else { throw Self.invalid }
        self.server = server
        self.key = secret
    }
}

final class StudioBroadcast: NSObject, AVAssetWriterDelegate {
    static let connectionError = "송출 연결을 확인하세요. 로컬 녹화는 계속됩니다."
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let transport: StudioRTMPTransport
    var hasFailed: Bool {
        if writer.status == .failed { transport.fail(Self.connectionError) }
        return transport.failed
    }
    var canAcceptAudio: Bool { writer.status == .writing && audio.isReadyForMoreMediaData }
    var isConnected: Bool { transport.isConnected }
    /// 다시 연결한 송출은 이 시각을 0초로 삼는다 (새 연결마다 타임스탬프가 0부터 시작)
    private let origin: CMTime

    init(url: URL, origin: CMTime = .zero, onStatus: @escaping (String) -> Void) throws {
        let endpoint = try StudioEndpoint(url)
        self.origin = origin
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(value: 1, timescale: 1)
        writer.initialSegmentStartTime = .zero
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_200_000, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        for input in [video, audio] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw MediaError.failed(Self.connectionError) }
            writer.add(input)
        }
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        transport = try StudioRTMPTransport(endpoint: endpoint, onStatus: onStatus)
        super.init()
        writer.delegate = self
        guard writer.startWriting() else {
            transport.fail(Self.connectionError)
            transport.finish()
            throw MediaError.failed(Self.connectionError)
        }
        writer.startSession(atSourceTime: .zero)
    }

    func appendVideo(at time: CMTime, render: (CVPixelBuffer) -> Void) {
        guard writer.status == .writing, video.isReadyForMoreMediaData, let pool = pixels.pixelBufferPool else { return }
        var frame: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &frame) == kCVReturnSuccess, let frame else { return }
        render(frame)
        if !pixels.append(frame, withPresentationTime: time - origin) { transport.fail(Self.connectionError) }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        var sample = sample
        if origin != .zero {
            let shifted = sample.presentationTimeStamp - origin
            guard shifted >= .zero else { return }   // 다시 연결하기 전 구간의 소리
            var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: shifted, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                        sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            sample = copy
        }
        if !audio.append(sample) { transport.fail(Self.connectionError) }
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType) {
        transport.submit(data)
    }

    func finish() {
        guard writer.status == .writing else { transport.finish(); return }
        video.markAsFinished()
        audio.markAsFinished()
        writer.finishWriting { [self] in transport.finish() }
    }
}

private final class StudioRTMPTransport: @unchecked Sendable {
    private let process = Process()
    private let queue = DispatchQueue(label: "easycut.studio.rtmp")
    private let lock = NSLock()
    private let dir: URL
    private let fd: Int32
    private let progress = Pipe()
    private let onStatus: (String) -> Void
    private var queuedBytes = 0
    private var failure = false
    private var stopping = false
    private var connected = false
    var failed: Bool { lock.withLock { failure } }
    var isConnected: Bool { lock.withLock { connected && !failure } }

    init(endpoint: StudioEndpoint, onStatus: @escaping (String) -> Void) throws {
        self.onStatus = onStatus
        guard let ffmpeg = Tools.find("ffmpeg") else { throw MediaError.failed(StudioBroadcast.connectionError) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EasyCut-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fifo = dir.appendingPathComponent("media")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw MediaError.failed(StudioBroadcast.connectionError)
        }
        fd = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw MediaError.failed(StudioBroadcast.connectionError)
        }
        let credentials = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        var protocolOptions: [String] = []
        let application = endpoint.server.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !application.isEmpty { protocolOptions += ["-rtmp_app", application] }
        if endpoint.server.scheme?.lowercased() == "rtmps" { protocolOptions += ["-tls_verify", "1"] }
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1",
                             "-f", "mov", "-analyzeduration", "100000", "-probesize", "4096", "-fpsprobesize", "0", "-i", fifo.path,
                             "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-fpre", "/dev/stdin"]
                            + protocolOptions + ["-rw_timeout", "8000000", "-flvflags", "no_duration_filesize", "-f", "flv", endpoint.server.absoluteString]
        process.standardInput = credentials
        process.standardOutput = progress
        process.standardError = FileHandle.nullDevice
        progress.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if String(decoding: data, as: UTF8.self).split(separator: "\n").contains(where: {
                $0.hasPrefix("out_time_us=") && (Int($0.dropFirst(12)) ?? 0) > 0
            }) { self?.markConnected() }
        }
        process.terminationHandler = { [weak self] _ in self?.fail(StudioBroadcast.connectionError) }
        do {
            // Write before launching: the bounded key fits in the pipe and stdout/argv never contain it.
            try credentials.fileHandleForWriting.write(contentsOf: Data(("rtmp_playpath=" + endpoint.key + "\n").utf8))
            try credentials.fileHandleForWriting.close()
            try process.run()
        } catch {
            progress.fileHandleForReading.readabilityHandler = nil
            close(fd)
            try? FileManager.default.removeItem(at: dir)
            throw MediaError.failed(StudioBroadcast.connectionError)
        }
        DispatchQueue.main.async { onStatus("송출 연결 중") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.lock.withLock({ self.connected || self.stopping }) else { return }
            self.fail(StudioBroadcast.connectionError)
        }
    }

    private func markConnected() {
        let changed = lock.withLock {
            guard !connected, !failure, !stopping else { return false }
            connected = true
            return true
        }
        if changed { DispatchQueue.main.async { self.onStatus("실시간 송출 중") } }
    }

    func submit(_ data: Data) {
        guard !data.isEmpty else { return }
        let bytes = lock.withLock { () -> Int in
            guard !failure, !stopping else { return -1 }
            queuedBytes += data.count
            return queuedBytes
        }
        guard bytes >= 0 else { return }
        guard bytes <= 4 * 1024 * 1024 else { fail("송출이 지연되어 중단했습니다. 로컬 녹화는 계속됩니다."); return }
        queue.async {
            defer { self.lock.withLock { self.queuedBytes -= data.count } }
            let written = data.withUnsafeBytes { buffer -> Bool in
                guard let pointer = buffer.baseAddress else { return true }
                var offset = 0
                var deadline = DispatchTime.now() + .seconds(6)
                while offset < buffer.count, !self.failed, self.process.isRunning {
                    let n = Darwin.write(self.fd, pointer.advanced(by: offset), buffer.count - offset)
                    if n > 0 {
                        offset += n
                        deadline = .now() + .seconds(6)
                    } else if n < 0, errno == EAGAIN || errno == EINTR {
                        if DispatchTime.now() > deadline { break }
                        usleep(8_000)
                    } else { break }
                }
                return offset == buffer.count
            }
            if !written { self.fail(StudioBroadcast.connectionError) }
        }
    }

    func fail(_ message: String) {
        let changed = lock.withLock {
            guard !failure, !stopping else { return false }
            failure = true
            return true
        }
        if changed {
            DispatchQueue.main.async { self.onStatus(message) }
            if process.isRunning { process.terminate() }
        }
    }

    func finish() {
        let first = lock.withLock {
            guard !stopping else { return false }
            stopping = true
            return true
        }
        guard first else { return }
        queue.async {
            close(self.fd)
            // Keep the pipe path until FFmpeg opens it. A stalled publisher must not survive the session.
            let worker = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if worker.isRunning { worker.terminate() }
                self.progress.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: self.dir)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
