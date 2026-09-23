import AVFoundation
import AppKit

/// 타임라인에 그릴 썸네일·파형 캐시
@MainActor
final class MediaCache: ObservableObject {
    struct Thumbs {
        var interval: Double
        var images: [CGImage?]
    }

    @Published private(set) var version = 0
    private(set) var thumbs: [UUID: Thumbs] = [:]
    /// 20ms 단위 피크 (0...1)
    private(set) var waveforms: [UUID: [Float]] = [:]
    private var pending: Set<UUID> = []
    static let waveRate: Double = 50

    func prepare(_ asset: MediaAsset) {
        guard !pending.contains(asset.id), thumbs[asset.id] == nil || waveforms[asset.id] == nil, !asset.isMissing else { return }
        pending.insert(asset.id)
        Task { [weak self] in
            async let t = Self.makeThumbs(asset)
            async let w = asset.hasAudio ? Self.makeWaveform(asset.url) : nil
            let (thumbs, wave) = await (t, w)
            guard let self else { return }
            if let thumbs { self.thumbs[asset.id] = thumbs }
            if let wave { self.waveforms[asset.id] = wave }
            self.version += 1
        }
    }

    func thumbnail(_ id: UUID) -> CGImage? {
        thumbs[id]?.images.first(where: { $0 != nil }) ?? nil
    }

    func thumb(_ id: UUID, at source: Double) -> CGImage? {
        guard let t = thumbs[id], !t.images.isEmpty else { return nil }
        let i = min(t.images.count - 1, max(0, Int(source / t.interval)))
        return t.images[i] ?? t.images.first(where: { $0 != nil }) ?? nil
    }

    nonisolated static func makeThumbs(_ asset: MediaAsset) async -> Thumbs? {
        switch asset.kind {
        case .audio:
            return nil
        case .image:
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 240,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return Thumbs(interval: .infinity, images: [img])
        case .video:
            let av = AVURLAsset(url: asset.url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let count = max(1, min(120, Int(asset.duration / 2)))
            let interval = asset.duration / Double(count)
            var images = [CGImage?](repeating: nil, count: count)
            let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * interval, preferredTimescale: 600) }
            for await r in gen.images(for: times) {
                if let img = try? r.image {
                    let i = min(count - 1, max(0, Int(r.requestedTime.seconds / interval)))
                    images[i] = img
                }
            }
            return Thumbs(interval: interval, images: images)
        }
    }

    nonisolated static func makeWaveform(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { return nil }
        let per = rate / Int(waveRate)
        var peaks: [Float] = []
        var cur: Int16 = 0
        var n = 0
        var buf = [Int16]()
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb) / 2
            if buf.count < len { buf = [Int16](repeating: 0, count: len) }
            buf.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len * 2, destination: raw.baseAddress!)
            }
            for i in 0..<len {
                let v = buf[i] == Int16.min ? Int16.max : abs(buf[i])
                if v > cur { cur = v }
                n += 1
                if n == per { peaks.append(Float(cur) / 32767); cur = 0; n = 0 }
            }
        }
        if n > 0 { peaks.append(Float(cur) / 32767) }
        // 보기 좋게 정규화
        let mx = max(0.05, peaks.max() ?? 1)
        return peaks.map { min(1, $0 / mx) }
    }
}
