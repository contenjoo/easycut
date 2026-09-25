//! EasyCut for Windows — Tauri 백엔드. 편집 규칙은 easycut-core, 화면은 ui/ (HTML·JS).
mod ai;
mod ai_tools;
mod control;
mod edits;
mod export;
mod link;
mod media;
mod record;
mod recovery;
mod selftest;
mod stt;
mod tools;
mod update;

pub use control::run_mcp;

pub use selftest::run as selftest;

use easycut_core::silence::{auto_threshold, loudness, SilenceSettings};
use easycut_core::transcript_ops::{deletion_ranges, srt};
use easycut_core::{Caption, Id, MediaKind, Project};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Default)]
struct Editor {
    project: Project,
    path: Option<PathBuf>,
    undo: Vec<Project>,
    redo: Vec<Project>,
    dirty: bool,
    loudness: HashMap<Id, Vec<f32>>,
    /// 바뀔 때마다 늘어난다 (자동 저장·복구 파일이 새로 써야 하는지 판단)
    rev: u64,
    /// 복사한 클립 (트랙, 클립)
    clipboard: Vec<(usize, easycut_core::Clip)>,
}

impl Editor {
    fn apply(&mut self, f: impl FnOnce(&mut Project)) {
        let before = self.project.clone();
        f(&mut self.project);
        self.project.normalize();
        if self.project != before {
            self.undo.push(before);
            if self.undo.len() > 300 {
                self.undo.remove(0);
            }
            self.redo.clear();
            self.dirty = true;
            self.rev += 1;
        }
    }

    fn undo_step(&mut self) -> bool {
        let Some(prev) = self.undo.pop() else { return false };
        let cur = std::mem::replace(&mut self.project, prev);
        self.redo.push(cur);
        self.dirty = true;
        self.rev += 1;
        true
    }

    fn redo_step(&mut self) -> bool {
        let Some(next) = self.redo.pop() else { return false };
        let cur = std::mem::replace(&mut self.project, next);
        self.undo.push(cur);
        self.dirty = true;
        self.rev += 1;
        true
    }

    fn snapshot(&self) -> Value {
        let fillers = self.project.filler_word_ids();
        let words: Vec<Value> = self
            .project
            .timeline_words()
            .iter()
            .map(|w| {
                let id = w.id();
                json!({ "id": id, "text": w.word.text, "start": w.start, "end": w.end,
                        "asset": w.asset_id, "word": w.word.id, "filler": fillers.contains(&id) })
            })
            .collect();
        json!({
            "words": words,
            "project": self.project,
            "path": self.path.as_ref().map(|p| p.to_string_lossy().to_string()),
            "dirty": self.dirty,
            "canUndo": !self.undo.is_empty(),
            "canRedo": !self.redo.is_empty(),
        })
    }
}

/// 화면 쪽 상태 (AI가 재생헤드·선택을 알아야 할 때)
#[derive(Clone, Default, serde::Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct UiState {
    time: f64,
    selection: Vec<String>,
    mark_in: Option<f64>,
    mark_out: Option<f64>,
    /// 음성 인식 언어 ("ko", "en", "auto" …)
    language: String,
}

struct AppState {
    editor: Mutex<Editor>,
    cancel: Arc<AtomicBool>,
    ui: Mutex<UiState>,
}

type Res<T> = Result<T, String>;

fn with<T>(st: &State<AppState>, f: impl FnOnce(&mut Editor) -> T) -> T {
    let mut e = st.editor.lock().unwrap();
    f(&mut e)
}

fn job(app: &AppHandle, id: &str, value: f64, message: &str) {
    let _ = app.emit("job", json!({ "id": id, "value": value, "message": message }));
}

fn changed(app: &AppHandle, st: &State<AppState>) -> Value {
    let v = with(st, |e| e.snapshot());
    let _ = app.emit("project", &v);
    v
}

/// 프로젝트가 바뀐 것을 화면에 알린다 (명령 밖: AI 도구, 제어 서버)
fn emit_state(app: &AppHandle) -> Value {
    let v = app.state::<AppState>().editor.lock().unwrap().snapshot();
    let _ = app.emit("project", &v);
    v
}

// MARK: 프로젝트

#[tauri::command]
fn get_state(st: State<AppState>) -> Value {
    with(&st, |e| e.snapshot())
}

#[tauri::command]
fn new_project(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| *e = Editor::default());
    recovery::clear();
    changed(&app, &st)
}

