//! 자동 저장과 복구용 파일 (맥 EditorStore 자동 저장과 같은 규칙).
//! 편집이 멈추고 1.5초 뒤: 파일이 있는 프로젝트는 그 파일에, 저장한 적 없으면 복구용 파일에 쓴다.
use crate::{emit_state, tools, AppState};
use easycut_core::Project;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

pub fn path() -> PathBuf {
    tools::app_data().join("복구용 프로젝트.easycut")
}

fn prefs_path() -> PathBuf {
    tools::app_data().join("prefs.json")
}

pub fn prefs() -> Value {
    std::fs::read_to_string(prefs_path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_else(|| json!({}))
}

pub fn set_pref(key: &str, v: Value) {
    let mut p = prefs();
    p[key] = v;
    let _ = std::fs::write(prefs_path(), serde_json::to_string_pretty(&p).unwrap_or_default());
}

pub fn autosave_enabled() -> bool {
    prefs()["autosave"].as_bool().unwrap_or(true)
}

pub fn clear() {
    let _ = std::fs::remove_file(path());
}

/// 지난번에 저장하지 않고 끝난 작업 (미디어 개수, 길이, 보관 시각)
pub fn check() -> Option<Value> {
    let p = path();
    let data = std::fs::read_to_string(&p).ok()?;
    let proj = Project::from_json(&data).ok()?;
    let when = std::fs::metadata(&p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as u64);
    Some(json!({ "assets": proj.assets.len(), "duration": proj.duration(), "savedAt": when }))
}

pub fn load() -> Option<Project> {
    Project::from_json(&std::fs::read_to_string(path()).ok()?).ok()
}

/// 바로 저장 (업데이트·종료 직전). 저장했으면 true
pub fn save_now(app: &AppHandle) -> bool {
    let st = app.state::<AppState>();
    let mut e = st.editor.lock().unwrap();
    if !e.dirty {
        return true;
    }
    let Ok(json) = e.project.to_json() else { return false };
    if let Some(p) = e.path.clone().filter(|_| autosave_enabled()) {
        if std::fs::write(&p, &json).is_ok() {
            e.dirty = false;
            drop(e);
            clear();
            emit_state(app);
            return true;
        }
        return false;
    }
    if !e.project.assets.is_empty() {
        return std::fs::write(path(), json).is_ok();
    }
    true
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last_rev = 0;
        let mut changed_at: Option<Instant> = None;
        loop {
            std::thread::sleep(Duration::from_millis(300));
            let rev = app.state::<AppState>().editor.lock().unwrap().rev;
            if rev != last_rev {
                last_rev = rev;
                changed_at = Some(Instant::now());
                continue;
            }
            if changed_at.is_some_and(|t| t.elapsed() >= Duration::from_millis(1500)) {
                changed_at = None;
                if autosave_enabled() {
                    save_now(&app);
                }
            }
        }
    });
}

/// 최근 프로젝트 (맨 앞이 가장 최근, 10개까지)
pub fn add_recent(path: &str) {
    let mut list: Vec<String> = prefs()["recent"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    list.retain(|p| p != path);
    list.insert(0, path.to_string());
    list.truncate(10);
    set_pref("recent", json!(list));
}
