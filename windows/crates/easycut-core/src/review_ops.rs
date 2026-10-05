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
        let x = (-seconds).min(((c.source_out - c.source_in) - MIN_CLIP_DURATION * c.speed).max(0.0));
        if x <= 1e-6 {
            return 0.0;
        }
        let d = x / c.speed;
        if at_end { self.ripple_delete(c.end() - d, c.end()) } else { self.ripple_delete(c.start, c.start + d) }
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

        let id = full.tracks[0].clips[0].id;
        full.adjust_edge(id, true, -1.0, 10.0);
        assert!((full.duration() - 9.0).abs() < 1e-9);
        let grow = full.adjust_edge(id, true, 5.0, 10.0);
        assert!((grow - 1.0).abs() < 1e-9 && (full.duration() - 10.0).abs() < 1e-9);
    }
}
