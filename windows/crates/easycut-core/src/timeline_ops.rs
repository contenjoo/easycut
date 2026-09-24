//! 타임라인 편집 연산. 모든 시간은 초 단위.
//! macOS 앱 `Sources/EasyCut/Model/TimelineOps.swift`를 그대로 옮겼다.

use crate::model::*;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashSet;

pub const MIN_CLIP_DURATION: f64 = 0.04;
pub const EPS: f64 = 0.0005;

/// 닫힌 시간 구간 [start, end]
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TimeRange {
    pub start: f64,
    pub end: f64,
}

impl TimeRange {
    pub fn new(start: f64, end: f64) -> Self {
        TimeRange { start, end }
    }

    pub fn len(&self) -> f64 {
        self.end - self.start
    }
}

/// 가까운 구간 합치기 (gap 이내로 붙은 구간은 하나로)
pub fn merge(ranges: &[TimeRange], gap: f64) -> Vec<TimeRange> {
    let mut sorted: Vec<TimeRange> = ranges
        .iter()
        .copied()
        .filter(|r| r.end - r.start > 0.001)
        .collect();
    sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut out: Vec<TimeRange> = vec![];
    for r in sorted {
        match out.last_mut() {
            Some(last) if r.start <= last.end + gap => last.end = last.end.max(r.end),
            _ => out.push(r),
        }
    }
    out
}

/// 기본 간격(0.01초)으로 합치기
pub fn merge_default(ranges: &[TimeRange]) -> Vec<TimeRange> {
    merge(ranges, 0.01)
}

fn track_name(n: usize) -> String {
    format!("트랙 {n}")
}

impl Project {
    fn ensure_track(&mut self, ti: usize) {
        while self.tracks.len() <= ti {
            let n = self.tracks.len() + 1;
            self.tracks.push(Track::named(track_name(n)));
        }
    }

    // MARK: 정리

    pub fn normalize(&mut self) {
        for t in &mut self.tracks {
            t.clips.retain(|c| c.duration() >= MIN_CLIP_DURATION);
            for c in &mut t.clips {
                if c.start < 0.0 {
                    c.start = 0.0;
                }
            }
            t.clips.sort_by(|a, b| a.start.total_cmp(&b.start));
        }
        self.captions
            .retain(|c| c.end - c.start >= 0.05 && !c.text.trim().is_empty());
        self.captions.sort_by(|a, b| a.start.total_cmp(&b.start));
    }

    /// 겹치는 클립은 뒤로 밀어서 한 트랙 안에서 겹치지 않도록 한다.
    pub fn resolve_overlaps(&mut self, ti: usize, pinned: Option<Id>) {
        let Some(track) = self.tracks.get_mut(ti) else {
            return;
        };
        track.clips.sort_by(|a, b| {
            if (a.start - b.start).abs() < EPS {
                let ap = Some(a.id) == pinned;
                let bp = Some(b.id) == pinned;
                return match (ap, bp) {
                    (true, false) => Ordering::Less,
                    (false, true) => Ordering::Greater,
                    _ => Ordering::Equal,
                };
            }
            a.start.total_cmp(&b.start)
        });
        let mut cursor = 0.0_f64;
        for c in &mut track.clips {
            if c.start < cursor - EPS {
                c.start = cursor;
            }
            cursor = cursor.max(c.end());
        }
    }

    // MARK: 추가

    pub fn insert(&mut self, asset: &MediaAsset, ti: usize, time: f64, image_duration: f64) -> Id {
        self.ensure_track(ti);
        let dur = if asset.kind == MediaKind::Image {
            image_duration
        } else {
            asset.duration
        };
        let clip = Clip {
            asset_id: Some(asset.id),
            start: time.max(0.0),
            source_in: 0.0,
            source_out: dur,
            ..Clip::default()
        };
        let id = clip.id;
        self.tracks[ti].clips.push(clip);
        self.resolve_overlaps(ti, Some(id));
        id
    }

