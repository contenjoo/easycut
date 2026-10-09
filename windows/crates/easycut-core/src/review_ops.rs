//! 편집 검토: 클립 경계 조정과 잘린 구간 되살리기. 맥 `TimelineOps.swift`의 adjustEdge·cutPoints·restoreCut과 같다.

use crate::model::*;
use crate::timeline_ops::{EPS, MIN_CLIP_DURATION};

/// 같은 원본을 잘라 이어 붙인 경계
#[derive(Clone, Debug, PartialEq)]
pub struct CutPoint {
    pub left: Id,
    pub right: Id,
    pub track: usize,
    pub time: f64,
    /// 잘린 원본 구간 (초)
    pub gap: (f64, f64),
}

impl Project {
    /// t 이후에 시작하는 모든 클립(except 제외)과 자막을 d초 민다
    pub fn ripple_shift(&mut self, t: f64, d: f64, except: Option<Id>) {
        if d.abs() < 1e-9 {
            return;
        }
        for tr in &mut self.tracks {
            for c in &mut tr.clips {
                if Some(c.id) != except && c.start >= t - EPS {
                    c.start += d;
                }
            }
        }
        for c in &mut self.captions {
            if c.start >= t - EPS {
                c.start += d;
                c.end += d;
            }
        }
    }

    /// 클립 가장자리를 원본 기준 seconds만큼 늘리거나(+) 줄인다(−). 뒤의 영상·자막도 함께 밀리거나 당겨진다.
    /// 돌려주는 값: 실제로 바뀐 원본 초
    pub fn adjust_edge(&mut self, id: Id, at_end: bool, seconds: f64, source_duration: f64) -> f64 {
        let Some(c) = self.clip(id).cloned() else { return 0.0 };
        if c.kind != ClipKind::Media {
            return 0.0;
        }
        if seconds >= 0.0 {
            let x = if at_end { seconds.min((source_duration - c.source_out).max(0.0)) } else { seconds.min(c.source_in.max(0.0)) };
            if x <= 1e-6 {
                return 0.0;
            }
            let t = if at_end { c.end() } else { c.start };
            if let Some(m) = self.clip_mut(id) {
                if at_end { m.source_out += x } else { m.source_in -= x }
            }
            self.ripple_shift(t, x / c.speed, Some(id));
            return x;
        }
        // 줄이기: 이 클립만 줄이고, 클립 끝 뒤에 시작하는 것만 당긴다 (다른 트랙의 배경음악 등은 자르지 않는다)
        let x = (-seconds).min(((c.source_out - c.source_in) - MIN_CLIP_DURATION * c.speed).max(0.0));
        if x <= 1e-6 {
            return 0.0;
        }
        if let Some(m) = self.clip_mut(id) {
            if at_end { m.source_out -= x } else { m.source_in += x }
        }
        self.ripple_shift(c.end(), -x / c.speed, Some(id));
        for ti in 0..self.tracks.len() {
            self.resolve_overlaps(ti, None);
        }
        -x
    }

    pub fn cut_points(&self, only: Option<usize>) -> Vec<CutPoint> {
        let mut out = vec![];
        for (ti, t) in self.tracks.iter().enumerate() {
            if only.is_some_and(|o| o != ti) {
                continue;
            }
            let mut clips: Vec<&Clip> = t.clips.iter().collect();
            clips.sort_by(|a, b| a.start.total_cmp(&b.start));
            for w in clips.windows(2) {
                let (a, b) = (w[0], w[1]);
                if a.kind == ClipKind::Media && b.kind == ClipKind::Media && a.asset_id.is_some() && a.asset_id == b.asset_id
                    && (a.end() - b.start).abs() < 0.01 && (a.speed - b.speed).abs() < 0.0001 && b.source_in > a.source_out + 0.001
                {
                    out.push(CutPoint { left: a.id, right: b.id, track: ti, time: b.start, gap: (a.source_out, b.source_in) });
                }
            }
        }
        out.sort_by(|a, b| a.time.total_cmp(&b.time));
        out
    }

