//! 화면·얼굴 녹화 (맥 RecordController.swift). 녹화 자체는 화면(WebView2)의 MediaRecorder가 하고,
//! 여기서는 받은 조각을 파일로 쓰고, 떠 있는 정지 창·전역 단축키를 관리하고, 끝나면 MP4로 정리해 타임라인에 넣는다.
use crate::{emit_state, job, link, media, tools, AppState};
use easycut_core::MediaKind;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

#[derive(Default)]
pub struct Recorder {
    /// 조각을 쓰는 중인 파일 (종류 → 파일)
    files: Mutex<HashMap<String, (PathBuf, std::fs::File)>>,
}

pub fn folder() -> PathBuf {
    let d = link::dirs_videos().unwrap_or_else(tools::app_data).join("EasyCut 녹화");
    let _ = std::fs::create_dir_all(&d);
    d
}

fn stamp() -> String {
    chrono::Local::now().format("%Y-%m-%d %H.%M.%S").to_string()
}

/// 녹화 시작: 종류별(screen/camera/system) 파일을 만든다. 확장자는 MediaRecorder 형식(webm/mp4)
pub fn begin(app: &AppHandle, kinds: &[(String, String)]) -> Result<Value, String> {
    let rec = app.state::<Recorder>();
    let mut files = rec.files.lock().unwrap();
    files.clear();
    let st = stamp();
    let mut out = json!({});
    for (kind, ext) in kinds {
        let label = match kind.as_str() {
            "screen" => "화면",
            "camera" => "카메라",
            _ => "컴퓨터 소리",
        };
        let path = tools::temp_dir().join(format!("녹화 {st} {label}.rec.{ext}"));
        let f = std::fs::File::create(&path).map_err(|e| format!("녹화 파일을 만들지 못했습니다: {e}"))?;
        out[kind] = json!(path.to_string_lossy());
        files.insert(kind.clone(), (path, f));
    }
    Ok(out)
}

pub fn write_chunk(app: &AppHandle, kind: &str, data: &[u8]) -> Result<(), String> {
    let rec = app.state::<Recorder>();
    let mut files = rec.files.lock().unwrap();
    let (_, f) = files.get_mut(kind).ok_or("녹화 중이 아닙니다")?;
    f.write_all(data).map_err(|e| format!("녹화 파일 쓰기 실패: {e}"))
}

pub fn discard(app: &AppHandle) {
    let rec = app.state::<Recorder>();
    for (_, (p, _)) in rec.files.lock().unwrap().drain() {
        let _ = std::fs::remove_file(p);
    }
}

// MARK: 떠 있는 정지 창

pub fn open_panel(app: &AppHandle, camera: bool) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("recpanel") {
        let _ = w.destroy();
    }
    let (w, h) = (300.0, if camera { 264.0 } else { 92.0 });
    let win = WebviewWindowBuilder::new(app, "recpanel", WebviewUrl::App("panel.html".into()))
        .title("EasyCut 녹화")
        .inner_size(w, h)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()
        .map_err(|e| format!("녹화 창을 열지 못했습니다: {e}"))?;
    // 녹화 영상에는 찍히지 않게 (윈도우 10 2004 이상)
    let _ = win.set_content_protected(true);
    // 화면 오른쪽 아래
    if let Ok(Some(m)) = win.current_monitor() {
        let scale = m.scale_factor();
        let size = m.size().to_logical::<f64>(scale);
        let pos = m.position().to_logical::<f64>(scale);
        let _ = win.set_position(tauri::LogicalPosition::new(pos.x + size.width - w - 24.0, pos.y + size.height - h - 64.0));
    }
    let _ = win.show();
    Ok(())
}

pub fn close_panel(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("recpanel") {
        let _ = w.destroy();
    }
}

// MARK: 전역 단축키 (Ctrl+Alt+P 일시정지, Ctrl+Alt+S 정지)

pub fn register_hotkeys(app: &AppHandle) {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    for (keys, action) in [("Ctrl+Alt+P", "pause"), ("Ctrl+Alt+S", "stop")] {
        let a = app.clone();
        let _ = gs.on_shortcut(keys, move |_, _, e| {
            if e.state() == ShortcutState::Pressed {
                let _ = a.emit("rec-control", json!({ "action": action }));
            }
        });
    }
}

pub fn unregister_hotkeys(app: &AppHandle) {
    use tauri_plugin_global_shortcut::GlobalShortcutExt;
    let _ = app.global_shortcut().unregister_all();
}

// MARK: 끝내기 → MP4로 정리 → 타임라인에

