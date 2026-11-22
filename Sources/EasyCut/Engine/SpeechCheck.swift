import AVFoundation

/// 녹화 뒤 자동 음성 인식·자막 전에 '사람 말소리가 있는지' 대충 가린다.
/// 무음, 일정한 소리(시험음·웅웅거림)는 Whisper가 엉뚱한 문장을 지어내므로 자동 실행을 건너뛴다.
enum SpeechCheck {
    struct Result: Equatable {
        var activeRatio: Double  // 소리가 있는 50ms 구간 비율
        var spreadDB: Double     // 소리 있는 구간 음량의 상위 10%와 하위 10% 차이(dB). 말은 크고, 시험음·웅웅거림은 작다
        var likelySpeech: Bool { activeRatio >= 0.05 && spreadDB >= 10 }
    }

    /// 50ms 구간별 RMS(0…1)로 판정한다. 테스트하기 쉽게 분리.
    static func judge(frameRMS: [Float]) -> Result {
        let threshold: Float = 0.003   // 약 -50 dBFS
        let active = frameRMS.filter { $0 > threshold }
        guard !frameRMS.isEmpty, !active.isEmpty else { return Result(activeRatio: 0, spreadDB: 0) }
        let sorted = active.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.1)], high = sorted[Int(Double(sorted.count - 1) * 0.9)]
        return Result(activeRatio: Double(active.count) / Double(frameRMS.count),
                      spreadDB: Double(20 * log10(high / max(low, 1e-6))))
    }

    /// 파일의 첫 오디오 트랙을 최대 `limit`초 읽어 판정한다. 읽지 못하면 nil(판정 보류 → 기존처럼 인식).
    static func analyze(_ url: URL, limit: Double = 600) async -> Result? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let frame = Int(rate * 0.05)
        var rms: [Float] = []
        var sum: Float = 0, count = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let n = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: n) { samples in
                for i in 0..<n {
                    sum += samples[i] * samples[i]; count += 1
                    if count == frame { rms.append(sqrt(sum / Float(frame))); sum = 0; count = 0 }
                }
            }
        }
        guard reader.status == .completed else { return nil }
        return judge(frameRMS: rms)
    }

    /// Whisper가 소리 없는 구간에서 같은 문장을 되풀이해 지어낸 경우
    static func looksRepetitive(_ words: [String]) -> Bool {
        let cleaned = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }.filter { !$0.isEmpty }
        guard cleaned.count >= 12 else { return false }
        return Double(Set(cleaned).count) / Double(cleaned.count) <= 0.35
    }
}
