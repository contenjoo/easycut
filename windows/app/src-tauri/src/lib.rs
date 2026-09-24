//! EasyCut for Windows — Tauri 백엔드. 편집 규칙은 easycut-core, 화면은 ui/ (HTML·JS).
mod export;
mod media;
mod selftest;
mod stt;
mod tools;
mod update;

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
        }
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

struct AppState {
    editor: Mutex<Editor>,
    cancel: Arc<AtomicBool>,
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

// MARK: 프로젝트

#[tauri::command]
fn get_state(st: State<AppState>) -> Value {
    with(&st, |e| e.snapshot())
}

#[tauri::command]
fn new_project(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| *e = Editor::default());
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
    Ok(changed(&app, &st))
}

#[tauri::command]
fn undo(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| {
        if let Some(prev) = e.undo.pop() {
            let cur = std::mem::replace(&mut e.project, prev);
            e.redo.push(cur);
            e.dirty = true;
        }
    });
    changed(&app, &st)
}

#[tauri::command]
fn redo(app: AppHandle, st: State<AppState>) -> Value {
    with(&st, |e| {
        if let Some(next) = e.redo.pop() {
            let cur = std::mem::replace(&mut e.project, next);
            e.undo.push(cur);
            e.dirty = true;
        }
    });
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
async fn silence_ranges(app: AppHandle, st: State<'_, AppState>, settings: Option<SilenceSettings>, auto: bool, apply: bool) -> Res<Value> {
    let (assets, have) = with(&st, |e| {
        let used: HashSet<Id> = e.project.tracks.first().map(|t| t.clips.iter().filter_map(|c| c.asset_id).collect()).unwrap_or_default();
        let assets: Vec<_> = e.project.assets.iter().filter(|a| used.contains(&a.id) && a.has_audio).map(|a| (a.id, a.path.clone())).collect();
        (assets, e.loudness.clone())
    });
    let a2 = app.clone();
    let todo: Vec<_> = assets.into_iter().filter(|(id, _)| !have.contains_key(id)).collect();
    let computed = tauri::async_runtime::spawn_blocking(move || {
        todo.into_iter()
            .map(|(id, path)| {
                job(&a2, "silence", 0.0, "소리 분석 중…");
                media::pcm(&PathBuf::from(path), 8000).map(|s| (id, loudness(&s)))
            })
            .collect::<Vec<_>>()
    })
    .await
    .map_err(|e| e.to_string())?;
    job(&app, "silence", 1.0, "");
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
        changed(&app, &st);
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
async fn transcribe(app: AppHandle, st: State<'_, AppState>, asset: Id, language: String) -> Res<Value> {
    let path = with(&st, |e| e.project.assets.iter().find(|a| a.id == asset).map(|a| a.path.clone())).ok_or("파일을 찾을 수 없습니다")?;
    let cancel = st.cancel.clone();
    cancel.store(false, Ordering::SeqCst);
    let a2 = app.clone();
    let words = tauri::async_runtime::spawn_blocking(move || {
        stt::transcribe(
            &PathBuf::from(path),
            &language,
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
        )
    })
    .await
    .map_err(|e| e.to_string())??;
    job(&app, "stt", 1.0, "");
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
    Ok(changed(&app, &st))
}

#[tauri::command]
async fn check_update() -> Res<Value> {
    tauri::async_runtime::spawn_blocking(update::check).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn install_update(app: AppHandle, url: String) -> Res<()> {
    job(&app, "update", 0.0, "업데이트 받는 중…");
    tauri::async_runtime::spawn_blocking(move || update::install(&url)).await.map_err(|e| e.to_string())??;
    app.exit(0);
    Ok(())
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
        .manage(AppState { editor: Mutex::new(Editor::default()), cancel: Arc::new(AtomicBool::new(false)) })
        .invoke_handler(tauri::generate_handler![
            get_state, new_project, open_project, save_project, undo, redo,
            import_files, add_to_timeline, remove_asset,
            split, delete_clips, ripple_delete_range, move_clips, reorder_clip, trim_clip, set_speed, update_clip, update_track, add_text, update_project,
            delete_words, update_word, remove_fillers, generate_captions, export_srt, import_srt, silence_ranges,
            whisper_status, download_model, transcribe, cancel_job, export_video, startup_files, check_update, install_update,
        ])
        .setup(|app| {
            let _ = app.path().app_data_dir();
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("EasyCut 실행 실패");
}