/// MediaRecorder 파일은 길이·색인이 없어 탐색이 안 되므로 다시 싸거나(mp4) H.264로 바꾼다(webm)
fn finalize_file(src: &Path, dest: &Path, audio_only: bool, progress: &dyn Fn(f64)) -> Result<PathBuf, String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다.")?;
    let is_mp4 = src.extension().is_some_and(|e| e.eq_ignore_ascii_case("mp4"));
    let run = |args: &[&str], out: &Path| -> bool {
        let mut c = tools::command(&ffmpeg);
        c.args(["-y", "-v", "error", "-i"]).arg(src).args(args).args(["-progress", "pipe:1", "-nostats"]).arg(out).stdout(Stdio::piped()).stderr(Stdio::null());
        let Ok(mut child) = c.spawn() else { return false };
        let dur = media::probe(src).map(|a| a.duration).unwrap_or(0.0).max(0.1);
        if let Some(o) = child.stdout.take() {
            use std::io::BufRead;
            for l in std::io::BufReader::new(o).lines().map_while(Result::ok) {
                if let Some(us) = l.strip_prefix("out_time_us=").and_then(|v| v.parse::<f64>().ok()) {
                    progress((us / 1e6 / dur).clamp(0.0, 0.99));
                }
            }
        }
        child.wait().is_ok_and(|s| s.success()) && std::fs::metadata(out).is_ok_and(|m| m.len() > 0)
    };
    if audio_only {
        let out = dest.with_extension("m4a");
        if run(&["-vn", "-c:a", "aac", "-b:a", "192k"], &out) {
            return Ok(out);
        }
    } else {
        let out = dest.with_extension("mp4");
        // 녹화 영상은 프레임 간격이 들쭉날쭉하므로 30fps로 고르게
        // 영상은 그대로, 소리는 맥에서도 열리게 AAC로
        if is_mp4 && run(&["-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"], &out) {
            return Ok(out);
        }
        if run(&["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "30", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"], &out) {
            return Ok(out);
        }
    }
    // 바꾸지 못하면 원래 형식 그대로라도 다시 싸서 쓴다
    let ext = src.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| "webm".into());
    let out = dest.with_extension(ext);
    if run(&["-c", "copy"], &out) {
        return Ok(out);
    }
    std::fs::copy(src, &out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// 녹화 파일을 정리해 타임라인에: 화면은 트랙 1, 카메라는 트랙 2 오른쪽 아래 작은 화면(원 모양), 컴퓨터 소리는 트랙 3. 그리고 음성 인식.
pub fn finish(app: &AppHandle, camera_circle: bool) -> Result<Value, String> {
    let files: Vec<(String, PathBuf)> = {
        let rec = app.state::<Recorder>();
        let mut f = rec.files.lock().unwrap();
        f.drain().map(|(k, (p, file))| {
            let _ = file.sync_all();
            (k, p)
        }).collect()
    };
    let dir = folder();
    let mut out: HashMap<String, PathBuf> = HashMap::new();
    let n = files.len().max(1) as f64;
    for (i, (kind, src)) in files.iter().enumerate() {
        if std::fs::metadata(src).map_or(0, |m| m.len()) == 0 {
            continue;
        }
        let name = src.file_name().unwrap().to_string_lossy().replace(".rec", "");
        let dest = dir.join(name);
        let a2 = app.clone();
        let base = i as f64 / n;
        let r = finalize_file(src, &dest, kind == "system", &move |v| job(&a2, "record", base + v / n, "녹화 파일 정리 중…"));
        if let Ok(p) = r {
            let _ = std::fs::remove_file(src);
            out.insert(kind.clone(), p);
        }
    }
    job(app, "record", 1.0, "");
    let screen = out.get("screen").ok_or("녹화 파일을 만들지 못했습니다.")?;
    let sa = media::probe(screen)?;
    let ca = out.get("camera").and_then(|p| media::probe(p).ok());
    let aa = out.get("system").and_then(|p| media::probe(p).ok());
    let st = app.state::<AppState>();
    {
        let mut e = st.editor.lock().unwrap();
        let was_empty = e.project.duration() <= 0.0;
        e.apply(|p| {
            p.assets.push(sa.clone());
            if let Some(ca) = &ca {
                p.assets.push(ca.clone());
            }
            if let Some(aa) = &aa {
                p.assets.push(aa.clone());
            }
            if was_empty && sa.width > 0.0 {
                p.canvas_width = sa.width;
                p.canvas_height = sa.height;
            }
            while p.tracks.len() < 3 {
                p.tracks.push(easycut_core::Track::named(format!("트랙 {}", p.tracks.len() + 1)));
            }
            let t = if was_empty { 0.0 } else { p.track_end(0).max(p.track_end(1)).max(p.track_end(2)) };
            p.insert(&sa, 0, t, 5.0);
            if let Some(aa) = &aa {
                p.insert(aa, 2, t, 5.0);
            }
            if let Some(ca) = ca.as_ref().filter(|c| c.width > 0.0 && c.kind == MediaKind::Video) {
                let id = p.insert(ca, 1, t, 5.0);
                let (w, h) = (p.canvas_width, p.canvas_height);
                // 원 모양이면 가운데 정사각형으로 잘리므로 그 크기로 배치
                let (cw, ch) = if camera_circle { let s = ca.width.min(ca.height); (s, s) } else { (ca.width, ca.height) };
                let base = (w / cw).min(h / ch);
                let width_frac = if camera_circle { 0.17 } else { 0.24 };
                let scale = width_frac * w / (cw * base);
                let height_frac = ch * base * scale / h;
                if let Some(c) = p.clip_mut(id) {
                    if camera_circle {
                        c.extra.insert("shape".into(), json!("circle"));
                    }
                    c.scale = scale;
                    c.offset_x = 0.5 - width_frac / 2.0 - 0.02;
                    c.offset_y = 0.5 - height_frac / 2.0 - 0.03;
                    c.volume = 0.0;
                }
            }
        });
    }
    emit_state(app);
    Ok(json!({ "screen": sa.id, "hasCamera": ca.is_some(), "hasAudio": sa.has_audio, "folder": dir.to_string_lossy() }))
}
