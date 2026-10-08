import Foundation

/// 자막 시작과 실제 말소리 시작을 비교해 자막 시간이 빠른지 늦은지 잰다 (소리 크기 기준, 음성 인식과 무관)
struct CaptionSyncMeasure {
    var index: Int
    var captionStart: Double
    /// 실제 말소리가 시작된 타임라인 시간
    var onset: Double
    /// + = 자막이 말보다 빠름 (늦춰야 함), - = 자막이 늦음
    var offset: Double { onset - captionStart }
}

struct CaptionSyncReport {
    var measures: [CaptionSyncMeasure]
    var skipped: Int
    var median: Double
    var spread: Double
    /// 차이가 거의 일정하면 한꺼번에 옮기면 된다
    var consistent: Bool { measures.count >= 3 && spread <= 0.06 }
}

extension Project {
    /// t에 소리가 나는 클립 (아래 트랙부터, 음소거 제외)
    func audibleClip(at t: Double) -> Clip? {
        for track in tracks where !track.muted {
            if let c = track.clips.first(where: { $0.kind == .media && t >= $0.start - 0.001 && t < $0.end && $0.volume > 0.001 && (asset($0.assetID)?.hasAudio ?? false) }) {
                return c
            }
        }
        return nil
    }

    /// 자막마다 근처(±window초)에서 "조용하다가 소리가 나기 시작한 순간"을 찾는다.
    /// 앞이 말소리로 이어지는 자막(문장 중간에서 나뉜 자막)은 잴 수 없어 건너뛴다.
    func captionSync(loudness: [UUID: [Float]], thresholds: [UUID: Double], from: Double = 0, to: Double = .infinity,
                     window: Double = 0.6) -> CaptionSyncReport {
        let hop = SilenceDetector.hop
        var measures: [CaptionSyncMeasure] = []
        var skipped = 0
        for (n, cap) in captions.enumerated() where cap.start >= from && cap.start < to {
            guard let c = audibleClip(at: cap.start + 0.001) ?? audibleClip(at: cap.start + window / 2),
                  let aid = c.assetID, let db = loudness[aid], let th = thresholds[aid] else { skipped += 1; continue }
            let s = c.sourceTime(atTimeline: cap.start)
            let lo = max(c.sourceIn, s - window * c.speed), hi = min(c.sourceOut, s + window * c.speed)
            let i0 = max(1, Int(lo / hop)), i1 = min(db.count - 4, Int(hi / hop))
            guard i1 > i0 else { skipped += 1; continue }
            // 조용하다가 소리가 나기 시작한 곳 중, 앞의 조용함이 가장 긴 곳 (문장 사이 쉼 > 단어 사이 틈)
            var best: (i: Int, quiet: Int)?
            var quiet = 0
            quiet = (max(0, i0 - 100)..<i0).reversed().prefix { Double(db[$0]) < th }.count
            // 파일 맨 앞까지 조용하면 충분히 긴 쉼으로 본다
            if quiet == i0 - max(0, i0 - 100), i0 < 100 { quiet = 100 }
            var i = i0
            while i <= i1 {
                if Double(db[i]) < th {
                    quiet += 1
                } else {
                    let loudAfter = (i..<(i + 4)).allSatisfy { Double(db[$0]) >= th }
                    if quiet >= 12 && loudAfter {
                        let q = min(quiet, 100)
                        let t = Double(i) * hop
                        if best == nil || q > best!.quiet || (q == best!.quiet && abs(t - s) < abs(Double(best!.i) * hop - s)) { best = (i, q) }
                    }
                    quiet = 0
                }
                i += 1
            }
            guard let b = best?.i else { skipped += 1; continue }
            let onset = c.timelineTime(atSource: Double(b) * hop)
            // 앞뒤 자막의 말 시작을 잡았으면 이 자막은 문장 중간이라 잴 수 없다
            if n > 0, onset < captions[n - 1].end - 0.35 { skipped += 1; continue }
            if n + 1 < captions.count, onset > captions[n + 1].end - 0.1 { skipped += 1; continue }
            measures.append(CaptionSyncMeasure(index: n, captionStart: cap.start, onset: onset))
        }
        let offs = measures.map(\.offset).sorted()
        let median = offs.isEmpty ? 0 : offs[offs.count / 2]
        let dev = offs.map { abs($0 - median) }.sorted()
        let spread = dev.isEmpty ? 0 : dev[dev.count / 2]
        return CaptionSyncReport(measures: measures, skipped: skipped, median: median, spread: spread)
    }

    /// 자막을 d초 옮긴다 (+ = 늦추기). 범위를 주면 그 안에서 시작하는 자막만.
    mutating func shiftCaptions(by d: Double, from: Double = 0, to: Double = .infinity) {
        for i in captions.indices where captions[i].start >= from && captions[i].start < to {
            let len = captions[i].end - captions[i].start
            captions[i].start = max(0, captions[i].start + d)
            captions[i].end = captions[i].start + len
        }
        captions.sort { $0.start < $1.start }
    }

    /// 잰 자막마다 시작을 실제 말소리 시작에 맞춘다. 앞 자막과 겹치지 않게, 너무 짧아지지 않게.
    mutating func snapCaptions(_ measures: [CaptionSyncMeasure]) {
        for m in measures where captions.indices.contains(m.index) {
            var c = captions[m.index]
            var start = m.onset
            if m.index > 0 { start = max(start, captions[m.index - 1].end) }
            // 늦출 때는 길이를 유지, 다음 자막을 넘지 않게
            var end = c.end + max(0, start - c.start)
            if m.index + 1 < captions.count { end = min(end, captions[m.index + 1].start) }
            c.start = start
            c.end = max(end, start + 0.3)
            captions[m.index] = c
        }
    }
}
