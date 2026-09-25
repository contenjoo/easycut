//! 유튜브 등 영상 링크에서 받아 가져오기 (yt-dlp). 맥 LinkImporter.swift와 같은 옵션.
use crate::{emit_state, job, media, tools, AppState};
use easycut_core::transcript_ops::srt;
use easycut_core::MediaKind;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager};

pub struct Options {
    /// "720p" | "1080p" | "best" | "audio"
    pub quality: String,
    pub start: Option<f64>,
    pub end: Option<f64>,
}

pub fn is_link(s: &str) -> bool {
    let t = s.trim().to_lowercase();
    (t.starts_with("http://") || t.starts_with("https://")) && t.split("://").nth(1).is_some_and(|h| !h.is_empty() && !h.starts_with('/'))
}

fn ytdlp_path() -> PathBuf {
    tools::app_data().join("bin").join(tools::exe("yt-dlp"))
}

pub fn ytdlp() -> Option<PathBuf> {
    let p = ytdlp_path();
    if p.is_file() {
        return Some(p);
    }
    tools::find_tool("yt-dlp")
}

/// 공식 yt-dlp를 받아 설치하거나 최신으로 바꾼다 (자주 바뀌므로 앱이 직접 받는다)
pub fn install_ytdlp() -> Result<(), String> {
    let asset = if cfg!(windows) { "yt-dlp.exe" } else if cfg!(target_os = "macos") { "yt-dlp_macos" } else { "yt-dlp" };
    let url = format!("https://github.com/yt-dlp/yt-dlp/releases/latest/download/{asset}");
    let dest = ytdlp_path();
    let _ = std::fs::create_dir_all(dest.parent().unwrap());
    let tmp = dest.with_extension("download");
    crate::update::download(&url, &tmp)?;
    std::fs::rename(&tmp, &dest).map_err(|e| format!("yt-dlp를 설치하지 못했습니다: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755));
    }
    Ok(())
}

pub fn download_dir() -> PathBuf {
    let base = dirs_videos().unwrap_or_else(tools::app_data);
    let d = base.join("EasyCut 다운로드");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// 사용자 동영상 폴더 (윈도우: %USERPROFILE%\Videos)
pub fn dirs_videos() -> Option<PathBuf> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })?;
    let v = PathBuf::from(home).join(if cfg!(windows) { "Videos" } else { "Movies" });
    v.is_dir().then_some(v)
}

pub struct Downloaded {
    pub file: PathBuf,
    pub title: String,
    pub srt: Option<PathBuf>,
}

