import Foundation

/// 타임라인 위에 배치된 단어
struct TimelineWord: Identifiable, Hashable {
    var id: String { "\(clipID.uuidString)-\(word.id.uuidString)" }
    let word: Word
    let assetID: UUID
    let clipID: UUID
    let track: Int
    let start: Double
    let end: Double
}

extension Project {
    /// 대본이 있는 모든 클립의 단어를 타임라인 시간 순서로 나열
    func timelineWords() -> [TimelineWord] {
        var out: [TimelineWord] = []
        for (ti, track) in tracks.enumerated() {
            for clip in track.clips where clip.kind == .media {
                guard let asset = asset(clip.assetID), let words = asset.words else { continue }
                for w in words {
                    let mid = (w.start + w.end) / 2
                    guard mid >= clip.sourceIn, mid < clip.sourceOut else { continue }
                    let s = clip.timelineTime(atSource: max(w.start, clip.sourceIn))
                    let e = clip.timelineTime(atSource: min(w.end, clip.sourceOut))
                    out.append(TimelineWord(word: w, assetID: asset.id, clipID: clip.id, track: ti, start: s, end: e))
                }
            }
        }
        out.sort { $0.start < $1.start }
        return out
    }

    /// 선택한 단어를 잘라낼 타임라인 구간 계산 (다음 단어 직전까지 포함해 어색한 공백을 없앤다)
    static func deletionRanges(selected: Set<String>, in words: [TimelineWord]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var i = 0
        while i < words.count {
            guard selected.contains(words[i].id) else { i += 1; continue }
            var j = i
            while j + 1 < words.count, selected.contains(words[j + 1].id) { j += 1 }
            let first = words[i], last = words[j]
            var start = first.start
            if i > 0 {
                let gap = first.start - words[i - 1].end
                start = first.start - min(0.04, max(0, gap) / 2)
            }
            var end: Double
            if j + 1 < words.count, words[j + 1].clipID == last.clipID, words[j + 1].start - last.end < 1.5 {
                let gap = max(0, words[j + 1].start - last.end)
                end = words[j + 1].start - min(0.04, gap / 2)
            } else {
                end = last.end + 0.08
                if j + 1 < words.count { end = min(end, words[j + 1].start) }
            }
            if end > start { ranges.append(start...end) }
            i = j + 1
        }
        return merge(ranges)
    }

    /// 말이 없는 구간(무음) 찾기. keep만큼 앞뒤 여유를 남긴다.
    func silenceRanges(minGap: Double, keep: Double) -> [ClosedRange<Double>] {
        let words = timelineWords()
        var ranges: [ClosedRange<Double>] = []
        let byClip = Dictionary(grouping: words, by: \.clipID)
        for (clipID, ws) in byClip {
            guard let clip = clip(clipID) else { continue }
            let sorted = ws.sorted { $0.start < $1.start }
            var cursor = clip.start
            for w in sorted {
                if w.start - cursor >= minGap {
                    let a = cursor == clip.start ? cursor : cursor + keep
                    let b = w.start - keep
                    if b - a > 0.1 { ranges.append(a...b) }
                }
                cursor = max(cursor, w.end)
            }
            if clip.end - cursor >= minGap, let _ = sorted.last {
                let a = cursor + keep
                if clip.end - a > 0.1 { ranges.append(a...clip.end) }
            }
        }
        return Project.merge(ranges)
    }

    static let fillerWords: Set<String> = ["음", "음음", "어", "어어", "으", "으음", "흠", "아", "에", "그", "저", "뭐", "음…", "어…", "um", "uh", "hmm", "erm"]

    static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "…~")))
    }

    func fillerWordIDs() -> Set<String> {
        Set(timelineWords().filter { Project.fillerWords.contains(Project.normalized($0.word.text)) }.map(\.id))
    }

    /// 대본으로 자막 생성
    func generatedCaptions(maxChars: Int = 20, maxDuration: Double = 4.5, pauseBreak: Double = 0.6) -> [Caption] {
        let words = timelineWords()
        var out: [Caption] = []
        var cur: [TimelineWord] = []

        func flush(nextStart: Double?) {
            guard let f = cur.first, let l = cur.last else { return }
            var end = l.end + 0.25
            if let n = nextStart { end = min(end, n) }
            let text = cur.map(\.word.text).joined(separator: " ")
            out.append(Caption(start: f.start, end: max(end, f.start + 0.3), text: text))
            cur.removeAll()
        }

        for (i, w) in words.enumerated() {
            if let l = cur.last, let f = cur.first {
                let chars = cur.map(\.word.text.count).reduce(0, +) + cur.count + w.word.text.count
                let endsSentence = l.word.text.last.map { ".?!。".contains($0) } ?? false
                if w.start - l.end > pauseBreak || chars > maxChars || w.end - f.start > maxDuration || endsSentence || w.clipID != l.clipID {
                    flush(nextStart: w.start)
                }
            }
            cur.append(w)
            if i == words.count - 1 { flush(nextStart: nil) }
        }
        return out
    }

    /// 인식 결과 단어 수정
    mutating func updateWord(asset assetID: UUID, word wordID: UUID, text: String) {
        guard let ai = assets.firstIndex(where: { $0.id == assetID }),
              let wi = assets[ai].words?.firstIndex(where: { $0.id == wordID }) else { return }
        assets[ai].words?[wi].text = text
    }

    /// 전체 대본 텍스트
    func transcriptText() -> String {
        timelineWords().map(\.word.text).joined(separator: " ")
    }
}

enum SRT {
    static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static func make(_ captions: [Caption]) -> String {
        captions.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [Caption] {
        var out: [Caption] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let s = parseStamp(parts[0]), let e = parseStamp(parts[1]) else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
            out.append(Caption(start: s, end: e, text: body))
        }
        return out
    }

    static func parseStamp(_ s: String) -> Double? {
        let p = s.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2].split(separator: " ").first ?? "") else { return nil }
        return h * 3600 + m * 60 + sec
    }
}

enum TimeFormat {
    static func clock(_ t: Double, fps: Double = 30, frames: Bool = false) -> String {
        let t = max(0, t)
        let total = Int(t)
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        if frames {
            let f = Int((t - Double(total)) * fps)
            return h > 0 ? String(format: "%d:%02d:%02d;%02d", h, m, s, f) : String(format: "%02d:%02d;%02d", m, s, f)
        }
        let cs = Int((t - Double(total)) * 100)
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, cs) : String(format: "%02d:%02d.%02d", m, s, cs)
    }

    static func short(_ t: Double) -> String {
        let total = Int(max(0, t).rounded(.down))
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