#[tauri::command]
fn open_project(app: AppHandle, st: State<AppState>, path: String) -> Res<Value> {
    let data = std::fs::read_to_string(&path).map_err(|e| format!("프로젝트를 열 수 없습니다: {e}"))?;
    let p = Project::from_json(&data).map_err(|e| format!("프로젝트를 열 수 없습니다: {e}"))?;
    with(&st, |e| {
        *e = Editor::default();
        e.project = p;
        e.path = Some(PathBuf::from(&path));
    });
    recovery::clear();
    Ok(changed(&app, &st))
}

#[tauri::command]
fn save_project(app: AppHandle, st: State<AppState>, path: Option<String>) -> Res<Value> {
    let (json, target) = with(&st, |e| {
        let target = path.map(PathBuf::from).or_else(|| e.path.clone());
        (e.project.to_json(), target)
    });
    let target = target.ok_or("저장할 위치가 없습니다.")?;
    std::fs::write(&target, json.map_err(|e| e.to_string())?).map_err(|e| format!("저장 실패: {e}"))?;
    with(&st, |e| {
        e.path = Some(target);
        e.dirty = false;
    });
    recovery::clear();
    Ok(changed(&app, &st))
}

#[tauri::command]
fn undo(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| e.undo_step());
    changed(&app, &st)
}

#[tauri::command]
fn redo(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| e.redo_step());
    changed(&app, &st)
}

// MARK: 가져오기

#[tauri::command]
async fn import_files(app: AppHandle, st: State<'_, AppState>, paths: Vec<String>) -> Res<Value> {
    let probed = tauri::async_runtime::spawn_blocking(move || {
        paths.iter().map(|p| media::probe(&PathBuf::from(p))).collect::<Vec<_>>()
    })
    .await
    .map_err(|e| e.to_string())?;
    let mut errors = vec![];
    let mut added = vec![];
    for r in probed {
        match r {
            Ok(a) => added.push(a),
            Err(e) => errors.push(e),
        }
    }
    with(&st, |e| {
        let was_empty = e.project.duration() <= 0.0;
        e.apply(|p| {
            for a in &added {
                if p.assets.iter().any(|x| x.path == a.path) {
                    continue;
                }
                p.assets.push(a.clone());
                if was_empty && p.assets.iter().filter(|x| x.kind == MediaKind::Video).count() == 1 && a.kind == MediaKind::Video && a.width > 0.0 {
                    p.canvas_width = a.width;
                    p.canvas_height = a.height;
                }
                if was_empty {
                    auto_place(p, a);
                }
            }
        });
    });
    let v = changed(&app, &st);
    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }
    Ok(v)
}

fn auto_place(p: &mut Project, a: &easycut_core::MediaAsset) {
    let ti = match a.kind {
        MediaKind::Video => 0,
        MediaKind::Image => 1,
        MediaKind::Audio => 2,
    };
    let t = p.track_end(ti);
    p.insert(a, ti, t, 5.0);
}

#[tauri::command]
fn add_to_timeline(app: AppHandle, st: State<AppState>, asset: Id, time: Option<f64>) -> Value {
    with(&st, |e| {
        let Some(a) = e.project.assets.iter().find(|x| x.id == asset).cloned() else { return };
        e.apply(|p| match time {
            Some(t) => {
                let ti = if a.kind == MediaKind::Audio { 2 } else { 0 };
                p.insert(&a, ti, t, 5.0);
            }
            None => auto_place(p, &a),
        });
    });
    changed(&app, &st)
}

#[tauri::command]
fn remove_asset(app: AppHandle, st: State<AppState>, asset: Id) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            p.assets.retain(|a| a.id != asset);
            for t in &mut p.tracks {
                t.clips.retain(|c| c.asset_id != Some(asset));
            }
        })
    });
    changed(&app, &st)
}

// MARK: 편집

#[tauri::command]
fn split(app: AppHandle, st: State<AppState>, time: f64, ids: Vec<Id>) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            if ids.is_empty() {
                p.split_all(time, None);
            } else {
                for id in &ids {
                    p.split(*id, time);
                }
            }
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn delete_clips(app: AppHandle, st: State<AppState>, ids: Vec<Id>, ripple: bool) -> Value {
    let set: HashSet<Id> = ids.into_iter().collect();
    with(&st, |e| e.apply(|p| p.delete_clips(&set, ripple)));
    changed(&app, &st)
}

#[tauri::command]
fn ripple_delete_range(app: AppHandle, st: State<AppState>, start: f64, end: f64) -> Value {
    with(&st, |e| e.apply(|p| p.ripple_delete(start, end)));
    changed(&app, &st)
}

