//! 목소리 선명하게(소음 줄이기) · 배경음악 자동 줄이기 · 음량 자동 맞추기 · 단어 강조 자막.
//! 맥 `AudioPolish.swift`, `CaptionWords.swift`와 같은 규칙을 쓴다.
//! 새 값은 `.easycut`의 같은 키(denoise, loudnessTarget, autoDuck, wordHighlight, highlightColor)로
//! 각 구조체의 `extra`에 보관해 맥 앱과 그대로 주고받는다.

use crate::model::{Clip, MediaAsset, MediaKind, Project, Rgba, TextStyle};
use serde_json::Value;

/// 소음 줄이기 필터 (낮은 웅웅거림 제거 + 소음 추적 FFT 잡음 제거)
pub const DENOISE_FILTER: &str = "highpass=f=70,afftdn=nr=20:nf=-30:tn=1";
/// 말소리가 나올 때 배경음악 배율 (약 -12 dB)
pub const DUCK_LEVEL: f64 = 0.25;
/// 배경음악이 줄고 다시 커지는 시간 (초)
pub const DUCK_RAMP: f64 = 0.25;
/// 이보다 짧은 말 사이 공백은 하나로 잇는다
pub const SPEECH_GAP: f64 = 0.8;
pub const DEFAULT_LOUDNESS: f64 = -14.0;
pub const DEFAULT_HIGHLIGHT: Rgba = Rgba { r: 1.0, g: 0.84, b: 0.1, a: 1.0 };

fn flag(map: &serde_json::Map<String, Value>, key: &str) -> bool {
    map.get(key).and_then(Value::as_bool) == Some(true)
}

fn set_flag(map: &mut serde_json::Map<String, Value>, key: &str, on: bool) {
    if on {
        map.insert(key.into(), Value::Bool(true));
    } else {
        map.remove(key);
    }
}

pub fn denoise(clip: &Clip) -> bool {
    flag(&clip.extra, "denoise")
}

pub fn set_denoise(clip: &mut Clip, on: bool) {
    set_flag(&mut clip.extra, "denoise", on);
}

pub fn auto_duck(p: &Project) -> bool {
    flag(&p.extra, "autoDuck")
}

pub fn set_auto_duck(p: &mut Project, on: bool) {
    set_flag(&mut p.extra, "autoDuck", on);
}

pub fn loudness_target(p: &Project) -> Option<f64> {
    p.extra.get("loudnessTarget").and_then(Value::as_f64).filter(|v| v.is_finite())
}

pub fn set_loudness_target(p: &mut Project, target: Option<f64>) {
    match target {
        Some(t) => {
            p.extra.insert("loudnessTarget".into(), serde_json::json!(t));
        }
        None => {
            p.extra.remove("loudnessTarget");
        }
    }
}

pub fn word_highlight(s: &TextStyle) -> bool {
    flag(&s.extra, "wordHighlight")
}

pub fn set_word_highlight(s: &mut TextStyle, on: bool) {
    set_flag(&mut s.extra, "wordHighlight", on);
}

pub fn highlight_color(s: &TextStyle) -> Rgba {
    s.extra
        .get("highlightColor")
        .and_then(|v| serde_json::from_value::<Rgba>(v.clone()).ok())
        .unwrap_or(DEFAULT_HIGHLIGHT)
}

pub fn set_highlight_color(s: &mut TextStyle, c: Rgba) {
    s.extra.insert("highlightColor".into(), serde_json::to_value(c).unwrap_or(Value::Null));
}

// MARK: 배경음악 자동 줄이기

/// 대본이 없는 오디오 파일 = 배경음악
pub fn is_music(a: &MediaAsset) -> bool {
    a.kind == MediaKind::Audio && a.words.as_ref().map_or(true, |w| w.is_empty())
}

