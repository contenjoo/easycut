//! 그룹 · 합치기 · 복제 · 붙여넣기 · 트랙 정리.
//! macOS 앱 `TimelineOps.swift`(group/ungroup/groupMembers/join)와 `EditorStore.swift`(duplicate/paste/tracks)를 옮겼다.
//! 그룹은 맥 파일 형식 그대로 클립의 `groupID`(대문자 UUID)로 저장한다.

use crate::model::*;
use crate::timeline_ops::EPS;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

const GROUP_KEY: &str = "groupID";

impl Clip {
    pub fn group_id(&self) -> Option<&str> {
        self.extra.get(GROUP_KEY).and_then(Value::as_str)
    }

    pub fn set_group_id(&mut self, g: Option<&str>) {
        match g {
            Some(g) => {
                self.extra.insert(GROUP_KEY.into(), Value::String(g.to_string()));
            }
            None => {
                self.extra.remove(GROUP_KEY);
            }
        }
    }
}

fn new_group() -> String {
    Id::new().to_string()
}

impl Project {
    /// 선택에 그룹 동료를 더한 집합
    pub fn group_members(&self, ids: &HashSet<Id>) -> HashSet<Id> {
        let all: Vec<&Clip> = self.tracks.iter().flat_map(|t| &t.clips).collect();
        let groups: HashSet<&str> = all.iter().filter(|c| ids.contains(&c.id)).filter_map(|c| c.group_id()).collect();
        let mut out = ids.clone();
        if !groups.is_empty() {
            out.extend(all.iter().filter(|c| c.group_id().is_some_and(|g| groups.contains(g))).map(|c| c.id));
        }
        out
    }

    /// 선택한 클립에 같은 그룹을 달아 함께 선택·이동되게 한다 (2개 이상)
    pub fn group(&mut self, ids: &HashSet<Id>) -> bool {
        let all = self.group_members(ids);
        if all.len() < 2 {
            return false;
        }
        let gid = new_group();
        for c in self.tracks.iter_mut().flat_map(|t| &mut t.clips) {
            if all.contains(&c.id) {
                c.set_group_id(Some(&gid));
            }
        }
        true
    }

    pub fn ungroup(&mut self, ids: &HashSet<Id>) {
        let all = self.group_members(ids);
        for c in self.tracks.iter_mut().flat_map(|t| &mut t.clips) {
            if all.contains(&c.id) {
                c.set_group_id(None);
            }
        }
    }

    /// 선택한 클립을 트랙별로 하나로 합친다.
    /// 원래 한 클립이던 조각(같은 원본·같은 속도·원본 구간이 이어짐)은 한 클립으로 되돌리고,
    /// 그렇지 않은 클립은 빈틈 없이 붙인 뒤 그룹으로 묶는다. 사이에 선택 안 한 클립이 있으면 거기서 끊는다.
    /// (합친 곳 수, 그룹으로 묶은 클립 수)
    pub fn join(&mut self, ids: &HashSet<Id>) -> (usize, usize) {
        let (mut merged, mut grouped) = (0, 0);
        for t in &mut self.tracks {
            let mut clips = std::mem::take(&mut t.clips);
            clips.sort_by(|a, b| a.start.total_cmp(&b.start));
            let mut chains: Vec<Vec<Id>> = vec![];
            let mut chain: Vec<Id> = vec![];
            let mut i = 0;
            while i < clips.len() {
                if !ids.contains(&clips[i].id) {
                    if chain.len() > 1 {
                        chains.push(std::mem::take(&mut chain));
                    }
                    chain.clear();
                    i += 1;
                    continue;
                }
                if chain.is_empty() {
                    chain.push(clips[i].id);
                    i += 1;
                    continue;
                }
                let p = i - 1;
                // 빈틈 메우기 (선택한 클립만 왼쪽으로)
                let gap = clips[i].start - clips[p].end();
                if gap > EPS {
                    clips[i].start = clips[p].end();
                }
                let (a, b) = (&clips[p], &clips[i]);
                let same = a.kind == ClipKind::Media
                    && b.kind == ClipKind::Media
                    && a.asset_id.is_some()
                    && a.asset_id == b.asset_id
                    && (a.speed - b.speed).abs() < 0.0001
                    && (a.source_out - b.source_in).abs() < 0.002
                    && (a.volume - b.volume).abs() < 0.0001
                    && (a.opacity - b.opacity).abs() < 0.0001
                    && (a.scale - b.scale).abs() < 0.0001
                    && (a.offset_x - b.offset_x).abs() < 0.0001
                    && (a.offset_y - b.offset_y).abs() < 0.0001;
                if same {
                    let (out, fade) = (b.source_out, b.fade_out);
                    clips[p].source_out = out;
                    clips[p].fade_out = fade;
                    clips.remove(i);
                    merged += 1;
                } else {
                    chain.push(b.id);
                    i += 1;
                }
            }
            if chain.len() > 1 {
                chains.push(chain);
            }
            for c in &chains {
                let gid = new_group();
                for clip in clips.iter_mut().filter(|x| c.contains(&x.id)) {
                    clip.set_group_id(Some(&gid));
                }
                grouped += c.len();
            }
            t.clips = clips;
        }
        (merged, grouped)
    }