#[tauri::command]
fn move_clips(app: AppHandle, st: State<AppState>, moves: Vec<(Id, usize, f64)>) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            for (id, track, start) in &moves {
                p.move_clip(*id, *track, *start);
            }
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn reorder_clip(app: AppHandle, st: State<AppState>, id: Id, pointer: f64) -> Value {
    with(&st, |e| e.apply(|p| p.reorder(id, pointer)));
    changed(&app, &st)
}

#[tauri::command]
fn trim_clip(app: AppHandle, st: State<AppState>, id: Id, left: bool, time: f64) -> Value {
    with(&st, |e| {
        let max = e.project.clip(id).and_then(|c| e.project.asset(c.asset_id)).filter(|a| a.kind != MediaKind::Image).map(|a| a.duration);
        e.apply(|p| if left { p.trim_start(id, time, max) } else { p.trim_end(id, time, max) });
    });
    changed(&app, &st)
}

#[tauri::command]
fn set_speed(app: AppHandle, st: State<AppState>, ids: Vec<Id>, speed: f64) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            for id in &ids {
                p.set_speed(*id, speed);
            }
        })
    });
    changed(&app, &st)
}

/// 편집 결과와 새로 고를 클립 id
fn with_selection(app: &AppHandle, st: &State<AppState>, ids: Vec<Id>, message: String) -> Value {
    let mut v = changed(app, st);
    v["select"] = json!(ids);
    v["message"] = json!(message);
    v
}

#[tauri::command]
fn duplicate_clips(app: AppHandle, st: State<AppState>, ids: Vec<Id>) -> Value {
    let set: HashSet<Id> = ids.into_iter().collect();
    let new = with(&st, |e| {
        let mut out = vec![];
        e.apply(|p| out = p.duplicate(&set));
        out
    });
    with_selection(&app, &st, new, String::new())
}

#[tauri::command]
fn copy_clips(st: State<AppState>, ids: Vec<Id>) -> usize {
    let set: HashSet<Id> = ids.into_iter().collect();
    with(&st, |e| {
        e.clipboard = e.project.clips_with_tracks(&set);
        e.clipboard.len()
    })
}

#[tauri::command]
fn paste_clips(app: AppHandle, st: State<AppState>, time: f64) -> Value {
    let new = with(&st, |e| {
        let items = e.clipboard.clone();
        let mut out = vec![];
        e.apply(|p| out = p.paste(&items, time));
        out
    });
    with_selection(&app, &st, new, String::new())
}

#[tauri::command]
fn group_clips(app: AppHandle, st: State<AppState>, ids: Vec<Id>, on: bool) -> Value {
    let set: HashSet<Id> = ids.into_iter().collect();
    let sel = with(&st, |e| {
        if on {
            e.apply(|p| {
                p.group(&set);
            });
        } else {
            e.apply(|p| p.ungroup(&set));
        }
        e.project.group_members(&set).into_iter().collect::<Vec<_>>()
    });
    with_selection(&app, &st, sel, String::new())
}

#[tauri::command]
fn join_clips(app: AppHandle, st: State<AppState>, ids: Vec<Id>) -> Value {
    let set: HashSet<Id> = ids.into_iter().collect();
    let (r, sel) = with(&st, |e| {
        let mut r = (0, 0);
        e.apply(|p| r = p.join(&set));
        let alive: HashSet<Id> = e.project.tracks.iter().flat_map(|t| &t.clips).map(|c| c.id).collect();
        let keep: HashSet<Id> = set.intersection(&alive).copied().collect();
        (r, e.project.group_members(&keep).into_iter().collect::<Vec<_>>())
    });
    let mut parts = vec![];
    if r.0 > 0 {
        parts.push(format!("잘린 조각 {}곳을 하나로 합침", r.0));
    }
    if r.1 > 0 {
        parts.push(format!("나머지 {}개는 빈틈 없이 붙여 그룹으로 묶음", r.1));
    }
    let msg = if parts.is_empty() { "합칠 수 있는 클립이 없습니다 (같은 트랙에서 이웃한 클립을 선택하세요)".to_string() } else { parts.join(", ") };
    with_selection(&app, &st, sel, msg)
}

#[tauri::command]
fn tracks_edit(app: AppHandle, st: State<AppState>, action: String) -> Value {
    with(&st, |e| e.apply(|p| if action == "add" { p.add_track() } else { p.remove_empty_tracks() }));
    changed(&app, &st)
}

