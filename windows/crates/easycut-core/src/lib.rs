//! EasyCut 편집 코어. UI·플랫폼과 무관한 순수 로직만 둔다.

pub mod model;
pub mod silence;
pub mod timeline_ops;
pub mod transcript_ops;
pub mod whisper;

pub use model::*;
pub use timeline_ops::{merge, merge_default, TimeRange, EPS, MIN_CLIP_DURATION};
pub use transcript_ops::{deletion_ranges, srt, TimelineWord};
