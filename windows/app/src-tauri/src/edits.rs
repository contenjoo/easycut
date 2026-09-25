//! 여러 곳(화면 명령, AI 도구)에서 함께 쓰는 편집 동작. 맥 EditorStore와 같은 규칙.
use easycut_core::timeline_ops::TimeRange;
use easycut_core::{Id, Project};
use std::collections::HashSet;

/// 자막 삭제. with_video면 그 말이 나오는 영상 구간도 함께 잘라 낸다
pub fn delete_captions(p: &mut Project, ids: &HashSet<Id>, with_video: bool) {
    let ranges: Vec<TimeRange> = if with_video { ids.iter().filter_map(|id| p.span_of_caption(*id)).collect() } else { vec![] };
    p.captions.retain(|c| !ids.contains(&c.id));
    if !ranges.is_empty() {
        p.ripple_delete_ranges(&ranges);
    }
}

/// 자막 순서 바꾸기: 시간순 from번째 자막과 그 구간 영상을 to번째 자막 앞으로 옮긴다 (to = 개수면 맨 끝)
pub fn move_caption(p: &mut Project, from: usize, to: usize) {
    let mut sorted = p.captions.clone();
    sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
    if from >= sorted.len() || to == from || to == from + 1 {
        return;
    }
    let Some(span) = p.span_of_caption(sorted[from].id) else { return };
    let target = if to >= sorted.len() {
        p.span_of_caption(sorted[sorted.len() - 1].id).map_or(p.duration(), |r| r.end)
    } else {
        sorted[to].start
    };
    p.move_range(span.start, span.end, target);
}