/// 클립 속성 한꺼번에 (volume, opacity, scale, offsetX, offsetY, fadeIn, fadeOut, text)
#[tauri::command]
fn update_clip(app: AppHandle, st: State<AppState>, id: Id, props: HashMap<String, Value>) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            if let Some(c) = p.clip_mut(id) {
                for (k, v) in &props {
                    let f = v.as_f64();
                    match (k.as_str(), f) {
                        ("volume", Some(x)) => c.volume = x.clamp(0.0, 4.0),
                        ("opacity", Some(x)) => c.opacity = x.clamp(0.0, 1.0),
                        ("scale", Some(x)) => c.scale = x.clamp(0.05, 4.0),
                        ("offsetX", Some(x)) => c.offset_x = x,
                        ("offsetY", Some(x)) => c.offset_y = x,
                        ("fadeIn", Some(x)) => c.fade_in = x.max(0.0),
                        ("fadeOut", Some(x)) => c.fade_out = x.max(0.0),
                        ("text", _) => c.text = v.as_str().unwrap_or("").to_string(),
                        _ => {}
                    }
                }
            }
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn update_track(app: AppHandle, st: State<AppState>, index: usize, muted: bool, hidden: bool) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            if let Some(t) = p.tracks.get_mut(index) {
                t.muted = muted;
                t.hidden = hidden;
            }
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn add_text(app: AppHandle, st: State<AppState>, time: f64, text: String) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            let ti = p.tracks.len().saturating_sub(1).max(1);
            p.insert_text(&text, ti, time, 4.0);
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn update_project(app: AppHandle, st: State<AppState>, props: HashMap<String, Value>) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            for (k, v) in &props {
                match k.as_str() {
                    "canvasWidth" => p.canvas_width = v.as_f64().unwrap_or(p.canvas_width),
                    "canvasHeight" => p.canvas_height = v.as_f64().unwrap_or(p.canvas_height),
                    "fps" => p.fps = v.as_f64().unwrap_or(p.fps),
                    "showCaptions" => p.show_captions = v.as_bool().unwrap_or(p.show_captions),
                    "captionStyle" => {
                        if let Ok(s) = serde_json::from_value(v.clone()) {
                            p.caption_style = s;
                        }
                    }
                    "captions" => {
                        if let Ok(c) = serde_json::from_value::<Vec<Caption>>(v.clone()) {
                            p.captions = c;
                        }
                    }
                    _ => {}
                }
            }
        })
    });
    changed(&app, &st)
}

// MARK: 대본 · 자막 · 무음

#[tauri::command]
fn delete_words(app: AppHandle, st: State<AppState>, ids: Vec<String>) -> Value {
    let set: HashSet<String> = ids.into_iter().collect();
    with(&st, |e| {
        let ranges = deletion_ranges(&set, &e.project.timeline_words());
        e.apply(|p| p.ripple_delete_ranges(&ranges));
    });
    changed(&app, &st)
}

#[tauri::command]
fn update_word(app: AppHandle, st: State<AppState>, asset: Id, word: Id, text: String) -> Value {
    with(&st, |e| e.apply(|p| p.update_word(asset, word, &text)));
    changed(&app, &st)
}

#[tauri::command]
fn remove_fillers(app: AppHandle, st: State<AppState>) -> Res<Value> {
    let n = with(&st, |e| {
        let ids = e.project.filler_word_ids();
        let n = ids.len();
        let ranges = deletion_ranges(&ids, &e.project.timeline_words());
        e.apply(|p| p.ripple_delete_ranges(&ranges));
        n
    });
    if n == 0 {
        return Err("군더더기 말(음, 어…)을 찾지 못했습니다".into());
    }
    Ok(changed(&app, &st))
}

#[tauri::command]
fn generate_captions(app: AppHandle, st: State<AppState>) -> Res<Value> {
    let ok = with(&st, |e| {
        let caps = e.project.generated_captions_default();
        if caps.is_empty() {
            return false;
        }
        e.apply(|p| {
            p.captions = caps;
            p.show_captions = true;
        });
        true
    });
    if !ok {
        return Err("대본이 없습니다. 먼저 음성 인식을 실행하세요.".into());
    }
    Ok(changed(&app, &st))
}

// MARK: 자막 편집

#[tauri::command]
fn add_caption(app: AppHandle, st: State<AppState>, time: f64) -> Value {
    let c = Caption::new(time, time + 3.0, "새 자막");
    let id = c.id;
    with(&st, |e| e.apply(|p| p.captions.push(c)));
    let mut v = changed(&app, &st);
    v["caption"] = json!(id);
    v
}