/// 말소리 구간 (타임라인 초). 음소거 트랙·소리 끈 클립·배경음악의 단어는 빼고, 가까운 구간은 잇는다.
pub fn speech_ranges(p: &Project) -> Vec<(f64, f64)> {
    let mut raw: Vec<(f64, f64)> = vec![];
    for w in p.timeline_words() {
        let Some(track) = p.tracks.get(w.track) else { continue };
        if track.muted {
            continue;
        }
        if p.asset(Some(w.asset_id)).map_or(true, is_music) {
            continue;
        }
        if track.clips.iter().any(|c| c.id == w.clip_id && c.volume <= 0.001) {
            continue;
        }
        raw.push((w.start, w.end.max(w.start)));
    }
    raw.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out: Vec<(f64, f64)> = vec![];
    for (s, e) in raw {
        if let Some(last) = out.last_mut() {
            if s - last.1 <= SPEECH_GAP {
                last.1 = last.1.max(e);
                continue;
            }
        }
        out.push((s, e));
    }
    out
}

/// 배경음악 배율 (말소리 구간에서 DUCK_LEVEL, 앞뒤 DUCK_RAMP초 동안 부드럽게)
pub fn duck_factor(t: f64, speech: &[(f64, f64)]) -> f64 {
    let mut f: f64 = 1.0;
    for &(a, b) in speech {
        if t < a - DUCK_RAMP {
            break;
        }
        let g = if t < a {
            (a - t) / DUCK_RAMP
        } else if t <= b {
            0.0
        } else if t < b + DUCK_RAMP {
            (t - b) / DUCK_RAMP
        } else {
            continue;
        };
        f = f.min(DUCK_LEVEL + (1.0 - DUCK_LEVEL) * g);
    }
    f
}

/// ffmpeg `volume` 필터 식: 클립 안 시간 t(0부터)에 대한 배경음악 배율. 말소리가 없으면 None.
pub fn duck_expression(clip: &Clip, speech: &[(f64, f64)]) -> Option<String> {
    let start = clip.start;
    let end = clip.end();
    let parts: Vec<String> = speech
        .iter()
        .filter(|&&(a, b)| b + DUCK_RAMP > start && a - DUCK_RAMP < end)
        .map(|&(a, b)| {
            let (a, b) = (a - start, b - start);
            // 구간마다 0(바깥)~1(안쪽) 사다리꼴, 그중 가장 큰 값만큼 줄인다
            format!(
                "clip(min((t-({a0:.4}))/{r},(({b1:.4})-t)/{r}),0,1)",
                a0 = a - DUCK_RAMP,
                b1 = b + DUCK_RAMP,
                r = DUCK_RAMP
            )
        })
        .collect();
    if parts.is_empty() {
        return None;
    }
    let mut m = parts[0].clone();
    for p in &parts[1..] {
        m = format!("max({m},{p})");
    }
    Some(format!("1-{:.4}*{m}", 1.0 - DUCK_LEVEL))
}

// MARK: 단어 강조 자막

#[derive(Clone, Debug, PartialEq)]
pub struct CaptionToken {
    /// 자막 글자(앞뒤 공백 제거) 안의 문자(char) 위치와 개수
    pub char_start: usize,
    pub char_len: usize,
    /// 강조가 시작되는 타임라인 시각
    pub start: f64,
}