/// 받기 (진행률 콜백, 취소 확인). 실패하면 사람이 읽을 수 있는 이유
pub fn download(link: &str, o: &Options, progress: impl Fn(f64, String), cancelled: impl Fn() -> bool) -> Result<Downloaded, String> {
    if ytdlp().is_none() {
        progress(0.0, "유튜브 도구(yt-dlp) 받는 중…".into());
        install_ytdlp()?;
    }
    let bin = ytdlp().ok_or("유튜브 도구(yt-dlp)를 찾을 수 없습니다.")?;
    let work = tools::temp_dir().join(format!("dl-{}", easycut_core::Id::new()));
    std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let mut args: Vec<String> = vec![
        link.trim().into(), "--no-playlist".into(), "--newline".into(), "--no-colors".into(), "--no-mtime".into(), "--windows-filenames".into(),
        "-P".into(), work.to_string_lossy().into(), "-o".into(), "%(title).80B [%(id)s].%(ext)s".into(),
        "--progress-template".into(), "download:EC %(progress._percent_str)s %(progress._eta_str)s".into(),
        "--print".into(), "after_move:EC_FILE %(filepath)s".into(),
        "--print".into(), "before_dl:EC_TITLE %(title)s".into(),
        "--encoding".into(), "utf-8".into(),
    ];
    if let Some(ff) = tools::find_tool("ffmpeg") {
        args.push("--ffmpeg-location".into());
        args.push(ff.to_string_lossy().into());
    }
    if o.quality == "audio" {
        args.extend(["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"].map(String::from));
    } else {
        // 편집하기 좋은 H.264 + AAC를 우선으로
        let res = match o.quality.as_str() {
            "720p" => "res:720,",
            "1080p" => "res:1080,",
            _ => "",
        };
        args.extend(["-S".into(), format!("{res}vcodec:h264,acodec:m4a"), "-f".into(), "bv*+ba/b".into(), "--merge-output-format".into(), "mp4".into()]);
        args.extend(["--write-subs", "--sub-langs", "ko.*,en.*", "--convert-subs", "srt"].map(String::from));
    }
    if o.start.is_some() || o.end.is_some() {
        let a = o.start.unwrap_or(0.0);
        let b = o.end.map_or("inf".to_string(), |e| format!("{e:.2}"));
        args.push("--download-sections".into());
        args.push(format!("*{a:.2}-{b}"));
    }
    args.extend(["--retries", "5", "--fragment-retries", "5"].map(String::from));
    progress(0.0, "링크 확인 중…".into());

    let mut outcome = (false, None::<String>, String::new(), String::new());
    for attempt in 1..=3 {
        if attempt > 1 {
            progress(0.0, format!("다시 시도하는 중… ({attempt}/3)"));
        }
        outcome = run_once(&bin, &args, &progress, &cancelled)?;
        if outcome.0 && outcome.1.is_some() {
            break;
        }
        let t = outcome.3.to_lowercase();
        if !(t.contains("403") || t.contains("timed out") || t.contains("connection")) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1500 * attempt));
    }
    let (ok, file, title, tail) = outcome;
    let file = file.map(PathBuf::from).filter(|f| ok && f.is_file()).ok_or_else(|| format!("영상을 받지 못했습니다.\n{}", friendly_error(&tail)))?;

    // 다운로드 폴더로 옮긴다 (같은 이름이 있으면 번호 붙이기)
    let dir = download_dir();
    let stem = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = file.extension().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut dest = dir.join(file.file_name().unwrap());
    let mut n = 2;
    while dest.exists() {
        dest = dir.join(format!("{stem} ({n}).{ext}"));
        n += 1;
    }
    if std::fs::rename(&file, &dest).is_err() {
        std::fs::copy(&file, &dest).map_err(|e| e.to_string())?;
    }
    // 업로더 자막 (한국어 우선)
    let mut subs: Vec<PathBuf> = std::fs::read_dir(&work).into_iter().flatten().flatten().map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("srt"))).collect();
    subs.sort_by_key(|p| !p.to_string_lossy().contains(".ko"));
    let srt = subs.first().and_then(|s| {
        let d = dest.with_extension("srt");
        std::fs::copy(s, &d).ok().map(|_| d)
    });
    let _ = std::fs::remove_dir_all(&work);
    progress(1.0, "완료".into());
    Ok(Downloaded { file: dest, title, srt })
}

type RunResult = (bool, Option<String>, String, String);

fn run_once(bin: &Path, args: &[String], progress: &impl Fn(f64, String), cancelled: &impl Fn() -> bool) -> Result<RunResult, String> {
    let mut child = tools::command(bin)
        .args(args)
        .env("PYTHONIOENCODING", "utf-8")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("yt-dlp 실행 실패: {e}"))?;
    let tail = Arc::new(Mutex::new(String::new()));
    let mut err = child.stderr.take().unwrap();
    let t2 = tail.clone();
    let reader = std::thread::spawn(move || {
        let mut buf = String::new();
        let _ = err.read_to_string(&mut buf);
        let mut t = t2.lock().unwrap();
        *t = buf.chars().rev().take(1500).collect::<Vec<_>>().into_iter().rev().collect();
    });
    let (mut file, mut title) = (None, String::new());
    for line in BufReader::new(child.stdout.take().unwrap()).lines().map_while(Result::ok) {
        if cancelled() {
            let _ = child.kill();
            break;
        }
        if let Some(f) = line.strip_prefix("EC_FILE ") {
            file = Some(f.trim().to_string());
        } else if let Some(t) = line.strip_prefix("EC_TITLE ") {
            title = t.trim().to_string();
            progress(0.0, format!("받는 중: {title}"));
        } else if let Some(rest) = line.strip_prefix("EC ") {
            let mut parts = rest.split_whitespace();
            if let Some(pct) = parts.next().and_then(|p| p.trim_end_matches('%').parse::<f64>().ok()) {
                let eta = parts.next().map(|e| format!(" · 남은 시간 {e}")).unwrap_or_default();
                progress((pct / 100.0).min(0.98), format!("받는 중 {}%{eta}", pct as i64));
            }
        } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[FixupM3u8]") {
            progress(0.99, "합치는 중…".into());
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let _ = reader.join();
    if cancelled() {
        return Err("취소했습니다".into());
    }
    let tail = tail.lock().unwrap().clone();
    Ok((status.success(), file, title, tail))
}