/// 자막 삭제. with_video면 그 말이 나오는 영상 구간도 함께 잘라낸다
#[tauri::command]
fn delete_captions(app: AppHandle, st: State<AppState>, ids: Vec<Id>, with_video: bool) -> Value {
    let set: HashSet<Id> = ids.into_iter().collect();
    let total = with(&st, |e| {
        let ranges: Vec<_> = if with_video { set.iter().filter_map(|id| e.project.span_of_caption(*id)).collect() } else { vec![] };
        let total: f64 = easycut_core::merge_default(&ranges).iter().map(|r| r.len()).sum();
        e.apply(|p| edits::delete_captions(p, &set, with_video));
        total
    });
    let mut v = changed(&app, &st);
    v["message"] = json!(if with_video { format!("자막 {}개와 영상 {:.1}초 삭제", set.len(), total) } else { format!("자막 {}개 삭제 (영상 유지)", set.len()) });
    v
}

/// 자막 순서 바꾸기: 시간순 from번째 자막을 그 영상 구간째 to번째 앞으로
#[tauri::command]
fn move_caption(app: AppHandle, st: State<AppState>, from: usize, to: usize) -> Value {
    with(&st, |e| e.apply(|p| edits::move_caption(p, from, to)));
    changed(&app, &st)
}

#[tauri::command]
fn update_caption(app: AppHandle, st: State<AppState>, id: Id, text: Option<String>, start: Option<f64>, end: Option<f64>) -> Value {
    with(&st, |e| {
        e.apply(|p| {
            if let Some(c) = p.captions.iter_mut().find(|c| c.id == id) {
                if let Some(t) = text {
                    c.text = t;
                }
                if let Some(v) = start {
                    c.start = v.max(0.0);
                }
                if let Some(v) = end {
                    c.end = v;
                }
                if c.end < c.start + 0.1 {
                    c.end = c.start + 0.1;
                }
            }
        })
    });
    changed(&app, &st)
}

#[tauri::command]
fn clear_captions(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| e.apply(|p| p.captions.clear()));
    changed(&app, &st)
}

#[tauri::command]
fn export_srt(st: State<AppState>, path: String) -> Res<()> {
    let text = with(&st, |e| srt::make(&e.project.captions));
    std::fs::write(path, text).map_err(|e| e.to_string())
}

#[tauri::command]
fn import_srt(app: AppHandle, st: State<AppState>, path: String) -> Res<Value> {
    let text = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let caps = srt::parse(&text);
    if caps.is_empty() {
        return Err("SRT 자막을 읽지 못했습니다.".into());
    }
    with(&st, |e| e.apply(|p| p.captions = caps));
    Ok(changed(&app, &st))
}

/// 소리 크기로 무음 구간 찾기. apply=false면 미리보기 구간만 돌려준다.
#[tauri::command]
async fn silence_ranges(app: AppHandle, settings: Option<SilenceSettings>, auto: bool, apply: bool) -> Res<Value> {
    tauri::async_runtime::spawn_blocking(move || silence_blocking(&app, settings, auto, apply)).await.map_err(|e| e.to_string())?
}

fn silence_blocking(app: &AppHandle, settings: Option<SilenceSettings>, auto: bool, apply: bool) -> Res<Value> {
    let st = app.state::<AppState>();
    let (assets, have) = with(&st, |e| {
        let used: HashSet<Id> = e.project.tracks.first().map(|t| t.clips.iter().filter_map(|c| c.asset_id).collect()).unwrap_or_default();
        let assets: Vec<_> = e.project.assets.iter().filter(|a| used.contains(&a.id) && a.has_audio).map(|a| (a.id, a.path.clone())).collect();
        (assets, e.loudness.clone())
    });
    let computed: Vec<_> = assets
        .into_iter()
        .filter(|(id, _)| !have.contains_key(id))
        .map(|(id, path)| {
            job(app, "silence", 0.0, "소리 분석 중…");
            media::pcm(&PathBuf::from(path), 8000).map(|s| (id, loudness(&s)))
        })
        .collect();
    job(app, "silence", 1.0, "");
    let mut settings = settings.unwrap_or_default();
    let v = with(&st, |e| {
        for r in computed.into_iter().flatten() {
            e.loudness.insert(r.0, r.1);
        }
        if auto {
            let all: Vec<f32> = e.loudness.values().flatten().copied().collect();
            settings.threshold = auto_threshold(&all);
        }
        let ranges = e.project.audio_silence_ranges(&e.loudness, &settings);
        let removed: f64 = ranges.iter().map(|r| r.len()).sum();
        if apply && !ranges.is_empty() {
            e.apply(|p| p.ripple_delete_ranges(&ranges));
        }
        json!({ "ranges": ranges.iter().map(|r| [r.start, r.end]).collect::<Vec<_>>(), "removed": removed, "threshold": settings.threshold })
    });
    if apply {
        emit_state(app);
    }
    Ok(v)
}

