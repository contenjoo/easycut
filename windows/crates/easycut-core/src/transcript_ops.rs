//! 대본(단어) 기반 편집: 단어 삭제 컷, 대본 무음 구간, 필러 단어, 자막 생성, SRT.
//! macOS 앱 `Sources/EasyCut/Model/TranscriptOps.swift`를 그대로 옮겼다.

use crate::model::*;
use crate::timeline_ops::{merge_default, TimeRange};
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};

/// 타임라인 위에 배치된 단어
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineWord {
    pub word: Word,
    pub asset_id: Id,
    pub clip_id: Id,
    pub track: usize,
    pub start: f64,
    pub end: f64,
}

impl TimelineWord {
    /// "<클립 UUID>-<단어 UUID>" (맥 앱과 같은 형식)
    pub fn id(&self) -> String {
        format!("{}-{}", self.clip_id, self.word.id)
    }
}

pub const FILLER_WORDS: &[&str] = &[
    "음", "음음", "어", "어어", "으", "으음", "흠", "아", "에", "그", "저", "뭐", "음…", "어…", "um", "uh", "hmm", "erm",
];

fn is_trim_char(c: char) -> bool {
    c.is_whitespace()
        || c.is_ascii_punctuation()
        || matches!(
            c,
            '…' | '~' | '。' | '、' | '，' | '！' | '？' | '「' | '」' | '『' | '』' | '·' | '“' | '”' | '‘' | '’' | '《' | '》'
        )
}

/// 소문자로 바꾸고 앞뒤 문장부호·공백·"…"·"~" 제거
pub fn normalized(s: &str) -> String {
    s.to_lowercase().trim_matches(is_trim_char).to_string()
}

/// 글자 수 (Swift `String.count`에 해당. 한글 완성형·영문에서는 같다)
fn char_count(s: &str) -> usize {
    s.chars().count()
}

impl Project {
    /// 대본이 있는 모든 클립의 단어를 타임라인 시간 순서로 나열
    pub fn timeline_words(&self) -> Vec<TimelineWord> {
        let mut out = vec![];
        for (ti, track) in self.tracks.iter().enumerate() {
            for clip in track.clips.iter().filter(|c| c.kind == ClipKind::Media) {
                let Some(asset) = self.asset(clip.asset_id) else { continue };
                let Some(words) = &asset.words else { continue };
                for w in words {
                    let mid = (w.start + w.end) / 2.0;
                    if !(mid >= clip.source_in && mid < clip.source_out) {
                        continue;
                    }
                    let s = clip.timeline_time(w.start.max(clip.source_in));
                    let e = clip.timeline_time(w.end.min(clip.source_out));
                    out.push(TimelineWord { word: w.clone(), asset_id: asset.id, clip_id: clip.id, track: ti, start: s, end: e });
                }
            }
        }
        out.sort_by(|a, b| a.start.total_cmp(&b.start));
        out
    }

    /// 말이 없는 구간(무음) 찾기. keep만큼 앞뒤 여유를 남긴다.
    pub fn silence_ranges(&self, min_gap: f64, keep: f64) -> Vec<TimeRange> {
        let words = self.timeline_words();
        let mut by_clip: BTreeMap<Id, Vec<&TimelineWord>> = BTreeMap::new();
        for w in &words {
            by_clip.entry(w.clip_id).or_default().push(w);
        }
        let mut ranges = vec![];
        for (clip_id, mut ws) in by_clip {
            let Some(clip) = self.clip(clip_id) else { continue };
            ws.sort_by(|a, b| a.start.total_cmp(&b.start));
            let mut cursor = clip.start;
            for w in &ws {
                if w.start - cursor >= min_gap {
                    let a = if cursor == clip.start { cursor } else { cursor + keep };
                    let b = w.start - keep;
                    if b - a > 0.1 {
                        ranges.push(TimeRange::new(a, b));
                    }
                }
                cursor = cursor.max(w.end);
            }
            if clip.end() - cursor >= min_gap && !ws.is_empty() {
                let a = cursor + keep;
                if clip.end() - a > 0.1 {
                    ranges.push(TimeRange::new(a, clip.end()));
                }
            }
        }
        merge_default(&ranges)
    }

    pub fn filler_word_ids(&self) -> HashSet<String> {
        self.timeline_words()
            .iter()
            .filter(|w| FILLER_WORDS.contains(&normalized(&w.word.text).as_str()))
            .map(TimelineWord::id)
            .collect()
    }

    /// 대본으로 자막 생성 (기본값: 20자, 4.5초, 0.6초 쉼)
    pub fn generated_captions(&self, max_chars: usize, max_duration: f64, pause_break: f64) -> Vec<Caption> {
        let words = self.timeline_words();
        let mut out: Vec<Caption> = vec![];
        let mut cur: Vec<&TimelineWord> = vec![];

        fn flush(cur: &mut Vec<&TimelineWord>, out: &mut Vec<Caption>, next_start: Option<f64>) {
            let (Some(f), Some(l)) = (cur.first(), cur.last()) else { return };
            let mut end = l.end + 0.25;
            if let Some(n) = next_start {
                end = end.min(n);
            }
            let text = cur.iter().map(|w| w.word.text.as_str()).collect::<Vec<_>>().join(" ");
            out.push(Caption::new(f.start, end.max(f.start + 0.3), text));
            cur.clear();
        }

        for (i, w) in words.iter().enumerate() {
            if let (Some(l), Some(f)) = (cur.last(), cur.first()) {
                let chars = cur.iter().map(|x| char_count(&x.word.text)).sum::<usize>() + cur.len() + char_count(&w.word.text);
                let ends_sentence = l.word.text.chars().last().is_some_and(|c| ".?!。".contains(c));
                if w.start - l.end > pause_break
                    || chars > max_chars
                    || w.end - f.start > max_duration
                    || ends_sentence
                    || w.clip_id != l.clip_id
                {
                    flush(&mut cur, &mut out, Some(w.start));
                }
            }
            cur.push(w);
            if i == words.len() - 1 {
                flush(&mut cur, &mut out, None);
            }
        }
        out
    }