pub fn friendly_error(tail: &str) -> String {
    let l = tail.to_lowercase();
    if l.contains("403") || l.contains("forbidden") || (l.contains("sign in to confirm you") && l.contains("bot")) {
        return "사이트가 다운로드를 막았습니다. 유튜브 도구가 오래됐을 수 있어요. 링크 가져오기 창에서 [유튜브 도구 업데이트]를 눌러 주세요.".into();
    }
    if l.contains("private video") {
        return "비공개 영상입니다.".into();
    }
    if l.contains("sign in to confirm your age") || l.contains("age-restricted") {
        return "연령 제한 영상이라 받을 수 없습니다.".into();
    }
    if l.contains("members-only") || l.contains("join this channel") {
        return "채널 회원 전용 영상입니다.".into();
    }
    if l.contains("drm") {
        return "DRM으로 보호된 영상은 받을 수 없습니다.".into();
    }
    if l.contains("unsupported url") {
        return "지원하지 않는 링크입니다.".into();
    }
    if l.contains("unable to download") || l.contains("http error") || l.contains("timed out") {
        return "네트워크 오류입니다. 연결을 확인하고 다시 시도하세요.".into();
    }
    if l.contains("unavailable") || l.contains("not available") {
        return "볼 수 없는 영상입니다. 주소가 맞는지, 삭제·비공개된 영상은 아닌지 확인하세요.".into();
    }
    tail.lines().rev().find(|l| l.contains("ERROR")).map(str::to_string).unwrap_or_else(|| tail.chars().rev().take(300).collect::<Vec<_>>().into_iter().rev().collect())
}

/// 받아서 프로젝트에 넣는다 (빈 타임라인이면 바로 배치, 자막이 없으면 업로더 자막을 자막으로). 받은 파일 이름을 돌려준다
pub fn import_blocking(app: &AppHandle, link: &str, o: &Options) -> Result<String, String> {
    let st = app.state::<AppState>();
    let cancel = st.cancel.clone();
    cancel.store(false, Ordering::SeqCst);
    let a2 = app.clone();
    let r = download(link, o, |v, m| job(&a2, "link", v, &m), || cancel.load(Ordering::SeqCst));
    job(app, "link", 1.0, "");
    let r = r?;
    let mut asset = media::probe(&r.file)?;
    if !r.title.is_empty() {
        let ext = r.file.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
        asset.name = format!("{}.{ext}", r.title);
    }
    let caps = r.srt.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).map(|t| srt::parse(&t)).unwrap_or_default();
    let name = asset.name.clone();
    {
        let mut e = st.editor.lock().unwrap();
        let was_empty = e.project.duration() <= 0.0;
        e.apply(|p| {
            if was_empty && asset.kind == MediaKind::Video && asset.width > 0.0 {
                p.canvas_width = asset.width;
                p.canvas_height = asset.height;
            }
            p.assets.push(asset.clone());
            if was_empty {
                crate::auto_place(p, &asset);
                if p.captions.is_empty() && !caps.is_empty() {
                    p.captions = caps;
                }
            }
        });
    }
    emit_state(app);
    Ok(name)
}
