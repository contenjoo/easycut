//! GitHub 릴리스(win-v* 태그)에서 새 윈도우 버전 확인 → 설치 파일 받아 실행
use crate::tools;
use serde_json::{json, Value};
use std::path::PathBuf;

pub const CURRENT: &str = env!("CARGO_PKG_VERSION");

fn parts(v: &str) -> Vec<u64> {
    v.trim_start_matches(|c: char| !c.is_ascii_digit()).split('.').map(|p| p.chars().take_while(char::is_ascii_digit).collect::<String>().parse().unwrap_or(0)).collect()
}

pub fn is_newer(a: &str, b: &str) -> bool {
    let (x, y) = (parts(a), parts(b));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if l != r {
            return l > r;
        }
    }
    false
}

fn curl() -> PathBuf {
    if cfg!(windows) { PathBuf::from("curl.exe") } else { PathBuf::from("/usr/bin/curl") }
}

/// 가장 새 윈도우 릴리스 (없거나 지금 버전 이하면 null)
pub fn check() -> Result<Value, String> {
    let out = tools::command(&curl())
        .args(["-sL", "--max-time", "15", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/contenjoo/easycut/releases?per_page=30"])
        .output()
        .map_err(|e| e.to_string())?;
    let list: Value = serde_json::from_slice(&out.stdout).map_err(|_| "업데이트를 확인하지 못했습니다.".to_string())?;
    let best = list.as_array().into_iter().flatten()
        .filter(|r| r["tag_name"].as_str().is_some_and(|t| t.starts_with("win-v")))
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            let asset = r["assets"].as_array()?.iter().find(|a| a["name"].as_str().is_some_and(|n| n.ends_with("setup.exe")))?;
            Some((tag.trim_start_matches("win-v").to_string(), asset["browser_download_url"].as_str()?.to_string(), r["body"].as_str().unwrap_or("").to_string()))
        })
        .max_by(|a, b| if is_newer(&a.0, &b.0) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Less });
    Ok(match best {
        Some((v, url, notes)) if is_newer(&v, CURRENT) => json!({ "version": v, "url": url, "notes": notes, "current": CURRENT }),
        _ => Value::Null,
    })
}

/// 파일 받기 (curl: 윈도우 10 이상에 기본으로 들어 있다)
pub fn download(url: &str, dest: &std::path::Path) -> Result<(), String> {
    if let Some(d) = dest.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let status = tools::command(&curl()).args(["-sL", "--fail", "--retry", "3", "-o"]).arg(dest).arg(url).status().map_err(|e| e.to_string())?;
    if !status.success() || std::fs::metadata(dest).map_or(0, |m| m.len()) == 0 {
        let _ = std::fs::remove_file(dest);
        return Err(format!("받지 못했습니다: {url}"));
    }
    Ok(())
}

/// 설치 파일을 받아 둔다 (윈도우 실행 파일인지 확인)
pub fn fetch_installer(url: &str) -> Result<PathBuf, String> {
    let dest = tools::temp_dir().join("EasyCut-setup.exe");
    download(url, &dest).map_err(|_| "업데이트 파일을 받지 못했습니다.".to_string())?;
    let mut head = [0u8; 2];
    let ok = std::fs::File::open(&dest).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut head)).is_ok();
    if !ok || &head != b"MZ" {
        let _ = std::fs::remove_file(&dest);
        return Err("받은 업데이트 파일이 올바르지 않습니다.".into());
    }
    Ok(dest)
}

/// 앱이 끝나기를 기다렸다가 조용히 설치하고 다시 연다 (reopen: 다시 열 프로젝트)
pub fn install_and_relaunch(setup: &std::path::Path, reopen: Option<&str>) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let q = |s: &str| s.replace('\'', "''");
    let args = reopen.map(|p| format!(" -ArgumentList '\"{}\"'", q(p))).unwrap_or_default();
    let script = format!(
        "Wait-Process -Id {pid} -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; \
         $p = Start-Process -FilePath '{setup}' -ArgumentList '/S' -Wait -PassThru; \
         Start-Process -FilePath '{exe}'{args}",
        pid = std::process::id(),
        setup = q(&setup.to_string_lossy()),
        exe = q(&exe.to_string_lossy()),
    );
    if cfg!(windows) {
        let ps = PathBuf::from(std::env::var_os("SystemRoot").unwrap_or("C:\\Windows".into())).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        tools::command(&ps)
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-Command", &script])
            .spawn()
            .map_err(|e| format!("업데이트를 시작하지 못했습니다: {e}"))?;
    } else {
        // 맥에서 개발할 때는 설치 파일을 실행할 수 없으므로 여기까지만 확인
        return Err("윈도우에서만 설치할 수 있습니다.".into());
    }
    Ok(())
}
