//! whisper.cpp 관련 순수 로직: 오디오 청크 분할, `-ojf` JSON 파싱, 단어 겹침 정리.
//! macOS 앱 `Sources/EasyCut/Engine/Transcriber.swift`를 옮겼다. 입력은 16kHz 모노 16비트 PCM.

use crate::model::Word;
use serde_json::Value;
use std::ops::Range;

pub const SAMPLE_RATE: usize = 16000;

/// 조용한 지점(0.3초 평균 에너지 최소)에서 minLen~maxLen초 조각으로 나눈다
pub fn chunks(s: &[i16], min_len: f64, max_len: f64) -> Vec<Range<usize>> {
    let win = SAMPLE_RATE / 10; // 0.1초
    let n_win = s.len() / win;
    if n_win == 0 {
        return if s.is_empty() {
            vec![]
        } else {
            vec![0..s.len()]
        };
    }
    let mut energy = vec![0f32; n_win];
    for (w, e) in energy.iter_mut().enumerate() {
        let base = w * win;
        let mut acc = 0f32;
        let mut i = 0;
        while i < win {
            let v = s[base + i] as f32;
            acc += v * v;
            i += 4;
        }
        *e = acc / (win / 4) as f32;
    }
    let mut out = vec![];
    let mut start_win = 0;
    let (min_w, max_w) = ((min_len * 10.0) as usize, (max_len * 10.0) as usize);
    while start_win < n_win {
        if n_win - start_win <= max_w {
            out.push(start_win * win..s.len());
            break;
        }
        let mut best = start_win + min_w;
        let mut best_e = f32::MAX;
        for w in (start_win + min_w)..n_win.min(start_win + max_w) {
            let e = energy[w]
                + if w + 1 < n_win { energy[w + 1] } else { 0.0 }
                + if w > 0 { energy[w - 1] } else { 0.0 };
            if e < best_e {
                best_e = e;
                best = w;
            }
        }
        out.push(start_win * win..best * win);
        start_win = best;
    }
    out
}

/// Whisper 조각 크기 (약 10분 단위)
pub fn whisper_chunks(s: &[i16]) -> Vec<Range<usize>> {
    chunks(s, 420.0, 600.0)
}

pub fn rms(s: &[i16]) -> f32 {
    if s.is_empty() {
        return 0.0;
    }
    let mut acc = 0f64;
    let mut i = 0;
    while i < s.len() {
        let v = s[i] as f64;
        acc += v * v;
        i += 8;
    }
    (acc / (s.len() / 8).max(1) as f64).sqrt() as f32
}

fn num(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64)
}

/// `-ojf`(토큰 포함) 출력 파싱. 단어 글자는 세그먼트 문장에서, 시간은 DTW 토큰 시간에서 가져온다.
pub fn parse_whisper_full(data: &[u8]) -> Vec<Word> {
    // whisper.cpp 출력에 잘못된 UTF-8이 섞일 수 있어 느슨하게 디코딩
    let text = String::from_utf8_lossy(data);
    let Ok(obj) = serde_json::from_str::<Value>(&text) else {
        return vec![];
    };
    let Some(segs) = obj.get("transcription").and_then(Value::as_array) else {
        return vec![];
    };
    let mut words = vec![];
    for seg in segs {
        let off = seg.get("offsets");
        let seg_from = num(off.and_then(|o| o.get("from"))).unwrap_or(0.0) / 1000.0;
        let seg_to = num(off.and_then(|o| o.get("to"))).unwrap_or(0.0) / 1000.0;
        let seg_text = seg.get("text").and_then(Value::as_str).unwrap_or("").trim();
        let seg_words: Vec<&str> = seg_text
            .split_whitespace()
            .filter(|w| !w.starts_with('['))
            .collect();
        if seg_words.is_empty() {
            continue;
        }
        // 토큰을 단어로 묶기 (앞 공백 = 새 단어)
        let mut starts = vec![];
        let mut saw_token = false;
        for t in seg
            .get("tokens")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[])
        {
            let tt = t.get("text").and_then(Value::as_str).unwrap_or("");
            if tt.starts_with("[_") {
                continue;
            }
            let dtw = num(t.get("t_dtw")).unwrap_or(-1.0);
            let from = num(t.get("offsets").and_then(|o| o.get("from"))).unwrap_or(-1.0);
            let time = if dtw >= 0.0 {
                dtw / 100.0 - 0.15
            } else {
                from / 1000.0
            };
            if tt.starts_with(' ') || !saw_token {
                if tt.trim().is_empty() {
                    continue;
                }
                starts.push(time);
                saw_token = true;
            }
        }
        let times: Vec<f64> = if starts.len() == seg_words.len() {
            starts
        } else {
            // 개수가 안 맞으면 글자 수 비율로 세그먼트 안에 나눈다
            let total = seg_words.iter().map(|w| w.chars().count()).sum::<usize>() as f64;
            let mut acc = 0.0;
            seg_words
                .iter()
                .map(|w| {
                    let t = seg_from + (seg_to - seg_from) * acc / total.max(1.0);
                    acc += w.chars().count() as f64;
                    t
                })
                .collect()
        };
        for (k, w) in seg_words.iter().enumerate() {
            let st = seg_from.max(times[k]);
            let en = if k + 1 < times.len() {
                (st + 0.05).max(times[k + 1])
            } else {
                (st + 0.1).max(seg_to)
            };
            words.push(Word::new(*w, st, en));
        }
    }
    words
}

pub fn fix_overlaps(w: Vec<Word>) -> Vec<Word> {
    let mut out = w;
    out.sort_by(|a, b| a.start.total_cmp(&b.start));
    for i in 0..out.len() {
        if out[i].end <= out[i].start {
            out[i].end = out[i].start + 0.05;
        }
        if i + 1 < out.len() && out[i].end > out[i + 1].start {
            out[i].end = (out[i].start + 0.02).max(out[i + 1].start);
        }
    }
    out
}

/// 단어 시간을 조각 길이 안으로 자른다. Whisper는 마지막 세그먼트 끝을 오디오보다 길게 알려 주기도 해서,
/// 그대로 두면 마지막 단어가 미디어 밖으로 나가 대본에서 사라질 수 있다.
pub fn clamp_to_duration(words: &mut [Word], duration: f64) {
    for w in words {
        w.start = w.start.clamp(0.0, (duration - 0.02).max(0.0));
        w.end = w.end.clamp(w.start + 0.02, duration.max(w.start + 0.02));
    }
}

/// whisper-cli stderr 한 줄에서 "progress = N%" 읽기
pub fn parse_progress(line: &str) -> Option<f64> {
    let i = line.find("progress =")?;
    let digits: String = line[i + 10..]
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse::<f64>().ok().map(|v| (v / 100.0).min(0.99))
}

/// 다운로드 가능한 모델 (맥 앱과 동일)
pub struct WhisperModel {
    pub id: &'static str,
    pub dtw: &'static str,
    pub label: &'static str,
}

pub const MODELS: &[WhisperModel] = &[
    WhisperModel {
        id: "large-v3-turbo-q5_0",
        dtw: "large.v3.turbo",
        label: "Large v3 Turbo (권장, GPU)",
    },
    WhisperModel {
        id: "small",
        dtw: "small",
        label: "Small (CPU 기본)",
    },
    WhisperModel {
        id: "base",
        dtw: "base",
        label: "Base (가장 빠름)",
    },
];

impl WhisperModel {
    pub fn file_name(&self) -> String {
        format!("ggml-{}.bin", self.id)
    }

    pub fn url(&self) -> String {
        format!(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{}",
            self.file_name()
        )
    }
}