    pub fn insert_text(&mut self, text: &str, ti: usize, time: f64, duration: f64) -> Id {
        self.ensure_track(ti);
        let clip = Clip {
            kind: ClipKind::Text,
            text: text.to_string(),
            text_style: TextStyle::title(),
            start: time.max(0.0),
            source_in: 0.0,
            source_out: duration,
            ..Clip::default()
        };
        let id = clip.id;
        self.tracks[ti].clips.push(clip);
        self.resolve_overlaps(ti, Some(id));
        id
    }

    pub fn track_end(&self, ti: usize) -> f64 {
        self.tracks
            .get(ti)
            .map(|t| t.clips.iter().map(Clip::end).fold(0.0, f64::max))
            .unwrap_or(0.0)
    }

    // MARK: 분할

    /// 클립을 t 지점에서 둘로 나눈다. 새 오른쪽 클립 id를 돌려준다.
    pub fn split(&mut self, id: Id, t: f64) -> Option<Id> {
        let (ti, ci) = self.locate(id)?;
        let c = self.tracks[ti].clips[ci].clone();
        if !(t > c.start + MIN_CLIP_DURATION && t < c.end() - MIN_CLIP_DURATION) {
            return None;
        }
        let cut = c.source_time(t);
        let mut left = c.clone();
        let mut right = c;
        left.source_out = cut;
        left.fade_out = 0.0;
        right.id = Id::new();
        right.source_in = cut;
        right.start = t;
        right.fade_in = 0.0;
        let rid = right.id;
        self.tracks[ti].clips[ci] = left;
        self.tracks[ti].clips.insert(ci + 1, right);
        Some(rid)
    }

    pub fn split_all(&mut self, t: f64, only: Option<&HashSet<usize>>) {
        for ti in 0..self.tracks.len() {
            if only.is_some_and(|s| !s.contains(&ti)) {
                continue;
            }
            let ids: Vec<Id> = self.tracks[ti]
                .clips
                .iter()
                .filter(|c| t > c.start && t < c.end())
                .map(|c| c.id)
                .collect();
            for id in ids {
                self.split(id, t);
            }
        }
    }

    // MARK: 삭제

    /// 선택 클립 삭제. ripple이면 같은 트랙의 뒤 클립을 당겨 빈틈을 없앤다.
    pub fn delete_clips(&mut self, ids: &HashSet<Id>, ripple: bool) {
        for t in &mut self.tracks {
            let mut removed: Vec<Clip> = t
                .clips
                .iter()
                .filter(|c| ids.contains(&c.id))
                .cloned()
                .collect();
            if removed.is_empty() {
                continue;
            }
            removed.sort_by(|a, b| b.start.total_cmp(&a.start));
            t.clips.retain(|c| !ids.contains(&c.id));
            if ripple {
                for r in &removed {
                    for c in &mut t.clips {
                        if c.start >= r.end() - EPS {
                            c.start -= r.duration();
                        }
                    }
                }
            }
        }
    }

    /// 모든 트랙과 자막에서 [t0, t1) 구간을 잘라내고 뒤를 당긴다.
    pub fn ripple_delete(&mut self, t0: f64, t1: f64) {
        let a = t0.min(t1).max(0.0);
        let b = t0.max(t1);
        let len = b - a;
        if len <= EPS {
            return;
        }
        self.split_all(a, None);
        self.split_all(b, None);
        for t in &mut self.tracks {
            t.clips
                .retain(|c| !(c.start >= a - EPS && c.end() <= b + EPS));
            for c in &mut t.clips {
                if c.start >= b - EPS {
                    c.start -= len;
                }
            }
        }
        let mut out = vec![];
        for mut c in std::mem::take(&mut self.captions) {
            if c.end <= a {
                out.push(c);
                continue;
            }
            if c.start >= b {
                c.start -= len;
                c.end -= len;
                out.push(c);
                continue;
            }
            // 구간과 겹침
            let keep_before = (a - c.start).max(0.0);
            let keep_after = (c.end - b).max(0.0);
            if keep_before + keep_after < 0.2 {
                continue;
            }
            c.start = c.start.min(a);
            c.end = c.start + keep_before + keep_after;
            out.push(c);
        }
        self.captions = out;
        self.normalize();
    }

