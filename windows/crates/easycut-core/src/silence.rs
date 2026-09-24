//! 음성 인식 없이 오디오 음량(파형)만으로 무음 구간을 찾는다.
//! macOS 앱 `Sources/EasyCut/Engine/SilenceDetector.swift`를 옮겼다.
//! 입력은 8kHz 모노 16비트 PCM (ffmpeg `-ac 1 -ar 8000 -f s16le`).

use crate::model::*;
use crate::timeline_ops::{merge_default, TimeRange};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// 10ms 단위 음량(dBFS)
pub const HOP: f64 = 0.01;
pub const SAMPLE_RATE: usize = 8000;

/// 10ms 단위 RMS 음량(dB)을 누적 계산한다. 샘플을 조각조각 넣을 수 있다.
#[derive(Default)]
pub struct LoudnessMeter {
    acc: f64,
    n: usize,
    pub db: Vec<f32>,
}

impl LoudnessMeter {
    const PER: usize = (SAMPLE_RATE as f64 * HOP) as usize;

    pub fn push(&mut self, samples: &[i16]) {
        for &s in samples {
            let v = s as f64 / 32768.0;
            self.acc += v * v;
            self.n += 1;
            if self.n == Self::PER {
                self.db.push((10.0 * (self.acc / Self::PER as f64).max(1e-10).log10()) as f32);
                self.acc = 0.0;
                self.n = 0;
            }
        }
    }

    pub fn finish(mut self) -> Vec<f32> {
        if self.n > 0 {
            self.db.push((10.0 * (self.acc / self.n as f64).max(1e-10).log10()) as f32);
        }
        self.db
    }
}

pub fn loudness(samples: &[i16]) -> Vec<f32> {
    let mut m = LoudnessMeter::default();
    m.push(samples);
    m.finish()
}

/// 소음 바닥과 말소리 크기를 보고 기준 음량을 자동으로 정한다
pub fn auto_threshold(db: &[f32]) -> f64 {
    let mut valid: Vec<f32> = db.iter().copied().filter(|&v| v > -95.0).collect();
    if valid.len() <= 50 {
        return -40.0;
    }
    valid.sort_by(f32::total_cmp);
    let floor = valid[(valid.len() as f64 * 0.1) as usize] as f64;
    let speech = valid[(valid.len() as f64 * 0.9) as usize] as f64;
    // 바닥과 말소리 사이의 약 1/3 지점, 너무 극단적이지 않게 제한
    (floor + (speech - floor) * 0.33).clamp(-60.0, -25.0)
}

/// 원본 시간 기준 무음 구간 (padding만큼 앞뒤를 남긴다)
pub fn silences(db: &[f32], threshold: f64, min_silence: f64, padding: f64) -> Vec<TimeRange> {
    let mut out = vec![];
    let mut start: Option<usize> = None;
    let th = threshold as f32;
    for i in 0..=db.len() {
        let quiet = i < db.len() && db[i] < th;
        if quiet {
            if start.is_none() {
                start = Some(i);
            }
        } else if let Some(s) = start {
            let len = (i - s) as f64 * HOP;
            if len >= min_silence {
                let a = s as f64 * HOP + if s == 0 { 0.0 } else { padding };
                let b = i as f64 * HOP - if i == db.len() { 0.0 } else { padding };
                if b - a > 0.05 {
                    out.push(TimeRange::new(a, b));
                }
            }
            start = None;
        }
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SilenceSettings {
    pub threshold: f64,
    pub min_silence: f64,
    pub padding: f64,
}

impl Default for SilenceSettings {
    fn default() -> Self {
        SilenceSettings { threshold: -40.0, min_silence: 0.6, padding: 0.12 }
    }
}

impl Project {
    /// 기본 트랙(트랙 1)의 소리 있는 클립 기준으로 무음을 타임라인 구간으로 변환
    pub fn audio_silence_ranges(&self, loudness: &HashMap<Id, Vec<f32>>, settings: &SilenceSettings) -> Vec<TimeRange> {
        let mut ranges = vec![];
        for track in self.tracks.iter().take(1).filter(|t| !t.muted) {
            for c in track.clips.iter().filter(|c| c.kind == ClipKind::Media) {
                let Some(a) = self.asset(c.asset_id) else { continue };
                if !a.has_audio {
                    continue;
                }
                let Some(db) = loudness.get(&a.id) else { continue };
                for r in silences(db, settings.threshold, settings.min_silence * c.speed, settings.padding * c.speed) {
                    let s0 = r.start.max(c.source_in);
                    let s1 = r.end.min(c.source_out);
                    if s1 - s0 <= 0.05 {
                        continue;
                    }
                    // 클립 경계에 걸친 부분은 여유를 다시 계산하지 않고 그대로 자른다
                    ranges.push(TimeRange::new(c.timeline_time(s0), c.timeline_time(s1)));
                }
            }
        }
        merge_default(&ranges)
    }
}