/// 공백으로 나눈 어절: (문자 위치, 문자 수, 글자 수(grapheme 대신 char))
pub fn tokens(text: &str) -> Vec<(usize, usize)> {
    let mut out = vec![];
    let mut start: Option<usize> = None;
    let chars: Vec<char> = text.trim().chars().collect();
    for (i, ch) in chars.iter().enumerate() {
        if ch.is_whitespace() {
            if let Some(s) = start.take() {
                out.push((s, i - s));
            }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start {
        out.push((s, chars.len() - s));
    }
    out
}

/// 대본 단어 수가 어절 수와 같으면 단어 시각을, 아니면 글자 수 비율로 나눈 시각을 쓴다.
pub fn timings(text: &str, start: f64, end: f64, words: &[f64]) -> Vec<CaptionToken> {
    let toks = tokens(text);
    if toks.is_empty() {
        return vec![];
    }
    if words.len() == toks.len() {
        return toks
            .iter()
            .zip(words)
            .map(|(&(s, l), &w)| CaptionToken { char_start: s, char_len: l, start: w.max(start) })
            .collect();
    }
    let total = toks.iter().map(|t| t.1.max(1)).sum::<usize>().max(1) as f64;
    let dur = (end - start).max(0.01);
    let mut acc = 0.0;
    toks.iter()
        .map(|&(s, l)| {
            let t = start + dur * acc / total;
            acc += l.max(1) as f64;
            CaptionToken { char_start: s, char_len: l, start: t }
        })
        .collect()
}

pub fn active_index(tokens: &[CaptionToken], t: f64) -> Option<usize> {
    if tokens.is_empty() {
        return None;
    }
    let mut idx = 0;
    for (i, tok) in tokens.iter().enumerate() {
        if tok.start <= t + 0.0001 {
            idx = i;
        }
    }
    Some(idx)
}

/// 자막마다 강조 시각
pub fn caption_word_timings(p: &Project) -> Vec<Vec<CaptionToken>> {
    let words = p.timeline_words();
    p.captions
        .iter()
        .map(|cap| {
            let inside: Vec<f64> = words
                .iter()
                .filter(|w| {
                    let mid = (w.start + w.end) / 2.0;
                    mid >= cap.start && mid < cap.end
                })
                .map(|w| w.start)
                .collect();
            timings(&cap.text, cap.start, cap.end, &inside)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Caption, Word};

    #[test]
    fn caption_tokens_and_timings() {
        assert_eq!(tokens("  안녕 하세요  여러분 "), vec![(0, 2), (3, 3), (8, 3)]);
        let exact = timings("안녕 하세요 여러분", 1.0, 3.0, &[1.0, 1.6, 2.3]);
        assert_eq!(exact.iter().map(|t| t.start).collect::<Vec<_>>(), vec![1.0, 1.6, 2.3]);
        let even = timings("ab cd", 0.0, 2.0, &[0.1]);
        assert_eq!(even.iter().map(|t| t.start).collect::<Vec<_>>(), vec![0.0, 1.0]);
        assert_eq!(active_index(&exact, 0.5), Some(0));
        assert_eq!(active_index(&exact, 1.7), Some(1));
        assert_eq!(active_index(&exact, 2.9), Some(2));
    }

    fn asset(kind: MediaKind, words: Option<Vec<Word>>) -> MediaAsset {
        MediaAsset { kind, duration: 10.0, has_audio: true, words, ..Default::default() }
    }

    fn word(text: &str, s: f64, e: f64) -> Word {
        Word { text: text.into(), start: s, end: e, ..Default::default() }
    }

    #[test]
    fn speech_and_ducking() {
        let mut p = Project::default();
        let v = asset(MediaKind::Video, Some(vec![word("a", 1.0, 1.2), word("b", 1.5, 2.0), word("c", 5.0, 6.0)]));
        let m = asset(MediaKind::Audio, None);
        p.assets = vec![v.clone(), m.clone()];
        p.insert(&v, 0, 0.0, 5.0);
        p.insert(&m, 1, 0.0, 5.0);
        assert_eq!(speech_ranges(&p), vec![(1.0, 2.0), (5.0, 6.0)]);
        assert!(is_music(&m) && !is_music(&v));
        let s = speech_ranges(&p);
        assert!((duck_factor(1.5, &s) - DUCK_LEVEL).abs() < 1e-9);
        assert_eq!(duck_factor(3.5, &s), 1.0);
        let music = p.tracks[1].clips[0].clone();
        let expr = duck_expression(&music, &s).unwrap();
        assert!(expr.starts_with("1-0.7500*max("), "{expr}");
        p.tracks[0].muted = true;
        assert!(speech_ranges(&p).is_empty());
    }

    #[test]
    fn extra_keys_round_trip_with_mac_names() {
        let mut p = Project::default();
        set_auto_duck(&mut p, true);
        set_loudness_target(&mut p, Some(-14.0));
        set_word_highlight(&mut p.caption_style, true);
        p.captions.push(Caption::new(0.0, 1.0, "하나 둘"));
        let json = serde_json::to_string(&p).unwrap();
        assert!(json.contains("\"autoDuck\":true") && json.contains("\"loudnessTarget\":-14.0") && json.contains("\"wordHighlight\":true"));
        let back: Project = serde_json::from_str(&json).unwrap();
        assert!(auto_duck(&back) && loudness_target(&back) == Some(-14.0) && word_highlight(&back.caption_style));
        assert_eq!(highlight_color(&back.caption_style), DEFAULT_HIGHLIGHT);
    }
}