    /// 여러 구간을 뒤에서부터 잘라낸다.
    pub fn ripple_delete_ranges(&mut self, ranges: &[TimeRange]) {
        for r in merge_default(ranges).iter().rev() {
            self.ripple_delete(r.start, r.end);
        }
    }

    // MARK: 구간째 옮기기 (자막 단위 순서 바꾸기)

    /// 타임라인 [a, b) 구간을 모든 트랙·자막째 떼어 내 t 지점(현재 타임라인 기준)에 끼워 넣는다.
    pub fn move_range(&mut self, a: f64, b: f64, t: f64) {
        let len = b - a;
        if !(len > EPS && (t < a - EPS || t > b + EPS)) {
            return;
        }
        self.split_all(a, None);
        self.split_all(b, None);
        let mut moved: Vec<(usize, Clip)> = vec![];
        for (ti, track) in self.tracks.iter().enumerate() {
            for c in &track.clips {
                if c.start >= a - EPS && c.end() <= b + EPS {
                    let mut n = c.clone();
                    n.start -= a;
                    moved.push((ti, n));
                }
            }
        }
        let moved_caps: Vec<Caption> = self
            .captions
            .iter()
            .filter(|c| c.start >= a - EPS && c.end <= b + EPS)
            .map(|c| {
                let mut n = c.clone();
                n.start -= a;
                n.end -= a;
                n
            })
            .collect();
        self.ripple_delete(a, b);
        let ins = if t > b { t - len } else { t };
        self.split_all(ins, None);
        for track in &mut self.tracks {
            for c in &mut track.clips {
                if c.start >= ins - EPS {
                    c.start += len;
                }
            }
        }
        for c in &mut self.captions {
            if c.start >= ins - EPS {
                c.start += len;
                c.end += len;
            } else if c.end > ins {
                c.end += len; // 끼워 넣는 지점에 걸친 자막은 늘려 준다
            }
        }
        for (ti, mut c) in moved {
            c.start += ins;
            self.tracks[ti].clips.push(c);
        }
        for mut c in moved_caps {
            c.start += ins;
            c.end += ins;
            self.captions.push(c);
        }
        self.normalize();
    }

    /// 자막 하나가 차지하는 영상 구간 (다음 자막 직전까지 포함해 어색한 공백을 남기지 않는다)
    pub fn span_of_caption(&self, id: Id) -> Option<TimeRange> {
        let mut sorted: Vec<&Caption> = self.captions.iter().collect();
        sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
        let i = sorted.iter().position(|c| c.id == id)?;
        let c = sorted[i];
        let mut end = c.end;
        if i + 1 < sorted.len() {
            let next = sorted[i + 1].start;
            // 문장 뒤 쉬는 시간(3초 이내)도 그 문장과 함께 옮기거나 지운다
            if next - c.end < 3.0 {
                end = c.end.max(next);
            }
        }
        end = end.min(self.duration().max(c.end));
        Some(TimeRange::new(c.start, end.max(c.start + 0.05)))
    }

    /// 기본 트랙 클립을 떨어뜨린 위치(포인터 시각)에 맞춰 순서를 바꾼다
    pub fn reorder(&mut self, id: Id, pointer: f64) {
        let Some((ti, ci)) = self.locate(id) else {
            return;
        };
        let c = self.tracks[ti].clips[ci].clone();
        let has_others = self.tracks[ti].clips.iter().any(|o| o.id != id);
        let Some(target) = self.insertion_point(ti, id, pointer) else {
            return;
        };
        if !has_others {
            return;
        }
        self.move_range(c.start, c.end(), target);
    }