// MARK: 음성 인식

#[tauri::command]
fn whisper_status() -> Value {
    json!({ "engine": tools::find_tool("whisper-cli").is_some(), "model": stt::model_ready(), "ffmpeg": tools::find_tool("ffmpeg").is_some() })
}

#[tauri::command]
async fn download_model(app: AppHandle) -> Res<()> {
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || stt::download_model(|v| job(&a2, "model", v, "Whisper 모델 받는 중…")))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn transcribe(app: AppHandle, asset: Id, language: String) -> Res<Value> {
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || transcribe_blocking(&a2, asset, &language)).await.map_err(|e| e.to_string())??;
    Ok(emit_state(&app))
}

fn transcribe_blocking(app: &AppHandle, asset: Id, language: &str) -> Res<()> {
    let st = app.state::<AppState>();
    let path = with(&st, |e| e.project.assets.iter().find(|a| a.id == asset).map(|a| a.path.clone())).ok_or("파일을 찾을 수 없습니다")?;
    let cancel = st.cancel.clone();
    cancel.store(false, Ordering::SeqCst);
    let a2 = app.clone();
    let words = stt::transcribe(
        &PathBuf::from(path),
        if language.is_empty() { "ko" } else { language },
        |v, m| job(&a2, "stt", v, &m),
        |ws| {
            // 인식되는 대로 대본에 바로 보이게 (실행 취소 기록은 남기지 않음)
            let st = a2.state::<AppState>();
            let snap = {
                let mut e = st.editor.lock().unwrap();
                if let Some(a) = e.project.assets.iter_mut().find(|a| a.id == asset) {
                    a.words = Some(ws.to_vec());
                }
                e.snapshot()
            };
            let _ = a2.emit("project", snap);
        },
        || cancel.load(Ordering::SeqCst),
    )?;
    job(app, "stt", 1.0, "");
    with(&st, |e| {
        // 중간에 채워 둔 대본은 되돌린 뒤 한 번의 편집으로 기록
        if let Some(a) = e.project.assets.iter_mut().find(|a| a.id == asset) {
            a.words = None;
        }
        e.apply(|p| {
            if let Some(a) = p.assets.iter_mut().find(|a| a.id == asset) {
                a.words = Some(words);
            }
        })
    });
    Ok(())
}

#[tauri::command]
async fn check_update() -> Res<Value> {
    tauri::async_runtime::spawn_blocking(update::check).await.map_err(|e| e.to_string())?
}

/// 업데이트: 작업을 저장(또는 복구용 파일에 보관)하고, 설치 파일을 받아 조용히 설치한 뒤 다시 연다
#[tauri::command]
async fn install_update(app: AppHandle, url: String) -> Res<()> {
    job(&app, "update", 0.0, "업데이트 받는 중…");
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || -> Res<()> {
        let setup = update::fetch_installer(&url)?;
        job(&a2, "update", 0.9, "설치 준비 중…");
        recovery::save_now(&a2);
        let reopen = {
            let e = a2.state::<AppState>().inner().editor.lock().unwrap();
            e.path.clone().filter(|_| !e.dirty)
        };
        update::install_and_relaunch(&setup, reopen.as_ref().map(|p| p.to_string_lossy()).as_deref())
    })
    .await
    .map_err(|e| e.to_string())??;
    force_quit(&app);
    Ok(())
}

// MARK: 자동 저장 · 복구 · 설정

#[tauri::command]
fn recovery_check() -> Option<Value> {
    recovery::check()
}

#[tauri::command]
fn recovery_restore(app: AppHandle, st: State<AppState>) -> Res<Value> {
    let p = recovery::load().ok_or("복구할 작업을 읽지 못했습니다.")?;
    with(&st, |e| {
        *e = Editor::default();
        e.project = p;
        e.dirty = true;
        e.rev = 1;
    });
    Ok(changed(&app, &st))
}

#[tauri::command]
fn recovery_discard() {
    recovery::clear();
}

/// 앱을 끝내기 전에 (저장 안 함을 고른 경우 포함) 복구용 파일을 지운다
#[tauri::command]
fn quit_app(app: AppHandle) {
    recovery::clear();
    force_quit(&app);
}

/// 창 닫기 확인을 다시 띄우지 않도록 창을 먼저 없애고 끝낸다
fn force_quit(app: &AppHandle) {
    for w in app.webview_windows().values() {
        let _ = w.destroy();
    }
    app.exit(0);
}