    /// 클립 복사본들을 넣는다 (새 id, 그룹은 새 그룹으로). items: (트랙, 클립). 시작 시각은 `shift`만큼 옮긴다. 새 id들
    pub fn place_copies(&mut self, items: &[(usize, Clip)], shift: f64) -> Vec<Id> {
        let mut new_ids = vec![];
        let mut groups: HashMap<String, String> = HashMap::new();
        for (ti, c) in items {
            let mut n = c.clone();
            n.id = Id::new();
            n.start = (c.start + shift).max(0.0);
            if let Some(g) = c.group_id().map(str::to_string) {
                let ng = groups.entry(g).or_insert_with(new_group).clone();
                n.set_group_id(Some(&ng));
            }
            while self.tracks.len() <= *ti {
                let k = self.tracks.len() + 1;
                self.tracks.push(Track::named(format!("트랙 {k}")));
            }
            self.tracks[*ti].clips.push(n.clone());
            self.resolve_overlaps(*ti, Some(n.id));
            new_ids.push(n.id);
        }
        new_ids
    }

    /// 선택한 클립들 (트랙, 클립)
    pub fn clips_with_tracks(&self, ids: &HashSet<Id>) -> Vec<(usize, Clip)> {
        self.tracks.iter().enumerate().flat_map(|(ti, t)| t.clips.iter().filter(|c| ids.contains(&c.id)).map(move |c| (ti, c.clone()))).collect()
    }

    /// 복제: 여러 개(그룹)를 복제하면 배치를 유지한 채 통째로 바로 뒤에 놓는다
    pub fn duplicate(&mut self, ids: &HashSet<Id>) -> Vec<Id> {
        let items = self.clips_with_tracks(ids);
        if items.is_empty() {
            return vec![];
        }
        let end = items.iter().map(|x| x.1.end()).fold(f64::MIN, f64::max);
        let start = items.iter().map(|x| x.1.start).fold(f64::MAX, f64::min);
        self.place_copies(&items, end - start)
    }

    /// 붙여넣기: 복사해 둔 클립들을 배치 그대로 time에
    pub fn paste(&mut self, items: &[(usize, Clip)], time: f64) -> Vec<Id> {
        let Some(base) = items.iter().map(|x| x.1.start).reduce(f64::min) else { return vec![] };
        self.place_copies(items, time - base)
    }

    pub fn add_track(&mut self) {
        let n = self.tracks.len() + 1;
        self.tracks.push(Track::named(format!("트랙 {n}")));
    }

    /// 빈 트랙 정리 (하나는 남기고, 이름을 다시 붙인다)
    pub fn remove_empty_tracks(&mut self) {
        self.tracks.retain(|t| !t.clips.is_empty());
        if self.tracks.is_empty() {
            self.tracks.push(Track::named("트랙 1"));
        }
        for (i, t) in self.tracks.iter_mut().enumerate() {
            t.name = format!("트랙 {}", i + 1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn media(asset: Id, start: f64, a: f64, b: f64) -> Clip {
        Clip { asset_id: Some(asset), start, source_in: a, source_out: b, ..Clip::default() }
    }

    #[test]
    fn join_merges_split_pieces_and_groups_the_rest() {
        let asset = Id::new();
        let other = Id::new();
        let mut p = Project::default();
        let a = media(asset, 0.0, 0.0, 2.0);
        let b = media(asset, 2.0, 2.0, 5.0); // a와 이어지는 조각 → 합쳐짐
        let c = media(other, 6.0, 0.0, 1.0); // 빈틈 1초 → 당겨지고 그룹
        let ids: HashSet<Id> = [a.id, b.id, c.id].into_iter().collect();
        p.tracks[0].clips = vec![a.clone(), b, c.clone()];
        let (merged, grouped) = p.join(&ids);
        assert_eq!(merged, 1);
        assert_eq!(grouped, 2);
        let clips = &p.tracks[0].clips;
        assert_eq!(clips.len(), 2);
        assert!((clips[0].source_out - 5.0).abs() < 1e-9);
        assert!((clips[1].start - 5.0).abs() < 1e-9);
        assert!(clips[0].group_id().is_some() && clips[0].group_id() == clips[1].group_id());
        assert_eq!(p.group_members(&[a.id].into_iter().collect()).len(), 2);
        p.ungroup(&[a.id].into_iter().collect());
        assert!(p.tracks[0].clips.iter().all(|c| c.group_id().is_none()));
    }

    #[test]
    fn duplicate_keeps_layout_with_new_group() {
        let asset = Id::new();
        let mut p = Project::default();
        let a = media(asset, 0.0, 0.0, 2.0);
        let b = media(asset, 0.0, 0.0, 1.0);
        p.tracks[0].clips = vec![a.clone()];
        p.tracks[1].clips = vec![b.clone()];
        let ids: HashSet<Id> = [a.id, b.id].into_iter().collect();
        assert!(p.group(&ids));
        let new = p.duplicate(&ids);
        assert_eq!(new.len(), 2);
        let n0 = p.clip(new[0]).unwrap();
        let n1 = p.clip(new[1]).unwrap();
        assert!((n0.start - 2.0).abs() < 1e-9 && (n1.start - 2.0).abs() < 1e-9);
        assert_eq!(n0.group_id(), n1.group_id());
        assert_ne!(n0.group_id(), p.clip(a.id).unwrap().group_id());
        // 파일로 저장해도 groupID가 남는다
        let json = p.to_json().unwrap();
        assert!(json.contains("\"groupID\""));
    }

    #[test]
    fn paste_at_time_and_tracks() {
        let asset = Id::new();
        let mut p = Project::default();
        let a = media(asset, 3.0, 0.0, 2.0);
        p.tracks[0].clips = vec![a.clone()];
        let items = p.clips_with_tracks(&[a.id].into_iter().collect());
        let new = p.paste(&items, 10.0);
        assert!((p.clip(new[0]).unwrap().start - 10.0).abs() < 1e-9);
        p.add_track();
        let n = p.tracks.len();
        p.remove_empty_tracks();
        assert!(p.tracks.len() < n);
        assert_eq!(p.tracks[0].name, "트랙 1");
    }
}