    /// 포인터 아래 클립의 앞/뒤 경계 (앞쪽 절반이면 앞, 뒤쪽 절반이면 뒤)
    pub fn insertion_point(&self, ti: usize, excluding: Id, t: f64) -> Option<f64> {
        let others: Vec<&Clip> = self
            .tracks
            .get(ti)?
            .clips
            .iter()
            .filter(|c| c.id != excluding)
            .collect();
        if let Some(under) = others.iter().find(|c| t >= c.start && t < c.end()) {
            return Some(if t < (under.start + under.end()) / 2.0 {
                under.start
            } else {
                under.end()
            });
        }
        let mut bounds = vec![0.0];
        for o in &others {
            bounds.push(o.start);
            bounds.push(o.end());
        }
        // Swift `min(by:)`와 같이 거리가 같으면 앞의 값을 고른다
        let mut best = bounds[0];
        for &v in &bounds[1..] {
            if (v - t).abs() < (best - t).abs() {
                best = v;
            }
        }
        Some(best)
    }

    // MARK: 이동 / 트림

    pub fn move_clip(&mut self, id: Id, new_track: usize, start: f64) {
        let Some((ti, ci)) = self.locate(id) else {
            return;
        };
        let mut c = self.tracks[ti].clips.remove(ci);
        c.start = start.max(0.0);
        self.ensure_track(new_track);
        self.tracks[new_track].clips.push(c);
        self.resolve_overlaps(new_track, Some(id));
    }

    /// 왼쪽 가장자리를 새 타임라인 위치로 트림.
    pub fn trim_start(&mut self, id: Id, new_start: f64, max_source: Option<f64>) {
        let Some((ti, ci)) = self.locate(id) else {
            return;
        };
        let mut c = self.tracks[ti].clips[ci].clone();
        let prev_end = self.tracks[ti]
            .clips
            .iter()
            .filter(|o| o.id != id && o.end() <= c.start + EPS)
            .map(Clip::end)
            .fold(0.0, f64::max);
        let mut s = new_start.max(prev_end).min(c.end() - MIN_CLIP_DURATION);
        if c.kind == ClipKind::Media && max_source.is_some() {
            // 원본 시작보다 앞으로 늘릴 수 없다
            let earliest = c.start - c.source_in / c.speed;
            s = s.max(earliest);
            c.source_in = c.source_time(s);
            c.start = s;
        } else {
            let end = c.end();
            c.start = s;
            c.source_in = 0.0;
            c.source_out = end - s;
        }
        self.tracks[ti].clips[ci] = c;
    }

    /// 오른쪽 가장자리를 새 타임라인 위치로 트림.
    pub fn trim_end(&mut self, id: Id, new_end: f64, max_source: Option<f64>) {
        let Some((ti, ci)) = self.locate(id) else {
            return;
        };
        let mut c = self.tracks[ti].clips[ci].clone();
        let next_start = self.tracks[ti]
            .clips
            .iter()
            .filter(|o| o.id != id && o.start >= c.end() - EPS)
            .map(|o| o.start)
            .fold(f64::INFINITY, f64::min);
        let mut e = new_end.min(next_start).max(c.start + MIN_CLIP_DURATION);
        if let Some(ms) = max_source {
            e = e.min(c.timeline_time(ms));
        }
        c.source_out = c.source_time(e);
        self.tracks[ti].clips[ci] = c;
    }

    /// 속도 변경. 같은 트랙의 뒤 클립은 길이 변화만큼 당기거나 민다.
    pub fn set_speed(&mut self, id: Id, speed: f64) {
        let Some((ti, ci)) = self.locate(id) else {
            return;
        };
        let old = self.tracks[ti].clips[ci].clone();
        let mut c = old.clone();
        c.speed = speed.clamp(0.1, 20.0);
        let delta = c.end() - old.end();
        self.tracks[ti].clips[ci] = c;
        for o in &mut self.tracks[ti].clips {
            if o.id != id && o.start >= old.end() - EPS {
                o.start += delta;
            }
        }
        self.resolve_overlaps(ti, Some(id));
    }

    /// 클립 경계 목록 (편집 지점 이동용)
    pub fn edit_points(&self) -> Vec<f64> {
        let mut pts = vec![0.0];
        for c in self.tracks.iter().flat_map(|t| t.clips.iter()) {
            pts.push(c.start);
            pts.push(c.end());
        }
        pts.sort_by(f64::total_cmp);
        pts.dedup();
        pts
    }
}
