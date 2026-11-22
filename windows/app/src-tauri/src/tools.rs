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

/// 앱이 끝나면(강제 종료·업데이트 포함) 같이 끝나야 하는 자식 프로세스(내보내기·녹화 정리 ffmpeg)를 묶는다.
/// 윈도우: 앱 전체에서 하나인 Job Object(KILL_ON_JOB_CLOSE). 앱 프로세스가 끝나 핸들이 닫히면 OS가 묶인 자식을 모두 끝낸다.
/// (업데이트 설치용 PowerShell은 묶지 않는다 — 앱이 끝난 뒤에도 살아 있어야 한다.)
pub fn tie_to_app(child: &std::process::Child) {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use std::sync::OnceLock;
        use windows_sys::Win32::System::JobObjects::*;
        static JOB: OnceLock<usize> = OnceLock::new();
        let job = *JOB.get_or_init(|| unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return 0;
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as *const _, std::mem::size_of_val(&info) as u32) == 0 {
                windows_sys::Win32::Foundation::CloseHandle(job);
                return 0;
            }
            job as usize
        });
        if job != 0 {
            unsafe {
                AssignProcessToJobObject(job as _, child.as_raw_handle() as _);
            }
        }
    }
    #[cfg(not(windows))]
    let _ = child;
}

/// Command::output()와 같지만 자식을 앱 수명에 묶는다
pub fn output_tied(cmd: &mut Command) -> std::io::Result<std::process::Output> {
    use std::process::Stdio;
    let child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    tie_to_app(&child);
    child.wait_with_output()
}

static BUSY: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// 내보내기·녹화 정리 중 표시 (mark_busy()가 돌려준 값이 살아 있는 동안 busy() == true). 업데이트 설치를 막는 데 쓴다.
pub struct BusyGuard(());
pub fn mark_busy() -> BusyGuard {
    BUSY.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    BusyGuard(())
}
impl Drop for BusyGuard {
    fn drop(&mut self) {
        BUSY.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}
pub fn busy() -> bool {
    BUSY.load(std::sync::atomic::Ordering::SeqCst) > 0
}

/// 원자적 저장: 같은 폴더의 임시 파일에 다 쓰고 디스크에 내린 뒤 원래 파일 위로 바꿔 넣는다.
/// 중간에 실패해도 원래 파일은 그대로 남는다 (std::fs::rename: 윈도우는 MoveFileExW REPLACE_EXISTING처럼 덮어쓴다).
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let dir = path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

pub fn temp_dir() -> PathBuf {
    let d = std::env::temp_dir().join("EasyCut");
    let _ = std::fs::create_dir_all(&d);
    d
}

#[cfg(test)]
mod tests {
    #[test]
    fn write_atomic_replaces_existing_file_and_leaves_no_temp() {
        let dir = std::env::temp_dir().join(format!("easycut-atomic-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("a.easycut");
        std::fs::write(&target, b"old contents that are longer").unwrap();
        super::write_atomic(&target, b"new").unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        let names: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names.len(), 1, "temp file must be renamed away: {names:?}");
        // 쓸 수 없는 폴더면 실패하고 아무것도 남기지 않는다
        assert!(super::write_atomic(&dir.join("missing").join("b.easycut"), b"x").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