    pub fn generated_captions_default(&self) -> Vec<Caption> {
        self.generated_captions(20, 4.5, 0.6)
    }

    /// 인식 결과 단어 수정
    pub fn update_word(&mut self, asset: Id, word: Id, text: &str) {
        if let Some(a) = self.assets.iter_mut().find(|a| a.id == asset) {
            if let Some(w) = a.words.as_mut().and_then(|ws| ws.iter_mut().find(|w| w.id == word)) {
                w.text = text.to_string();
            }
        }
    }

    /// 전체 대본 텍스트
    pub fn transcript_text(&self) -> String {
        self.timeline_words().iter().map(|w| w.word.text.as_str()).collect::<Vec<_>>().join(" ")
    }
}

/// 선택한 단어를 잘라낼 타임라인 구간 계산 (다음 단어 직전까지 포함해 어색한 공백을 없앤다)
pub fn deletion_ranges(selected: &HashSet<String>, words: &[TimelineWord]) -> Vec<TimeRange> {
    let ids: Vec<String> = words.iter().map(TimelineWord::id).collect();
    let mut ranges = vec![];
    let mut i = 0;
    while i < words.len() {
        if !selected.contains(&ids[i]) {
            i += 1;
            continue;
        }
        let mut j = i;
        while j + 1 < words.len() && selected.contains(&ids[j + 1]) {
            j += 1;
        }
        let (first, last) = (&words[i], &words[j]);
        let mut start = first.start;
        if i > 0 {
            let gap = first.start - words[i - 1].end;
            start = first.start - 0.04_f64.min(gap.max(0.0) / 2.0);
        }
        let end;
        if j + 1 < words.len() && words[j + 1].clip_id == last.clip_id && words[j + 1].start - last.end < 1.5 {
            let gap = (words[j + 1].start - last.end).max(0.0);
            end = words[j + 1].start - 0.04_f64.min(gap / 2.0);
        } else {
            let mut e = last.end + 0.08;
            if j + 1 < words.len() {
                e = e.min(words[j + 1].start);
            }
            end = e;
        }
        if end > start {
            ranges.push(TimeRange::new(start, end));
        }
        i = j + 1;
    }
    merge_default(&ranges)
}

pub mod srt {
    use crate::model::Caption;

    pub fn stamp(t: f64) -> String {
        let ms = (t.max(0.0) * 1000.0).round() as i64;
        format!("{:02}:{:02}:{:02},{:03}", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    pub fn make(captions: &[Caption]) -> String {
        captions
            .iter()
            .enumerate()
            .map(|(i, c)| format!("{}\n{} --> {}\n{}\n", i + 1, stamp(c.start), stamp(c.end), c.text))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn parse(text: &str) -> Vec<Caption> {
        let text = text.replace("\r\n", "\n");
        let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
        let mut out = vec![];
        for b in text.split("\n\n") {
            let lines: Vec<&str> = b.split('\n').filter(|l| !l.is_empty()).collect();
            let Some(ti) = lines.iter().position(|l| l.contains("-->")) else { continue };
            let parts: Vec<&str> = lines[ti].split("-->").map(str::trim).collect();
            if parts.len() != 2 {
                continue;
            }
            let (Some(s), Some(e)) = (parse_stamp(parts[0]), parse_stamp(parts[1])) else { continue };
            out.push(Caption::new(s, e, lines[ti + 1..].join("\n")));
        }
        out
    }

    pub fn parse_stamp(s: &str) -> Option<f64> {
        let s = s.replace(',', ".");
        let p: Vec<&str> = s.split(':').collect();
        if p.len() != 3 {
            return None;
        }
        let h: f64 = p[0].trim().parse().ok()?;
        let m: f64 = p[1].trim().parse().ok()?;
        let sec: f64 = p[2].split(' ').next()?.trim().parse().ok()?;
        Some(h * 3600.0 + m * 60.0 + sec)
    }
}

pub mod time_format {
    pub fn clock(t: f64, fps: f64, frames: bool) -> String {
        let t = t.max(0.0);
        let total = t as i64;
        let (h, m, s) = (total / 3600, (total / 60) % 60, total % 60);
        if frames {
            let f = ((t - total as f64) * fps) as i64;
            return if h > 0 { format!("{h}:{m:02}:{s:02};{f:02}") } else { format!("{m:02}:{s:02};{f:02}") };
        }
        let cs = ((t - total as f64) * 100.0) as i64;
        if h > 0 {
            format!("{h}:{m:02}:{s:02}.{cs:02}")
        } else {
            format!("{m:02}:{s:02}.{cs:02}")
        }
    }

    pub fn short(t: f64) -> String {
        let total = t.max(0.0).floor() as i64;
        let (h, m, s) = (total / 3600, (total / 60) % 60, total % 60);
        if h > 0 {
            format!("{h}:{m:02}:{s:02}")
        } else {
            format!("{m}:{s:02}")
        }
    }
}