#[tauri::command]
fn get_prefs() -> Value {
    let mut p = recovery::prefs();
    p["autosave"] = json!(recovery::autosave_enabled());
    p["version"] = json!(update::CURRENT);
    p
}

#[tauri::command]
fn set_pref(key: String, value: Value) {
    recovery::set_pref(&key, value);
}

/// 화면 쪽 상태 알림 (재생헤드, 선택, 구간, 인식 언어)
#[tauri::command]
fn ui_state(st: State<AppState>, state: UiState) {
    *st.ui.lock().unwrap() = state;
}

// MARK: AI

#[tauri::command]
fn ai_settings(app: AppHandle) -> Value {
    ai::settings_json(&app)
}

#[tauri::command]
fn ai_set_settings(app: AppHandle, settings: ai::Settings) -> Value {
    ai::set_settings(&app, settings);
    ai::settings_json(&app)
}

#[tauri::command]
fn ai_send(app: AppHandle, text: String) {
    ai::send(&app, &text);
}

#[tauri::command]
fn ai_cancel(app: AppHandle) {
    ai::cancel(&app);
}

#[tauri::command]
fn ai_reset(app: AppHandle) {
    ai::reset(&app);
}

#[tauri::command]
fn ai_set_key(app: AppHandle, key: String) -> Res<Value> {
    ai::save_key(&key)?;
    Ok(ai::agents_json(&app))
}

#[tauri::command]
fn ai_agents(app: AppHandle) -> Value {
    ai::agents_json(&app)
}

#[tauri::command]
async fn ai_refresh_agents(app: AppHandle) -> Res<Value> {
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || ai::refresh_agents(&a2)).await.map_err(|e| e.to_string())?;
    Ok(ai::agents_json(&app))
}

#[tauri::command]
async fn ai_connect(app: AppHandle, provider: String) -> Res<Value> {
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || ai::connect(&a2, provider == "codex")).await.map_err(|e| e.to_string())??;
    Ok(ai::agents_json(&app))
}

#[tauri::command]
async fn ai_connect_codex_key(app: AppHandle, key: String) -> Res<Value> {
    let a2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || ai::connect_codex_with_key(&a2, &key)).await.map_err(|e| e.to_string())??;
    Ok(ai::agents_json(&app))
}

#[tauri::command]
fn ai_cancel_login(app: AppHandle) {
    ai::cancel_login(&app);
}

#[tauri::command]
fn ai_links() -> Value {
    ai::links_json()
}

/// 다른 AI 앱에 EasyCut 연결 ("desktop" | "code" | "codex")
#[tauri::command]
async fn ai_link(target: String) -> Res<Value> {
    tauri::async_runtime::spawn_blocking(move || match target.as_str() {
        "desktop" => ai::link_desktop(),
        "code" => ai::link_code(),
        _ => ai::link_codex(),
    })
    .await
    .map_err(|e| e.to_string())??;
    Ok(ai::links_json())
}

/// 브라우저로 주소 열기 (http/https만)
#[tauri::command]
fn open_url(url: String) -> Res<()> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("열 수 없는 주소입니다".into());
    }
    let r = if cfg!(windows) {
        std::process::Command::new("explorer.exe").arg(&url).spawn()
    } else {
        std::process::Command::new("/usr/bin/open").arg(&url).spawn()
    };
    r.map(|_| ()).map_err(|e| e.to_string())
}

/// 파일이 있는 폴더를 탐색기에서 열고 그 파일을 선택
#[tauri::command]
fn reveal_file(path: String) -> Res<()> {
    let r = if cfg!(windows) {
        std::process::Command::new("explorer.exe").arg(format!("/select,{path}")).spawn()
    } else {
        std::process::Command::new("/usr/bin/open").args(["-R", &path]).spawn()
    };
    r.map(|_| ()).map_err(|e| e.to_string())
}

/// 파일을 기본 프로그램으로 열기
#[tauri::command]
fn open_file(path: String) -> Res<()> {
    let r = if cfg!(windows) {
        std::process::Command::new("explorer.exe").arg(&path).spawn()
    } else {
        std::process::Command::new("/usr/bin/open").arg(&path).spawn()
    };
    r.map(|_| ()).map_err(|e| e.to_string())
}

// MARK: 화면·얼굴 녹화

#[tauri::command]
fn rec_begin(app: AppHandle, kinds: Vec<(String, String)>) -> Res<Value> {
    record::begin(&app, &kinds)
}

