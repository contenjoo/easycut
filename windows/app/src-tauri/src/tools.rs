//! 외부 도구(ffmpeg, ffprobe, whisper-cli) 찾기와 실행
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

/// 앱 데이터 폴더 (Tauri app_data_dir 과 같은 위치)
pub fn app_data() -> PathBuf {
    let base = if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
    } else {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share"))
    };
    let d = base.unwrap_or_else(std::env::temp_dir).join("com.contenjoo.easycut.windows");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// 설치 파일에 넣은 도구 → 앱이 받은 도구 → PATH 순서로 찾는다
pub fn find_tool(name: &str) -> Option<PathBuf> {
    let file = exe(name);
    let mut dirs: Vec<PathBuf> = vec![];
    if let Some(exe_dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
        dirs.push(exe_dir.join("resources").join("bin")); // 윈도우 설치본
        dirs.push(exe_dir.join("bin"));
        dirs.push(exe_dir.join("../Resources/resources/bin")); // 맥 번들
    }
    dirs.push(app_data().join("bin"));
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    // 맥에서 개발할 때
    dirs.push(PathBuf::from("/opt/homebrew/bin"));
    dirs.push(PathBuf::from("/usr/local/bin"));
    dirs.into_iter().map(|d| d.join(&file)).find(|p| p.is_file())
}

/// 콘솔 창이 뜨지 않게 실행 (윈도우)
pub fn command(program: &Path) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c
}

pub fn temp_dir() -> PathBuf {
    let d = std::env::temp_dir().join("EasyCut");
    let _ = std::fs::create_dir_all(&d);
    d
}
