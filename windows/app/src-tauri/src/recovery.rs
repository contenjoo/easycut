//! 자동 저장과 복구용 파일 (맥 EditorStore 자동 저장과 같은 규칙).
//! 편집이 멈추고 1.5초 뒤: 파일이 있는 프로젝트는 그 파일에, 저장한 적 없으면 복구용 파일에 쓴다.
use crate::{tools, AppState};
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

/// 바로 저장 (업데이트·종료 직전). 프로젝트 파일에 쓰지 못하면(읽기 전용·빠진 드라이브) 복구용 파일에라도 보관한다.
/// 둘 다 못 쓰면 Err — 이때는 앱을 끝내면 안 된다.
pub fn save_now(app: &AppHandle) -> Result<(), String> {
    let st = app.state::<AppState>();
    let mut e = st.editor.lock().unwrap();
    if !e.dirty {
        return Ok(());
    }
    let json = e.project.to_json().map_err(|err| format!("작업을 저장하지 못했습니다: {err}"))?;
    let mut project_error = None;
    if let Some(p) = e.path.clone().filter(|_| autosave_enabled()) {
        match tools::write_atomic(&p, json.as_bytes()) {
            Ok(()) => {
                e.dirty = false;
                drop(e);
                clear();
                // 화면 전체를 다시 그리지 않게 (입력 중인 글자가 지워지지 않도록) 저장됨만 알린다
                let _ = tauri::Emitter::emit(app, "saved", serde_json::json!({ "dirty": false }));
                return Ok(());
            }
            Err(err) => project_error = Some(err),
        }
    } else if e.project.assets.is_empty() {
        return Ok(());
    }
    // 프로젝트 파일에 못 썼거나 저장한 적 없는 작업 → 복구용 파일 (dirty는 그대로 두어 다음 실행 때 복구를 묻는다)
    tools::write_atomic(&path(), json.as_bytes()).map_err(|err| match project_error {
        Some(pe) => format!("작업을 저장하지 못했습니다. 프로젝트 파일: {pe} / 복구용 파일: {err}"),
        None => format!("작업을 복구용 파일에 보관하지 못했습니다: {err}"),
    })
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
                    if let Err(err) = save_now(&app) {
                        eprintln!("자동 저장 실패: {err}");
                    }
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