/// 녹화 조각 (본문은 바이너리, 종류는 x-kind 헤더)
#[tauri::command]
fn rec_chunk(app: AppHandle, request: tauri::ipc::Request) -> Res<()> {
    let kind = request.headers().get("x-kind").and_then(|v| v.to_str().ok()).unwrap_or("screen").to_string();
    match request.body() {
        tauri::ipc::InvokeBody::Raw(b) => record::write_chunk(&app, &kind, b),
        _ => Err("녹화 조각 형식이 올바르지 않습니다".into()),
    }
}

#[tauri::command]
fn rec_discard(app: AppHandle) {
    record::discard(&app);
}

#[tauri::command]
fn rec_panel(app: AppHandle, open: bool, camera: bool) -> Res<()> {
    if open {
        record::open_panel(&app, camera)
    } else {
        record::close_panel(&app);
        Ok(())
    }
}

#[tauri::command]
fn rec_hotkeys(app: AppHandle, on: bool) {
    if on { record::register_hotkeys(&app) } else { record::unregister_hotkeys(&app) }
}

#[tauri::command]
async fn rec_finish(app: AppHandle, camera_circle: bool) -> Res<Value> {
    tauri::async_runtime::spawn_blocking(move || record::finish(&app, camera_circle)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn rec_folder() -> String {
    record::folder().to_string_lossy().to_string()
}

// MARK: 링크로 가져오기

#[tauri::command]
async fn import_link(app: AppHandle, url: String, quality: String, start: Option<f64>, end: Option<f64>) -> Res<String> {
    tauri::async_runtime::spawn_blocking(move || link::import_blocking(&app, &url, &link::Options { quality, start, end }))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn ytdlp_status() -> Value {
    json!({ "installed": link::ytdlp().is_some() })
}

#[tauri::command]
async fn ytdlp_update() -> Res<()> {
    tauri::async_runtime::spawn_blocking(link::install_ytdlp).await.map_err(|e| e.to_string())?
}

/// 실행할 때 넘겨받은 파일 (탐색기에서 "EasyCut으로 열기", 끌어다 놓기로 실행)
#[tauri::command]
fn startup_files() -> Vec<String> {
    std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with('-') && std::path::Path::new(a).is_file())
        .collect()
}

#[tauri::command]
fn cancel_job(st: State<AppState>) {
    st.cancel.store(true, Ordering::SeqCst);
}

// MARK: 내보내기

#[tauri::command]
async fn export_video(app: AppHandle, st: State<'_, AppState>, path: String, height: u32, burn_captions: bool) -> Res<()> {
    let project = with(&st, |e| e.project.clone());
    let cancel = st.cancel.clone();
    cancel.store(false, Ordering::SeqCst);
    let a2 = app.clone();
    let opts = export::Options { path, height, burn_captions };
    tauri::async_runtime::spawn_blocking(move || {
        export::export(&project, &opts, |v| job(&a2, "export", v, "내보내는 중…"), || cancel.load(Ordering::SeqCst))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { editor: Mutex::new(Editor::default()), cancel: Arc::new(AtomicBool::new(false)), ui: Mutex::default() })
        .manage(ai::Ai::default())
        .manage(record::Recorder::default())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            get_state, new_project, open_project, save_project, undo, redo,
            import_files, add_to_timeline, remove_asset,
            split, delete_clips, ripple_delete_range, move_clips, reorder_clip, trim_clip, set_speed, update_clip, update_track, add_text, update_project,
            delete_words, update_word, remove_fillers, generate_captions, export_srt, import_srt, silence_ranges,
            whisper_status, download_model, transcribe, cancel_job, export_video, startup_files, check_update, install_update,
            recovery_check, recovery_restore, recovery_discard, quit_app, get_prefs, set_pref, ui_state,
            ai_settings, ai_set_settings, ai_send, ai_cancel, ai_reset, ai_set_key, ai_agents, ai_refresh_agents, ai_connect,
            ai_connect_codex_key, ai_cancel_login, ai_links, ai_link, import_link, ytdlp_status, ytdlp_update, open_url, reveal_file, open_file,
            add_caption, delete_captions, move_caption, update_caption, clear_captions,
            duplicate_clips, copy_clips, paste_clips, group_clips, join_clips, tracks_edit,
            rec_begin, rec_chunk, rec_discard, rec_panel, rec_hotkeys, rec_finish, rec_folder,
        ])
        .setup(|app| {
            let _ = app.path().app_data_dir();
            control::start(app.handle().clone());
            recovery::start(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("EasyCut 실행 실패");
}