    /// 잘린 경계에서 원본을 되살린다. 둘 다 None이면 잘린 구간 전체를 되살리고 두 클립을 합친다.
    pub fn restore_cut(&mut self, cp: &CutPoint, before: Option<f64>, after: Option<f64>) -> Vec<(f64, f64)> {
        let gap = cp.gap.1 - cp.gap.0;
        let b = before.unwrap_or(if after.is_none() { gap } else { 0.0 }).clamp(0.0, gap);
        let a = after.unwrap_or(0.0).clamp(0.0, gap - b);
        let mut out = vec![];
        if b > 1e-6 {
            self.adjust_edge(cp.left, true, b, f64::INFINITY);
            out.push((cp.gap.0, cp.gap.0 + b));
        }
        if a > 1e-6 {
            self.adjust_edge(cp.right, false, a, f64::INFINITY);
            out.push((cp.gap.1 - a, cp.gap.1));
        }
        // 빈틈 없이 이어지면 한 클립으로
        if let (Some(l), Some(r)) = (self.clip(cp.left).cloned(), self.clip(cp.right).cloned()) {
            let alike = l.volume == r.volume && l.opacity == r.opacity && l.scale == r.scale && l.offset_x == r.offset_x && l.offset_y == r.offset_y
                && ["shape", "backgroundEffect", "showClicks"].iter().all(|k| l.extra.get(*k) == r.extra.get(*k));
            if alike && (r.source_in - l.source_out).abs() < 0.0005 && (l.end() - r.start).abs() < 0.01 {
                let mut blurs = l.blurs();
                for x in r.blurs() {
                    if !blurs.iter().any(|y| y.id == x.id) {
                        blurs.push(x);
                    }
                }
                if let Some(m) = self.clip_mut(cp.left) {
                    m.source_out = r.source_out;
                    m.fade_out = r.fade_out;
                    m.set_blurs(blurs);
                }
                for t in &mut self.tracks {
                    t.clips.retain(|c| c.id != cp.right);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project() -> Project {
        let mut p = Project::default();
        let a = MediaAsset { path: "/tmp/x.mp4".into(), name: "x".into(), kind: MediaKind::Video, duration: 10.0, width: 1920.0, height: 1080.0, has_audio: true, ..Default::default() };
        p.assets.push(a.clone());
        p.insert(&a, 0, 0.0, 5.0);
        p.captions = vec![Caption::new(1.0, 2.0, "앞"), Caption::new(6.0, 7.0, "뒤")];
        p.ripple_delete(3.0, 5.0);
        p
    }

    #[test]
    fn same_as_mac() {
        let m = project();
        let cps = m.cut_points(None);
        assert_eq!(cps.len(), 1);
        assert_eq!(cps[0].gap, (3.0, 5.0));
        assert!((m.duration() - 8.0).abs() < 1e-9);

        let mut part = m.clone();
        part.restore_cut(&cps[0], Some(0.5), Some(0.25));
        let c = &part.tracks[0].clips;
        assert_eq!(c.len(), 2);
        assert!((c[0].source_out - 3.5).abs() < 1e-9 && (c[1].source_in - 4.75).abs() < 1e-9);
        assert!((part.duration() - 8.75).abs() < 1e-9 && (part.captions[1].start - 4.75).abs() < 1e-9);

        let mut full = m.clone();
        full.restore_cut(&cps[0], None, None);
        assert_eq!(full.tracks[0].clips.len(), 1);
        assert!((full.duration() - 10.0).abs() < 1e-9 && (full.captions[1].start - 6.0).abs() < 1e-9);

        // 경계 0.02초 뒤부터 자르기 (장면 저장·구간 내보내기)
        let mut edge = m.clone();
        edge.ripple_delete(0.0, 3.02);
        edge.normalize();
        assert_eq!(edge.tracks[0].clips.len(), 1);
        assert!((edge.tracks[0].clips[0].source_in - 5.02).abs() < 1e-6 && edge.tracks[0].clips[0].start.abs() < 1e-9);

        // 늘렸다 줄이기: 다른 트랙(배경음악)은 잘리지 않고 원래대로
        let mut bgm = m.clone();
        let music = MediaAsset { path: "/tmp/m.m4a".into(), name: "m".into(), kind: MediaKind::Audio, duration: 30.0, has_audio: true, ..Default::default() };
        bgm.assets.push(music.clone());
        let mid = bgm.insert(&music, 1, 0.0, 5.0);
        bgm.clip_mut(mid).unwrap().source_out = 8.0;
        let snapshot = bgm.clone();
        let right = cps[0].right;
        bgm.adjust_edge(right, false, 1.0, 10.0);
        bgm.adjust_edge(right, false, -1.0, 10.0);
        assert_eq!(bgm.tracks[1].clips.len(), 1);
        assert_eq!(bgm.tracks[1].clips[0].source_out, 8.0);
        assert_eq!(bgm.clip(right).unwrap().source_in, 5.0);
        assert!((bgm.duration() - snapshot.duration()).abs() < 1e-9);

        let id = full.tracks[0].clips[0].id;
        full.adjust_edge(id, true, -1.0, 10.0);
        assert!((full.duration() - 9.0).abs() < 1e-9);
        let grow = full.adjust_edge(id, true, 5.0, 10.0);
        assert!((grow - 1.0).abs() < 1e-9 && (full.duration() - 10.0).abs() < 1e-9);
    }
}

// MARK: 자막 시간 검사 (맥 CaptionSync.swift와 같음)

/// 자막 하나의 측정: + = 자막이 말보다 빠름 (늦춰야 함)
#[derive(Clone, Debug, PartialEq)]
pub struct SyncMeasure {
    pub index: usize,
    pub caption_start: f64,
    pub onset: f64,
}

impl SyncMeasure {
    pub fn offset(&self) -> f64 {
        self.onset - self.caption_start
    }
}

#[derive(Clone, Debug, Default)]
pub struct SyncReport {
    pub measures: Vec<SyncMeasure>,
    pub skipped: usize,
    pub median: f64,
    pub spread: f64,
}

impl SyncReport {
    /// 차이가 거의 일정하면 한꺼번에 옮기면 된다
    pub fn consistent(&self) -> bool {
        self.measures.len() >= 3 && self.spread <= 0.06
    }
}

impl Project {
    /// t에 소리가 나는 클립 (아래 트랙부터, 음소거 제외)
    pub fn audible_clip(&self, t: f64) -> Option<&Clip> {
        self.tracks.iter().filter(|tr| !tr.muted).find_map(|tr| {
            tr.clips.iter().find(|c| c.kind == ClipKind::Media && t >= c.start - 0.001 && t < c.end() && c.volume > 0.001 && self.asset(c.asset_id).is_some_and(|a| a.has_audio))
        })
    }

    /// 자막마다 근처(±window초)에서 조용하다가 소리가 나기 시작한 곳 중 앞의 조용함이 가장 긴 곳을 말 시작으로 본다
    pub fn caption_sync(&self, loudness: &std::collections::HashMap<Id, Vec<f32>>, thresholds: &std::collections::HashMap<Id, f64>, from: f64, to: f64, window: f64) -> SyncReport {
        let hop = crate::silence::HOP;
        let mut r = SyncReport::default();
        for (n, cap) in self.captions.iter().enumerate() {
            if cap.start < from || cap.start >= to {
                continue;
            }
            let Some(c) = self.audible_clip(cap.start + 0.001).or_else(|| self.audible_clip(cap.start + window / 2.0)) else { r.skipped += 1; continue };
            let (Some(db), Some(&th)) = (c.asset_id.and_then(|a| loudness.get(&a)), c.asset_id.and_then(|a| thresholds.get(&a))) else { r.skipped += 1; continue };
            let s = c.source_time(cap.start);
            let (lo, hi) = ((s - window * c.speed).max(c.source_in), (s + window * c.speed).min(c.source_out));
            let i0 = ((lo / hop) as usize).max(1);
            let i1 = ((hi / hop) as usize).min(db.len().saturating_sub(4));
            if i1 <= i0 {
                r.skipped += 1;
                continue;
            }
            let below = |k: usize| (db[k] as f64) < th;
            let back = i0.saturating_sub(100);
            let mut quiet = (back..i0).rev().take_while(|&k| below(k)).count();
            if quiet == i0 - back && i0 < 100 {
                quiet = 100; // 파일 맨 앞까지 조용함
            }
            let mut best: Option<(usize, usize)> = None;
            for i in i0..=i1 {
                if below(i) {
                    quiet += 1;
                    continue;
                }
                if quiet >= 12 && (i..i + 4).all(|k| !below(k)) {
                    let q = quiet.min(100);
                    let t = i as f64 * hop;
                    let better = match best {
                        None => true,
                        Some((bi, bq)) => q > bq || (q == bq && (t - s).abs() < (bi as f64 * hop - s).abs()),
                    };
                    if better {
                        best = Some((i, q));
                    }
                }
                quiet = 0;
            }
            let Some((b, _)) = best else { r.skipped += 1; continue };
            let onset = c.timeline_time(b as f64 * hop);
            // 앞뒤 자막의 말 시작을 잡았으면 이 자막은 문장 중간이라 잴 수 없다
            let prev_end = n.checked_sub(1).map(|k| self.captions[k].end);
            let next_end = self.captions.get(n + 1).map(|x| x.end);
            if prev_end.is_some_and(|p| onset < p - 0.35) || next_end.is_some_and(|x| onset > x - 0.1) {
                r.skipped += 1;
                continue;
            }
            r.measures.push(SyncMeasure { index: n, caption_start: cap.start, onset });
        }
        let mut offs: Vec<f64> = r.measures.iter().map(|m| m.offset()).collect();
        offs.sort_by(f64::total_cmp);
        r.median = offs.get(offs.len() / 2).copied().unwrap_or(0.0);
        let mut dev: Vec<f64> = offs.iter().map(|o| (o - r.median).abs()).collect();
        dev.sort_by(f64::total_cmp);
        r.spread = dev.get(dev.len() / 2).copied().unwrap_or(0.0);
        r
    }

    /// 자막을 d초 옮긴다 (+ = 늦추기)
    pub fn shift_captions(&mut self, d: f64, from: f64, to: f64) {
        for c in &mut self.captions {
            if c.start >= from && c.start < to {
                let len = c.end - c.start;
                c.start = (c.start + d).max(0.0);
                c.end = c.start + len;
            }
        }
        self.captions.sort_by(|a, b| a.start.total_cmp(&b.start));
    }

    /// 잰 자막마다 시작을 실제 말 시작에 맞춘다 (앞 자막과 겹치지 않게, 늦출 때는 길이 유지)
    pub fn snap_captions(&mut self, measures: &[SyncMeasure]) {
        for m in measures {
            // 재는 동안 자막이 바뀌었으면(지우거나 옮김) 그 자막은 건드리지 않는다
            if m.index >= self.captions.len() || (self.captions[m.index].start - m.caption_start).abs() >= 0.0005 {
                continue;
            }
            let mut start = m.onset;
            // 앞 자막이 말 시작을 덮고 있으면 앞 자막 끝을 줄인다 (최소 0.3초는 남김)
            if m.index > 0 && self.captions[m.index - 1].end > start {
                let prev = &mut self.captions[m.index - 1];
                prev.end = (prev.start + 0.3).max(start);
                start = start.max(prev.end);
            }
            let c = &self.captions[m.index];
            let mut end = c.end + (start - c.start).max(0.0);
            if let Some(next) = self.captions.get(m.index + 1) {
                end = end.min(next.start);
            }
            let c = &mut self.captions[m.index];
            c.start = start;
            c.end = end.max(start + 0.3);
        }
    }
}

#[cfg(test)]
mod sync_tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn finds_speech_start_after_longest_pause() {
        // 0~1초 조용, 1~2초 말(1.4초에 짧은 틈), 2~3초 조용, 3~4초 말
        let mut db = vec![-80f32; 400];
        for (i, v) in db.iter_mut().enumerate() {
            let t = i as f64 * 0.01;
            if (1.0..2.0).contains(&t) && !(1.4..1.55).contains(&t) || (3.0..4.0).contains(&t) {
                *v = -20.0;
            }
        }
        let a = MediaAsset { path: "/x.wav".into(), name: "x".into(), kind: MediaKind::Audio, duration: 4.0, has_audio: true, ..Default::default() };
        let mut p = Project::default();
        p.assets.push(a.clone());
        p.insert(&a, 0, 0.0, 5.0);
        p.captions = vec![Caption::new(0.8, 1.45, "하나"), Caption::new(1.45, 1.9, "중간"), Caption::new(3.2, 3.9, "둘")];
        let loud: HashMap<Id, Vec<f32>> = [(a.id, db)].into();
        let th: HashMap<Id, f64> = [(a.id, -50.0)].into();
        let r = p.caption_sync(&loud, &th, 0.0, f64::INFINITY, 0.6);
        let offs: Vec<(usize, f64)> = r.measures.iter().map(|m| (m.index, (m.offset() * 100.0).round() / 100.0)).collect();
        assert_eq!(offs, vec![(0, 0.2), (2, -0.2)]);
        assert_eq!(r.skipped, 1);
        p.snap_captions(&r.measures);
        assert!((p.captions[0].start - 1.0).abs() < 1e-9 && (p.captions[2].start - 3.0).abs() < 1e-9);
        // 앞 자막 끝이 말 시작을 덮고 있으면 줄여서 맞춘다
        let mut q = p.clone();
        q.captions[1].end = 3.15;
        q.captions[2].start = 3.2;
        let m = SyncMeasure { index: 2, caption_start: q.captions[2].start, onset: 3.0 };
        q.snap_captions(&[m]);
        assert!((q.captions[2].start - 3.0).abs() < 1e-9 && (q.captions[1].end - 3.0).abs() < 1e-9);
        // 재는 동안 바뀐 자막은 건드리지 않는다
        let mut z = q.clone();
        let stale = SyncMeasure { index: 2, caption_start: 9.9, onset: 2.5 };
        z.snap_captions(&[stale]);
        assert_eq!(z.captions[2].start, q.captions[2].start);
        p.shift_captions(0.5, 0.0, f64::INFINITY);
        assert!((p.captions[2].start - 3.5).abs() < 1e-9);
    }
}
