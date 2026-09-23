import AVFoundation

/// Recut 방식: 음성 인식 없이 오디오 음량(파형)만으로 무음 구간을 찾는다.
enum SilenceDetector {
    /// 10ms 단위 음량(dBFS)
    static let hop: Double = 0.01

    /// 파일 전체의 10ms 단위 RMS 음량(dB)을 계산
    static func loudness(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8000
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw MediaError.failed("오디오를 읽을 수 없습니다") }
        let per = Int(Double(rate) * hop)
        var db: [Float] = []
        var acc: Double = 0
        var n = 0
        var buf = [Int16]()
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb) / 2
            if buf.count < len { buf = [Int16](repeating: 0, count: len) }
            buf.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len * 2, destination: raw.baseAddress!)
            }
            for k in 0..<len {
                let v = Double(buf[k]) / 32768
                acc += v * v
                n += 1
                if n == per {
                    db.append(Float(10 * log10(max(acc / Double(per), 1e-10))))
                    acc = 0; n = 0
                }
            }
        }
        if n > 0 { db.append(Float(10 * log10(max(acc / Double(n), 1e-10)))) }
        return db
    }

    /// 소음 바닥과 말소리 크기를 보고 기준 음량을 자동으로 정한다
    static func autoThreshold(_ db: [Float]) -> Double {
        let valid = db.filter { $0 > -95 }.sorted()
        guard valid.count > 50 else { return -40 }
        let floor = Double(valid[Int(Double(valid.count) * 0.1)])
        let speech = Double(valid[Int(Double(valid.count) * 0.9)])
        // 바닥과 말소리 사이의 약 1/3 지점, 너무 극단적이지 않게 제한
        return min(-25, max(-60, floor + (speech - floor) * 0.33))
    }

    /// 원본 시간 기준 무음 구간 (padding만큼 앞뒤를 남긴다)
    static func silences(_ db: [Float], threshold: Double, minSilence: Double, padding: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var start: Int?
        let th = Float(threshold)
        // 짧은 소음(20ms 이하)은 무시
        for i in 0...db.count {
            let quiet = i < db.count ? db[i] < th : false
            if quiet {
                if start == nil { start = i }
            } else if let s = start {
                let len = Double(i - s) * hop
                if len >= minSilence {
                    let a = Double(s) * hop + (s == 0 ? 0 : padding)
                    let b = Double(i) * hop - (i == db.count ? 0 : padding)
                    if b - a > 0.05 { out.append(a...b) }
                }
                start = nil
            }
        }
        return out
    }
}

struct SilenceSettings: Equatable {
    var threshold: Double = -40
    var minSilence: Double = 0.6
    var padding: Double = 0.12
}

extension Project {
    /// 기본 트랙(트랙 1)의 소리 있는 클립 기준으로 무음을 타임라인 구간으로 변환
    func audioSilenceRanges(loudness: [UUID: [Float]], settings: SilenceSettings) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        let base = tracks.first.map { [$0] } ?? []
        for track in base where !track.muted {
            for c in track.clips where c.kind == .media {
                guard let a = asset(c.assetID), a.hasAudio, let db = loudness[a.id] else { continue }
                for r in SilenceDetector.silences(db, threshold: settings.threshold, minSilence: settings.minSilence * c.speed, padding: settings.padding * c.speed) {
                    let s0 = max(r.lowerBound, c.sourceIn), s1 = min(r.upperBound, c.sourceOut)
                    guard s1 - s0 > 0.05 else { continue }
                    // 클립 경계에 걸친 부분은 여유를 다시 계산하지 않고 그대로 자른다
                    ranges.append(c.timelineTime(atSource: s0)...c.timelineTime(atSource: s1))
                }
            }
        }
        return Project.merge(ranges)
    }
}
