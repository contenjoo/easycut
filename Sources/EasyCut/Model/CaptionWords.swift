import Foundation

/// 단어 강조 자막: 자막 한 줄을 어절로 나누고 각 어절이 강조되는 시각을 정한다.
/// Windows `easycut_core::caption_words`와 같은 규칙을 쓴다.
struct CaptionToken: Hashable {
    /// 자막 글자(앞뒤 공백 제거) 안의 UTF-16 위치와 길이
    let location: Int
    let length: Int
    /// 강조가 시작되는 타임라인 시각 (초)
    let start: Double
}

enum CaptionWords {
    static let defaultHighlight = RGBA(r: 1, g: 0.84, b: 0.1, a: 1)

    /// 공백으로 나눈 어절과 그 UTF-16 범위
    static func tokens(_ text: String) -> [(location: Int, length: Int, chars: Int)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [(Int, Int, Int)] = []
        var loc = 0
        var start: Int?
        var chars = 0
        for ch in trimmed {
            let n = String(ch).utf16.count
            if ch.isWhitespace {
                if let s = start { out.append((s, loc - s, chars)) }
                start = nil
                chars = 0
            } else {
                if start == nil { start = loc }
                chars += 1
            }
            loc += n
        }
        if let s = start { out.append((s, loc - s, chars)) }
        return out.map { (location: $0.0, length: $0.1, chars: $0.2) }
    }

    /// 대본 단어 시각이 자막 어절 수와 맞으면 그 시각을, 아니면 글자 수 비율로 나눈 시각을 쓴다.
    static func timings(text: String, start: Double, end: Double, words: [Double]) -> [CaptionToken] {
        let toks = tokens(text)
        guard !toks.isEmpty else { return [] }
        if words.count == toks.count {
            return zip(toks, words).map { CaptionToken(location: $0.location, length: $0.length, start: max(start, $1)) }
        }
        let total = Double(max(1, toks.reduce(0) { $0 + max(1, $1.chars) }))
        let dur = max(0.01, end - start)
        var acc = 0.0
        return toks.map { t in
            let s = start + dur * acc / total
            acc += Double(max(1, t.chars))
            return CaptionToken(location: t.location, length: t.length, start: s)
        }
    }

    /// t 시각에 강조할 어절 번호
    static func activeIndex(_ tokens: [CaptionToken], at t: Double) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var idx = 0
        for (i, tok) in tokens.enumerated() where tok.start <= t + 0.0001 { idx = i }
        return idx
    }
}

extension Project {
    /// 자막마다 강조 시각 (자막 id → 어절 목록)
    func captionWordTimings() -> [UUID: [CaptionToken]] {
        let words = timelineWords()
        var out: [UUID: [CaptionToken]] = [:]
        for cap in captions {
            let inside = words.filter { w in
                let mid = (w.start + w.end) / 2
                return mid >= cap.start && mid < cap.end
            }.map(\.start)
            out[cap.id] = CaptionWords.timings(text: cap.text, start: cap.start, end: cap.end, words: inside)
        }
        return out
    }
}
